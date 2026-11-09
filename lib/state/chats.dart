import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../system/chime.dart';
import 'providers.dart';
import 'section.dart';

class ChatsState {
  const ChatsState({
    this.kind = ChatKind.chat,
    this.chats = const [],
    this.pinned = const [],
    this.openId,
    this.open,
    this.replyingId,
  });

  /// Whose chats the sidebar shows: Chat's or Code's (the last of the two the user was in).
  final ChatKind kind;

  /// All chats of both sections, the most recently used first (titles and dates only; messages stay in the
  /// database).
  final List<ChatInfo> chats;

  /// The ids of the pinned chats of both sections, in the user's order (each newly pinned one at the bottom until
  /// the user drags it).
  final List<String> pinned;

  /// The chat on screen; null = a new, empty chat.
  final String? openId;

  /// The chat on screen with its messages; null for a new chat, and for a moment while an opened chat loads.
  final Chat? open;

  /// The chat whose reply is being written (one at a time).
  final String? replyingId;

  ChatInfo? byId(String? id) => id == null ? null : chats.where((c) => c.id == id).firstOrNull;

  /// The chats of the section shown ([kind]), but the archived ones.
  List<ChatInfo> get shown => [for (final c in chats) if (c.kind == kind && !c.archived) c];

  /// The pinned chats of the section shown, in the user's order.
  List<ChatInfo> get shownPins =>
      [for (final id in pinned) if (byId(id) case final c? when c.kind == kind && !c.archived) c];

  /// The archived chats of the section shown, the last active first.
  List<ChatInfo> get shownArchived =>
      [for (final c in chats) if (c.kind == kind && c.archived) c]..sort((a, b) => b.lastActive.compareTo(a.lastActive));

  ChatsState copyWith({
    ChatKind? kind,
    List<ChatInfo>? chats,
    List<String>? pinned,
    String? Function()? openId,
    Chat? Function()? open,
    String? Function()? replyingId,
  }) =>
      ChatsState(
        kind: kind ?? this.kind,
        chats: chats ?? this.chats,
        pinned: pinned ?? this.pinned,
        openId: openId != null ? openId() : this.openId,
        open: open != null ? open() : this.open,
        replyingId: replyingId != null ? replyingId() : this.replyingId,
      );
}

/// The chat list, the open chat and the reply being written; every change is saved to the chats database.
/// Only the open chat's messages (and those of the chat being replied to) are kept in memory.
/// Chat and Code each have their own chats, and each keeps its open chat while the user is in the other.
class ChatsNotifier extends Notifier<ChatsState> {
  StreamSubscription<String>? _reply;

  /// The chat whose reply is being written, with its messages, kept here even while another chat is open.
  Chat? _replying;

  /// The open chat of the section not shown (null = a new chat), opened again when the user comes back to it.
  final _openIn = <ChatKind, String?>{};

  @override
  ChatsState build() {
    ref.onDispose(() => _reply?.cancel());
    ref.listen(sectionProvider, (_, section) {
      if (section.kind case final kind?) _show(kind);
    });
    final store = ref.read(chatStoreProvider);
    return ChatsState(
        kind: ref.read(sectionProvider).kind ?? ChatKind.chat, chats: sortChats([...store.chats]), pinned: store.pins);
  }

  /// Shows the chats of [kind], and its open chat from before.
  void _show(ChatKind kind) {
    if (kind == state.kind) return;
    _openIn[state.kind] = state.openId;
    final id = _openIn[kind];
    state = state.copyWith(kind: kind, openId: () => null, open: () => null);
    if (state.byId(id) != null) open(id!);
  }

  void newChat() => state = state.copyWith(openId: () => null, open: () => null);

  /// Opens the chat; its messages come from the database (at once for the chat being replied to).
  Future<void> open(String id) async {
    if (state.openId == id && state.open != null) return;
    final replying = _replying;
    if (replying != null && replying.id == id) {
      state = state.copyWith(openId: () => id, open: () => replying);
      return;
    }
    state = state.copyWith(openId: () => id, open: () => null);
    final messages = await ref.read(chatStoreProvider).messages(id);
    final info = state.byId(id);
    // Another chat may have been opened (or this one deleted) meanwhile.
    if (!ref.mounted || state.openId != id || state.open != null || info == null) return;
    state = state.copyWith(open: () => Chat.of(info, messages));
  }

