import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../search/chat_search.dart';
import 'chat_db.dart';
import 'models.dart';

/// The chats database, run on its own background worker (a Dart isolate) so the screen never waits for the disk:
/// loading, saving and searching all happen there. Saves are sent and not waited for; the worker does them in the
/// order they were sent.
class ChatStore {
  ChatStore._(this._requests, this._replies, this.chats, this.pins);

  final SendPort _requests;
  final ReceivePort _replies;
  final _waiting = <int, Completer<Object?>>{};
  int _next = 0;

  /// The chat list and the pins when the store was opened (the app keeps them up to date itself from then on).
  final List<ChatInfo> chats;
  final List<String> pins;

  /// Starts the worker on [dir]/chats.db (moving in the chats older versions saved as files).
  static Future<ChatStore> open(Directory dir) async {
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
    await Isolate.spawn(_worker, (replies.sendPort, '${dir.path}${Platform.pathSeparator}chats.db'),
        debugName: 'chats database');
    final [port, chats, pins] = await first.future;
    store = ChatStore._(port! as SendPort, replies, chats! as List<ChatInfo>, pins! as List<String>);
    return store;
  }

  Future<T> _ask<T>(_Request request) {
    final done = Completer<Object?>();
    _waiting[request.id] = done;
    _requests.send(request);
    return done.future.then((r) => r as T);
  }

  int get _id => _next++;

  Future<List<ChatMessage>> messages(String chatId) => _ask(_Messages(_id, chatId));

  void createChat(ChatInfo chat) => _requests.send(_CreateChat(_id, chat));
  void addMessage(String chatId, int pos, ChatMessage message) => _requests.send(_AddMessage(_id, chatId, pos, message));
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

  /// Waits until every save sent so far is done (tests, and before closing).
  Future<void> flush() => _ask(_Flush(_id));

  /// Finishes the saves sent so far, then stops the worker.
  Future<void> close() async {
    await _ask<void>(_Close(_id));
    _replies.close();
  }
}

// ---- The worker ----------------------------------------------------------------------------------------------------

Future<void> _worker((SendPort, String) start) async {
  final (replies, path) = start;
  final db = ChatDb.open(path);
  final requests = ReceivePort();
  replies.send([requests.sendPort, db.chats(), db.pins()]);
  var latestSearch = -1;
  Future<void>? running;
  await for (final r in requests) {
    try {
      switch (r as _Request) {
        case _Messages(:final id, :final chatId):
          replies.send((id, db.messages(chatId)));
        case _CreateChat(:final chat):
          db.createChat(chat);
        case _AddMessage(:final chatId, :final pos, :final message):
          db.addMessage(chatId, pos, message);
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
      if (r case _Messages(:final id)) replies.send((id, const <ChatMessage>[]));
      if (r case _Search(:final id)) replies.send((id, null));
      if (r case _FillLines(:final id, :final hits)) replies.send((id, hits));
    }
  }
}

sealed class _Request {
  const _Request(this.id);
  final int id;
}

class _Messages extends _Request {
  const _Messages(super.id, this.chatId);
  final String chatId;
}

class _CreateChat extends _Request {
  const _CreateChat(super.id, this.chat);
  final ChatInfo chat;
}

class _AddMessage extends _Request {
  const _AddMessage(super.id, this.chatId, this.pos, this.message);
  final String chatId;
  final int pos;
  final ChatMessage message;
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
