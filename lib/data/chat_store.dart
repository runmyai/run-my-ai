import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../search/chat_search.dart';
import 'chat_db.dart';
import 'models.dart';
import 'storage.dart';

/// The chats (their files and the index of them, lib/data/chat_db.dart), run on its own background worker (a Dart
/// isolate) so the screen never waits for the disk: loading, saving and searching all happen there. Saves are sent and
/// not waited for; the worker does them in the order they were sent.
class ChatStore {
  ChatStore._(this._requests, this._replies, this.chats, this.pins, this.branches, this.unreadable);

  final SendPort _requests;
  final ReceivePort _replies;
  final _waiting = <int, Completer<Object?>>{};
  int _next = 0;

  /// The parent to give [addMessage] for a message that starts the chat.
  static const noParent = ChatDb.noParent;

  /// The chat list, the pins and the chats' branches (their conversation ids but their own, by chat id) when the
  /// store was opened (the app keeps them up to date itself from then on).
  final List<ChatInfo> chats;
  final List<String> pins;
  final Map<String, List<String>> branches;

  /// The chat files ("Chat/Name.json") that could not be read when the store was opened; they are left untouched.
  final List<String> unreadable;

  /// Starts the worker on the chats in [folder] (default: the chats folder of [dir], the app's data folder), with
  /// their index and the benchmark runs in [dir]. Chats older versions kept in [dir] are moved into files first.
  static Future<ChatStore> open(Directory dir, {Directory? folder}) async {
    final replies = ReceivePort();
    final first = Completer<List<Object?>>();
    late final ChatStore store;
    replies.listen((message) {
      if (!first.isCompleted) {
        first.complete(message as List<Object?>);
      } else {
        final (id, result) = message as (int, Object?);
        store._waiting.remove(id)?.complete(result);
      }
    });
    await Isolate.spawn(_worker, (replies.sendPort, dir.path, (folder ?? Storage(dir).chatsDir).path),
        debugName: 'chats database');
    final [port, chats, pins, branches, unreadable] = await first.future;
    store = ChatStore._(port! as SendPort, replies, chats! as List<ChatInfo>, pins! as List<String>,
        branches! as Map<String, List<String>>, unreadable! as List<String>);
    return store;
  }

  Future<T> _ask<T>(_Request request) {
    final done = Completer<Object?>();
    _waiting[request.id] = done;
    _requests.send(request);
    return done.future.then((r) => r as T);
  }

  int get _id => _next++;

  /// The messages shown: one path through the chat's versions.
  Future<List<ChatMessage>> messages(String chatId) async => (await path(chatId)).messages;

  /// The messages shown, and the number the chat's next new message gets.
  Future<ChatPath> path(String chatId) => _ask(_Path(_id, chatId));

  /// Shows the version of message [node] that is [step] places after it (before it, for a negative step), and every
  /// message after that version in the versions last shown there; the chat's path then. Null if it failed.
  Future<ChatPath?> flip(String chatId, int node, int step) => _ask(_Flip(_id, chatId, node, step));

  /// The chat's path with message [node] on it, which the chat opens on from now on. Null if it failed.
  Future<ChatPath?> pathTo(String chatId, int node) => _ask(_PathTo(_id, chatId, node));

  void createChat(ChatInfo chat) => _requests.send(_CreateChat(_id, chat));

  /// Saves message number [pos] of the chat, following message [parent] ([ChatDb.noParent]: the chat's first); a
  /// new message becomes the version shown at its place. Left out, [parent] is the number before [pos]. A message
  /// already saved under [pos] gets the new text (a reply is saved as it grows).
  void addMessage(String chatId, int pos, ChatMessage message, {int? parent}) =>
      _requests.send(_AddMessage(_id, chatId, pos, message, parent));

  /// Saves a benchmark run; the answer is its id in the history.
  Future<int> addBenchmark(String data) => _ask(_AddBenchmark(_id, data));

  /// Deletes a benchmark run from the history.
  void deleteBenchmark(int id) => _requests.send(_DeleteBenchmark(_id, id));