  /// Sends [text] in the open chat (a new chat if none is open). Switching chats does not stop the reply.
  void send(String text, ModelFile model) {
    text = text.trim();
    if (text.isEmpty || state.replyingId != null) return;
    // An opened chat whose messages have not arrived yet (a moment) cannot take a message.
    if (state.openId != null && state.open == null) return;
    final store = ref.read(chatStoreProvider);
    final now = DateTime.now();
    final isNew = state.open == null;
    final base = state.open ??
        Chat(
          id: '${now.microsecondsSinceEpoch}',
          title: _titleFrom(text),
          createdAt: now,
          updatedAt: now,
          messages: const [],
          kind: state.kind,
        );
    final user = ChatMessage(Role.user, text);
    final history = [...base.messages, user];
    final chat = base.copyWith(updatedAt: now, messages: [...history, const ChatMessage(Role.assistant, '')]);
    if (isNew) {
      store.createChat(chat.info);
    } else {
      store.setUpdated(chat.id, now);
    }
    store.addMessage(chat.id, base.messages.length, user);
    _replying = chat;
    state = state.copyWith(
      // (An archived chat stays archived.)
      chats: sortChats([for (final c in state.chats) if (c.id != chat.id) c, state.byId(chat.id)?.withUpdated(now) ?? chat.info]),
      openId: () => chat.id,
      open: () => chat,
      replyingId: () => chat.id,
    );

    _reply = ref.read(backendProvider).reply(chatId: chat.id, model: model, messages: history).listen(
          _appendToReply,
          onError: (Object _) => _finish(),
          onDone: () => _finish(finished: true),
        );
  }

  /// Stops the reply being written; the words so far are kept.
  void stop() {
    _reply?.cancel();
    _finish();
  }

  /// Gives the chat a new title; an empty one keeps the old title. Its place in the list does not change.
  void rename(String id, String title) {
    title = title.trim();
    final info = state.byId(id);
    if (info == null || title.isEmpty || title == info.title) return;
    ref.read(chatStoreProvider).rename(id, title);
    if (_replying?.id == id) _replying = _replying!.copyWith(title: title);
    final open = state.open;
    state = state.copyWith(
      chats: [
        for (final c in state.chats)
          c.id == id ? c.withTitle(title) : c,
      ],
      open: open?.id == id ? () => open!.copyWith(title: title) : null,
    );
  }

  /// Marks the open chat's sent message at [index] as a bookmark, or (when it is one) not any more.
  void toggleBookmark(int index) {
    final chat = state.open;
    if (chat == null || index < 0 || index >= chat.messages.length || chat.messages[index].role != Role.user) return;
    final bookmark = !chat.messages[index].bookmark;
    List<ChatMessage> marked(List<ChatMessage> messages) =>
        [for (var i = 0; i < messages.length; i++) i == index ? messages[i].withBookmark(bookmark) : messages[i]];
    ref.read(chatStoreProvider).setBookmark(chat.id, index, bookmark);
    // The chat being replied to keeps its own copy of the messages: marked there too.
    if (_replying?.id == chat.id) _replying = _replying!.copyWith(messages: marked(_replying!.messages));
    state = state.copyWith(open: () => chat.copyWith(messages: marked(chat.messages)));
  }

  /// Archives the chat: it leaves the list (and Pinned) for Archived, and works as usual there.
  void archive(String id) {
    final info = state.byId(id);
    if (info == null || info.archived) return;
    final now = DateTime.now();
    ref.read(chatStoreProvider).setArchived(id, now, now);
    state = state.copyWith(
      chats: [for (final c in state.chats) c.id == id ? c.withArchived(now, now: now) : c],
      pinned: [for (final p in state.pinned) if (p != id) p],
    );
  }

  /// Brings the chat back to the list, at the top of Today.
  void unarchive(String id) {
    final info = state.byId(id);
    if (info == null || !info.archived) return;
    final now = DateTime.now();
    ref.read(chatStoreProvider).setArchived(id, null, now);
    state = state.copyWith(
        chats: sortChats([for (final c in state.chats) c.id == id ? c.withArchived(null, now: now) : c]));
  }

  /// Pins the chat at the bottom of the pinned ones.
  void pin(String id) {
    if (state.pinned.contains(id)) return;
    _setPins([...state.pinned, id]);
  }

  /// Unpins the chat; it goes back to its place by date.
  void unpin(String id) => _setPins([for (final p in state.pinned) if (p != id) p]);

  /// Moves the pinned chat at [from] so it ends up at [to] (both positions among the shown section's pinned chats).
  void movePin(int from, int to) {
    final pins = [for (final c in state.shownPins) c.id];
    if (from < 0 || from >= pins.length) return;
    final id = pins.removeAt(from);
    pins.insert(to.clamp(0, pins.length), id);
    final mine = state.shownPins.map((c) => c.id).toSet();
    _setPins([for (final p in state.pinned) if (!mine.contains(p)) p, ...pins]);
  }

  /// Moves the chat at [from] to [to] among [day], the chats under one date heading in the order shown. They get
  /// places one after another from the top one's down, so the order stays until one of them gets a new message.
  void moveInDay(List<String> day, int from, int to) {
    final ids = [...day];
    if (from < 0 || from >= ids.length || ids.length < 2) return;
    ids.insert(to.clamp(0, ids.length - 1), ids.removeAt(from));
    final byId = {for (final c in state.chats) c.id: c};
    final top = [for (final id in ids) ?byId[id]?.order].fold(double.negativeInfinity, (a, b) => a > b ? a : b);
    final sorts = {for (var i = 0; i < ids.length; i++) ids[i]: top - i};
    state = state.copyWith(
        chats: sortChats([for (final c in state.chats) sorts.containsKey(c.id) ? c.withSort(sorts[c.id]!) : c]));
    ref.read(chatStoreProvider).setSorts(sorts);
  }

  /// Deletes the chat and its messages. A reply being written in it is stopped first; if it was open, a new chat
  /// opens.
  void delete(String id) {
    if (state.byId(id) == null) return;
    if (state.replyingId == id) {
      _reply?.cancel();
      _reply = null;
      _replying = null;
    }
    ref.read(chatStoreProvider).delete(id);
    _openIn.removeWhere((_, open) => open == id);
    final wasOpen = state.openId == id;
    state = state.copyWith(
      chats: [for (final c in state.chats) if (c.id != id) c],
      pinned: [for (final p in state.pinned) if (p != id) p],
      openId: wasOpen ? () => null : null,
      open: wasOpen ? () => null : null,
      replyingId: state.replyingId == id ? () => null : null,
    );
  }

  void _setPins(List<String> pins) {
    state = state.copyWith(pinned: pins);
    ref.read(chatStoreProvider).setPins(pins);
  }

  void _appendToReply(String piece) {
    final chat = _replying;
    if (chat == null) return;
    final last = chat.messages.last;
    final grown = chat.copyWith(
        messages: [...chat.messages.sublist(0, chat.messages.length - 1), ChatMessage(last.role, last.text + piece)]);
    _replying = grown;
    if (state.openId == grown.id) state = state.copyWith(open: () => grown);
  }

  /// The reply is done (or stopped): it is saved, unless it is still empty. [finished]: it ended by itself (not
  /// stopped, no error), which the bell rings for.
  void _finish({bool finished = false}) {
    _reply = null;
    final chat = _replying;
    _replying = null;
    if (chat == null) {
      state = state.copyWith(replyingId: () => null);
      return;
    }
    final last = chat.messages.last;
    // A reply stopped before its first word leaves no empty message behind.
    final done = last.text.isEmpty ? chat.copyWith(messages: chat.messages.sublist(0, chat.messages.length - 1)) : chat;
    if (last.text.isNotEmpty) ref.read(chatStoreProvider).addMessage(chat.id, chat.messages.length - 1, last);
    if (finished) ref.read(chimeProvider).replyDone();
    state = state.copyWith(replyingId: () => null, open: state.openId == chat.id ? () => done : null);
  }

  static String _titleFrom(String text) {
    final line = text.split('\n').first.trim();
    return line.length <= 40 ? line : '${line.substring(0, 40).trimRight()}…';
  }
}

final chatsProvider = NotifierProvider<ChatsNotifier, ChatsState>(ChatsNotifier.new);

/// Sorts [chats] the way the list shows them: by the day each was last used, the newest day first; within a day
/// by [ChatInfo.order] (where the user dragged it, else when it was last used), the highest first.
List<ChatInfo> sortChats(List<ChatInfo> chats) {
  DateTime day(DateTime t) => DateTime(t.year, t.month, t.day);
  return chats
    ..sort((a, b) {
      final byDay = day(b.updatedAt).compareTo(day(a.updatedAt));
      if (byDay != 0) return byDay;
      final byOrder = b.order.compareTo(a.order);
      return byOrder != 0 ? byOrder : b.id.compareTo(a.id);
    });
}