  /// Every benchmark run's id and details, the newest first.
  Future<List<(int, String)>> benchmarks() => _ask(_Benchmarks(_id));

  /// The model file and context length the chat uses.
  void setChoices(String chatId, String? modelId, int? contextLength) =>
      _requests.send(_SetChoices(_id, chatId, modelId, contextLength));

  /// Removes message [node] of the chat and any message after it.
  void removeMessage(String chatId, int node) => _requests.send(_RemoveMessage(_id, chatId, node));
  void setUpdated(String chatId, DateTime updatedAt) => _requests.send(_SetUpdated(_id, chatId, updatedAt));
  void rename(String chatId, String title) => _requests.send(_Rename(_id, chatId, title));
  void setBookmark(String chatId, int pos, bool bookmark) => _requests.send(_SetBookmark(_id, chatId, pos, bookmark));
  void setArchived(String chatId, DateTime? at, DateTime now) => _requests.send(_SetArchived(_id, chatId, at, now));
  void delete(String chatId) => _requests.send(_Delete(_id, chatId));
  void setPins(List<String> ids) => _requests.send(_SetPins(_id, ids));
  void setSorts(Map<String, double> sorts) => _requests.send(_SetSorts(_id, sorts));

  /// The chats of section [kind] that match [text], best first; null when a newer search started before this one
  /// finished.
  Future<List<ChatHit>?> search(String text, ChatKind kind) => _ask(_Search(_id, text, kind));

  /// [hits] with the lines under their titles filled in (results further down the list than the first ones).
  Future<List<ChatHit>> fillLines(String text, List<ChatHit> hits) => _ask(_FillLines(_id, text, hits));

  /// Waits until every save sent so far is done, in the index and in the chats' files (tests, and before closing).
  Future<void> flush() => _ask(_Flush(_id));

  /// Finishes the saves sent so far, then stops the worker.
  Future<void> close() async {
    await _ask<void>(_Close(_id));
    _replies.close();
  }
}

// ---- The worker ----------------------------------------------------------------------------------------------------

Future<void> _worker((SendPort, String, String) start) async {
  final (replies, data, chats) = start;
  final db = ChatDb.open(Directory(data), Directory(chats));
  final requests = ReceivePort();
  replies.send([requests.sendPort, db.chats(), db.pins(), db.branches(), [...db.unreadable]]);
  var latestSearch = -1;
  Future<void>? running;
  await for (final r in requests) {
    try {
      switch (r as _Request) {
        case _Path(:final id, :final chatId):
          replies.send((id, db.path(chatId)));
        case _Flip(:final id, :final chatId, :final node, :final step):
          replies.send((id, db.flip(chatId, node, step)));
        case _PathTo(:final id, :final chatId, :final node):
          replies.send((id, db.pathTo(chatId, node)));
        case _CreateChat(:final chat):
          db.createChat(chat);
        case _AddMessage(:final chatId, :final pos, :final message, :final parent):
          db.addMessage(chatId, pos, message, parent: parent);
        case _AddBenchmark(:final id, :final data):
          replies.send((id, db.addBenchmark(data)));
        case _DeleteBenchmark(:final benchmark):
          db.deleteBenchmark(benchmark);
        case _Benchmarks(:final id):
          replies.send((id, db.benchmarks()));
        case _SetChoices(:final chatId, :final modelId, :final contextLength):
          db.setChoices(chatId, modelId, contextLength);
        case _RemoveMessage(:final chatId, :final node):
          db.removeMessage(chatId, node);
        case _SetUpdated(:final chatId, :final updatedAt):
          db.setUpdated(chatId, updatedAt);
        case _Rename(:final chatId, :final title):
          db.rename(chatId, title);
        case _SetBookmark(:final chatId, :final pos, :final bookmark):
          db.setBookmark(chatId, pos, bookmark);
        case _SetArchived(:final chatId, :final at, :final now):
          db.setArchived(chatId, at, now);
        case _Delete(:final chatId):
          db.delete(chatId);
        case _SetPins(:final ids):
          db.setPins(ids);
        case _SetSorts(:final sorts):
          db.setSorts(sorts);
        case _Search(:final id, :final text, :final kind):
          // Runs alongside the next requests (it pauses every few milliseconds); a newer search stops it.
          latestSearch = id;
          running = db
              .search(SearchQuery.parse(text), kind: kind, cancelled: () => latestSearch != id)
              .then((hits) => replies.send((id, latestSearch == id ? hits : null)))
              .catchError((Object e) {
            stderr.writeln('Run My AI: search: $e');
            replies.send((id, null));
          });
        case _FillLines(:final id, :final text, :final hits):
          replies.send((id, db.fillLines(SearchQuery.parse(text), hits)));
        case _Flush(:final id):
          db.writeFiles();
          replies.send((id, null));
        case _Close(:final id):
          latestSearch = -1;
          await running;
          db.close();
          replies.send((id, null));
          requests.close();
      }
    } catch (e, stack) {
      stderr.writeln('Run My AI: chats database: $e\n$stack');
      if (r case _Path(:final id)) replies.send((id, const ChatPath([], 0)));
      if (r case _Flip(:final id)) replies.send((id, null));
      if (r case _PathTo(:final id)) replies.send((id, null));
      if (r case _Search(:final id)) replies.send((id, null));
      if (r case _FillLines(:final id, :final hits)) replies.send((id, hits));
    }
  }
}

sealed class _Request {
  const _Request(this.id);
  final int id;
}

class _Path extends _Request {
  const _Path(super.id, this.chatId);
  final String chatId;
}

class _Flip extends _Request {
  const _Flip(super.id, this.chatId, this.node, this.step);
  final String chatId;
  final int node;
  final int step;
}

class _PathTo extends _Request {
  const _PathTo(super.id, this.chatId, this.node);
  final String chatId;
  final int node;
}

class _CreateChat extends _Request {
  const _CreateChat(super.id, this.chat);
  final ChatInfo chat;
}

class _AddMessage extends _Request {
  const _AddMessage(super.id, this.chatId, this.pos, this.message, this.parent);
  final String chatId;
  final int pos;
  final ChatMessage message;
  final int? parent;
}

class _SetUpdated extends _Request {
  const _SetUpdated(super.id, this.chatId, this.updatedAt);
  final String chatId;
  final DateTime updatedAt;
}

class _Rename extends _Request {
  const _Rename(super.id, this.chatId, this.title);
  final String chatId;
  final String title;
}

class _AddBenchmark extends _Request {
  const _AddBenchmark(super.id, this.data);
  final String data;
}

class _DeleteBenchmark extends _Request {
  const _DeleteBenchmark(super.id, this.benchmark);
  final int benchmark;
}

class _Benchmarks extends _Request {
  const _Benchmarks(super.id);
}

class _SetChoices extends _Request {
  const _SetChoices(super.id, this.chatId, this.modelId, this.contextLength);
  final String chatId;
  final String? modelId;
  final int? contextLength;
}

class _RemoveMessage extends _Request {
  const _RemoveMessage(super.id, this.chatId, this.node);
  final String chatId;
  final int node;
}

class _SetBookmark extends _Request {
  const _SetBookmark(super.id, this.chatId, this.pos, this.bookmark);
  final String chatId;
  final int pos;
  final bool bookmark;
}

class _SetArchived extends _Request {
  const _SetArchived(super.id, this.chatId, this.at, this.now);
  final String chatId;
  final DateTime? at;
  final DateTime now;
}

class _Delete extends _Request {
  const _Delete(super.id, this.chatId);
  final String chatId;
}

class _SetPins extends _Request {
  const _SetPins(super.id, this.ids);
  final List<String> ids;
}

class _SetSorts extends _Request {
  const _SetSorts(super.id, this.sorts);
  final Map<String, double> sorts;
}

class _Search extends _Request {
  const _Search(super.id, this.text, this.kind);
  final String text;
  final ChatKind kind;
}

class _FillLines extends _Request {
  const _FillLines(super.id, this.text, this.hits);
  final String text;
  final List<ChatHit> hits;
}

class _Flush extends _Request {
  const _Flush(super.id);
}

class _Close extends _Request {
  const _Close(super.id);
}
