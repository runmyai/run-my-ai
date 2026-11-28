import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/backend.dart';
import '../data/chat_store.dart';
import '../data/models.dart';
import '../data/reply_stats.dart';
import '../engine/engine_process.dart';
import '../system/chime.dart';
import 'benchmark.dart';
import 'prefs.dart';
import 'profiles.dart';
import 'library.dart';
import 'providers.dart';
import 'queue.dart';
import 'section.dart';
import 'serve.dart';
import 'thinking.dart';

/// The speed shown under a chat's last reply: while it is written, or its average once [done].
class ShownSpeed {
  const ShownSpeed({required this.chatId, required this.tokensPerSecond, required this.done, this.node});

  final String chatId;
  final double tokensPerSecond;
  final bool done;

  /// The reply it belongs to ([ChatMessage.node]), so it shows under that reply and no other version; null: the
  /// chat's last reply.
  final int? node;
}

/// Where a message of a reply's path sits among the versions of its place: its number ([ChatMessage.node]) and which
/// version it is ([ChatMessage.version]).
typedef ReplyPlace = ({int node, int version});

/// What the arrows of message [index] of [shown] say about the reply being written, whose path is [path]: null when
/// the reply is not under a version of this message; "writing" when the message is the reply itself; "2 writing" when
/// the reply (or what leads to it) is the other version of this place that has that number, the one to flip to.
String? writingLabel(List<ChatMessage> shown, List<ReplyPlace> path, int index) {
  if (index >= path.length || index >= shown.length) return null;
  if (index > 0 && shown[index - 1].node != path[index - 1].node) return null;
  if (shown[index].node != path[index].node) return '${path[index].version + 1} writing';
  return index == path.length - 1 ? 'writing' : null;
}

/// A sent message being edited in the message box: the new version is written in its own branch, whose
/// conversation id is made when the editing starts (the engine may be reading the chat up to the message already).
class Editing {
  const Editing({required this.chatId, required this.node, required this.branch});

  final String chatId;

  /// The message being edited ([ChatMessage.node]).
  final int node;

  /// The conversation id of the new version's branch.
  final String branch;
}

/// A reply the engine could not write, shown in its chat with Try again.
class ReplyFailure {
  const ReplyFailure({
    required this.chatId,
    required this.message,
    required this.log,
    required this.model,
    required this.thinking,
    required this.run,
  });

  final String chatId;
  final String message;

  /// The engine's last lines of output.
  final List<String> log;

  /// What the reply was asked of, to write it again.
  final ModelFile model;
  final bool thinking;
  final EngineRun run;
}

class ChatsState {
  const ChatsState({
    this.kind = ChatKind.chat,
    this.chats = const [],
    this.pinned = const [],
    this.openId,
    this.open,
    this.replyingId,
    this.replyingPath = const [],
    this.loadingModel,
    this.failure,
    this.speed,
    this.editing,
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

  /// Where the reply being written sits in its chat (each message of its path), so the page can tell which version
  /// it is, whichever version of the chat is on screen; empty when none is written.
  final List<ReplyPlace> replyingPath;

  /// The model being loaded before the reply can start; null when none is.
  final String? loadingModel;

  /// The last reply the engine could not write.
  final ReplyFailure? failure;

  /// The speed of the reply being written, or of the last one written.
  final ShownSpeed? speed;

  /// The message being edited in the message box.
  final Editing? editing;

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
    List<ReplyPlace>? replyingPath,
    String? Function()? loadingModel,
    ReplyFailure? Function()? failure,
    ShownSpeed? Function()? speed,
    Editing? Function()? editing,
  }) =>
      ChatsState(
        kind: kind ?? this.kind,
        chats: chats ?? this.chats,
        pinned: pinned ?? this.pinned,
        openId: openId != null ? openId() : this.openId,
        open: open != null ? open() : this.open,
        replyingId: replyingId != null ? replyingId() : this.replyingId,
        replyingPath: replyingPath ?? this.replyingPath,
        loadingModel: loadingModel != null ? loadingModel() : this.loadingModel,
        failure: failure != null ? failure() : this.failure,
        speed: speed != null ? speed() : this.speed,
        editing: editing != null ? editing() : this.editing,
      );
}

/// The chat list, the open chat and the reply being written; every change is saved to the chats database.
/// Only the open chat's messages (and those of the chat being replied to) are kept in memory.
/// Chat and Code each have their own chats, and each keeps its open chat while the user is in the other.
class ChatsNotifier extends Notifier<ChatsState> {
  StreamSubscription<ReplyEvent>? _reply;

  /// The thinking block of the reply being written, once the model has started to think (its clock is in
  /// [thinkingProvider]).
  ThinkingKey? _thinking;

  /// The engine's latest average speed for the reply being written.
  double? _averageSpeed;

  /// How the reply being written went (known when it ends), and what is written it: the model, the profile and the
  /// context length it runs with.
  ReplyStats? _stats;
  ReplyStats? _basis;

  /// The chat whose reply is being written, with its messages, kept here even while another chat is open.
  Chat? _replying;

  /// Saves the reply being written, a moment after it last grew (see [_saveSoon]).
  Timer? _saveTimer;

  /// Whether the reply being written has its message in the database: a flip may go to it or from it, so it is there
  /// by then (empty if need be).
  var _replySaved = false;

  /// The user flipped to a version of the open chat that is not the reply being written: it keeps being written in
  /// the background, and the page keeps what the user chose.
  var _away = false;

  /// A reply being written is saved this often at most, so a closed app or a crash loses little of it.
  static const _saveEvery = Duration(seconds: 1);

  /// The open chat of the section not shown (null = a new chat), opened again when the user comes back to it.
  final _openIn = <ChatKind, String?>{};

  /// The conversation ids of each chat's branches (every id but the chat's own), so pinning, archiving and
  /// deleting reach all of them.
  final _branches = <String, List<String>>{};

  /// The text of the message being edited, kept for the message box to show again if it is rebuilt.
  String? editText;

  /// A version flip is on its way from the database.
  var _flipping = false;

  @override
  ChatsState build() {
    ref.onDispose(() {
      _reply?.cancel();
      _saveTimer?.cancel();
    });
    ref.listen(sectionProvider, (_, section) {
      if (section.kind case final kind?) _show(kind);
    });
    listenSelf((previous, next) {
      if (!identical(previous?.pinned, next.pinned)) _tellPinned(next.pinned);
    });
    final store = ref.read(chatStoreProvider);
    _branches
      ..clear()
      ..addAll({for (final e in store.branches.entries) e.key: [...e.value]});
    _tellPinned(store.pins);
    return ChatsState(
        kind: ref.read(sectionProvider).kind ?? ChatKind.chat, chats: sortChats([...store.chats]), pinned: store.pins);
  }

  /// Shows the chats of [kind], and its open chat from before.
  void _show(ChatKind kind) {
    if (kind == state.kind) return;
    cancelEdit();
    _openIn[state.kind] = state.openId;
    final id = _openIn[kind];
    state = state.copyWith(kind: kind, openId: () => null, open: () => null);
    if (state.byId(id) != null) open(id!);
  }

  void newChat() {
    cancelEdit();
    state = state.copyWith(openId: () => null, open: () => null);
  }

  /// Opens the chat; its messages come from the database (at once for the chat being replied to).
  Future<void> open(String id) async {
    if (state.openId == id && state.open != null) return;
    cancelEdit();
    final replying = _replying;
    // (The version the user flipped to meanwhile comes from the database, as for any chat.)
    if (replying != null && replying.id == id && !_away) {
      state = state.copyWith(openId: () => id, open: () => replying);
      return;
    }
    state = state.copyWith(openId: () => id, open: () => null);
    final path = await ref.read(chatStoreProvider).path(id);
    final info = state.byId(id);
    // Another chat may have been opened (or this one deleted) meanwhile.
    if (!ref.mounted || state.openId != id || state.open != null || info == null) return;
    state = state.copyWith(open: () => _pathChat(info, path));
  }

  /// Opens the chat on the version that holds message [node] (a search result in another version of the chat shows
  /// that version, and the chat opens on it from now on). Returns where the message is among the messages shown;
  /// null if it is not shown (the chat's reply being written stays as it is).
  Future<int?> openAt(String id, int node) async {
    int? indexIn(Chat? chat) {
      final at = chat?.messages.indexWhere((m) => m.node == node) ?? -1;
      return at < 0 ? null : at;
    }

    if (state.openId == id && state.open != null) {
      final at = indexIn(state.open);
      if (at != null || _replying?.id == id) return at;
    }
    final replying = _replying;
    if (replying != null && replying.id == id) {
      await open(id);
      return indexIn(state.open);
    }
    cancelEdit();
    if (state.openId != id) state = state.copyWith(openId: () => id, open: () => null);
    final path = await ref.read(chatStoreProvider).pathTo(id, node);
    final info = state.byId(id);
    if (!ref.mounted || state.openId != id || info == null || path == null || _replying?.id == id) return null;
    final chat = Chat.of(info, path.messages, nextNode: path.nextNode);
    state = state.copyWith(open: () => chat);
    return indexIn(chat);
  }

  /// Shows the version of the open chat's message at [index] that is [step] places after it (before it, for a
  /// negative step), and the messages after that version. Also while a reply is being written in the chat: that
  /// only changes what is shown, the reply goes on in its own version.
  Future<void> flip(int index, int step) async {
    final chat = state.open;
    if (chat == null || _flipping || index < 0 || index >= chat.messages.length) return;
    final node = chat.messages[index].node;
    if (node == null || chat.messages[index].versions < 2) return;
    cancelEdit();
    _saveWritten(chat.id);
    _flipping = true;
    final ChatPath? path;
    try {
      path = await ref.read(chatStoreProvider).flip(chat.id, node, step);
    } finally {
      _flipping = false;
    }
    if (ref.mounted && path != null) _showPath(chat.id, path);
  }

  /// Puts [path] on screen as the open chat's messages, if that chat is still open.
  void _showPath(String id, ChatPath path) {
    final info = state.byId(id);
    if (info == null || state.openId != id) return;
    state = state.copyWith(open: () => _pathChat(info, path));
  }

  /// The chat with the messages of [path]. If the reply being written is among them it is the copy kept here (the
  /// database is a moment behind); if it is not, the user is looking at another version ([_away]).
  Chat _pathChat(ChatInfo info, ChatPath path) {
    final chat = Chat.of(info, path.messages, nextNode: path.nextNode);
    final writing = _replying;
    if (writing == null || writing.id != info.id) return chat;
    final reply = writing.messages.last;
    final at = chat.messages.indexWhere((m) => m.node == reply.node);
    _away = at < 0;
    if (at < 0) return chat;
    return chat.copyWith(
        messages: [...chat.messages.sublist(0, at), reply], nextNode: max(chat.nextNode, writing.nextNode));
  }

  /// Has the reply being written of chat [id] saved if it is not yet, so the database knows it as one of the
  /// versions of its place. It is saved as one that did not get to its end, like every save until it ends.
  void _saveWritten(String id) {
    final chat = _replying;
    if (chat == null || chat.id != id || _replySaved) return;
    _replySaved = true;
    _saveReply(chat, chat.messages.last.asStopped(thinkingMillis: _thinkingMillis()));
  }

  /// Whether a benchmark is running or a model is loading or hosted for other programs: either owns the engine, so no
  /// reply may start or swap it.
  bool get _benchmarking => ref.read(benchmarkProvider).running || ref.read(serveProvider).busy;

  /// Sends [text] in the open chat (a new chat if none is open). Switching chats does not stop the reply.
  void send(String text, ModelFile model) {
    text = text.trim();
    if (text.isEmpty || state.replyingId != null || _benchmarking) return;
    // An opened chat whose messages have not arrived yet (a moment) cannot take a message.
    if (state.openId != null && state.open == null) return;
    final now = DateTime.now();
    final base = state.open ??
        Chat(
          id: '${now.microsecondsSinceEpoch}',
          title: _titleFrom(text),
          createdAt: now,
          updatedAt: now,
          messages: const [],
          kind: state.kind,
        );
    _post(base, text, model, isNew: state.open == null, now: now);
  }

  /// Adds [text] to [base] and has it answered. The chat need not be the one on screen (a waiting message's turn can
  /// come while another chat is open). [branch]: the message is a new version of one in [base]'s place, written in
  /// that conversation, which starts as a copy of [forkFrom]'s (null: it goes on in [base]'s own conversation).
  void _post(Chat base, String text, ModelFile model,
      {required bool isNew, DateTime? now, String? branch, String? forkFrom, int versions = 0}) {
    now ??= DateTime.now();
    final conv = branch ?? base.conversationId;
    final stored = conv == base.id ? null : conv;
    final user = ChatMessage(Role.user, text,
        node: base.nextNode, version: versions, versions: versions + 1, conv: stored);
    final reply = ChatMessage(Role.assistant, '', node: base.nextNode + 1, conv: stored);
    final chat = base.copyWith(updatedAt: now, messages: [...base.messages, user, reply], nextNode: base.nextNode + 2);
    // (A new version of the chat's first message shares nothing with the old one: no state to copy.)
    _begin(chat, model, isNew: isNew, now: now, sent: user, forkFrom: forkFrom, copyState: base.messages.isNotEmpty);
  }

  /// Has the reply written, which is the last message of [chat] (empty), to the message before it. [sent]: that
  /// message is new and is saved first. [forkFrom]: the reply's conversation is a new branch, a copy of [forkFrom]'s
  /// ([copyState] false: the branch shares nothing with it, so nothing is copied).
  void _begin(Chat chat, ModelFile model,
      {required bool isNew, required DateTime now, ChatMessage? sent, String? forkFrom, bool copyState = true}) {
    final store = ref.read(chatStoreProvider);
    final history = chat.messages.sublist(0, chat.messages.length - 1);
    final thinking = ref.read(prefsProvider).thinking;
    final info = state.byId(chat.id) ?? chat.info;
    final run = ref.read(profilesProvider.notifier).runFor(model, _contextFor(info, model));
    if (isNew) {
      store.createChat(chat.info);
    } else {
      store.setUpdated(chat.id, now);
    }
    store.setChoices(chat.id, model.id, run.contextLength);
    if (sent != null) store.addMessage(chat.id, sent.node!, sent, parent: _parentOf(history, history.length - 1));
    if (forkFrom != null) _startBranch(chat, forkFrom, copyState: copyState);
    _replying = chat;
    final onScreen = isNew || state.openId == chat.id;
    state = state.copyWith(
      // (An archived chat stays archived.)
      chats: sortChats([for (final c in state.chats) if (c.id != chat.id) c, info.withUpdated(now).withChoices(modelId: model.id, contextLength: run.contextLength)]),
      openId: onScreen ? () => chat.id : null,
      open: onScreen ? () => chat : null,
      replyingId: () => chat.id,
      replyingPath: _placesOf(chat.messages),
      failure: () => null,
      speed: () => null,
    );
    _writeReply(chat, _forModel(history), model, thinking, run);
  }

  /// Where each of [messages] sits among the versions of its place.
  static List<ReplyPlace> _placesOf(List<ChatMessage> messages) =>
      [for (final m in messages) (node: m.node ?? -1, version: m.version)];

  /// The number of the message that message [index] of [messages] follows, as the database takes it.
  static int _parentOf(List<ChatMessage> messages, int index) =>
      index <= 0 ? ChatStore.noParent : messages[index - 1].node ?? ChatStore.noParent;

  /// [chat]'s last message starts a branch: its conversation is noted for pinning and erasing, and the engine is
  /// told to copy [from]'s saved state to it before its first request.
  void _startBranch(Chat chat, String from, {required bool copyState}) {
    final branch = chat.conversationId;
    final branches = _branches.putIfAbsent(chat.id, () => []);
    if (!branches.contains(branch)) {
      branches.add(branch);
      if (state.pinned.contains(chat.id)) _tellPinned(state.pinned);
    }
    final backend = ref.read(backendProvider);
    if (copyState && backend is BranchControl) (backend as BranchControl).forkBeforeFirstUse(from, branch);
  }

  /// A conversation id for a new branch of chat [chatId].
  String _newBranch(String chatId) {
    var micros = DateTime.now().microsecondsSinceEpoch;
    while (_branches[chatId]?.contains('$chatId-b$micros') ?? false) {
      micros++;
    }
    return '$chatId-b$micros';
  }

  // ---- Editing a message and writing a reply again ------------------------------------------------------------

  /// Starts editing the open chat's sent message at [index]: its text goes to the message box (the message box
  /// shows [editText]) and the new version will be written in a branch of its own. When the message is older than
  /// the chat's latest exchange and the engine already has [model] loaded the way the chat runs it, the engine reads
  /// the chat up to the message now, so the new version's reply starts at once. Not while a reply or a benchmark
  /// runs.
  void beginEdit(int index, ModelFile? model) {
    final chat = state.open;
    if (chat == null || state.replyingId != null || _benchmarking || index < 0 || index >= chat.messages.length) return;
    final message = chat.messages[index];
    final node = message.node;
    if (message.role != Role.user || node == null) return;
    if (state.editing != null) {
      if (state.editing!.chatId == chat.id && state.editing!.node == node) return;
      cancelEdit();
    }
    final edit = Editing(chatId: chat.id, node: node, branch: _newBranch(chat.id));
    editText = message.text;
    state = state.copyWith(editing: () => edit);
    final backend = ref.read(backendProvider);
    final latest = chat.messages.lastIndexWhere((m) => m.role == Role.user);
    if (model == null || index == 0 || index >= latest || backend is! BranchControl) return;
    final run = ref.read(profilesProvider.notifier).runFor(model, _contextFor(state.byId(chat.id) ?? chat.info, model));
    unawaited((backend as BranchControl).readAhead(
      from: chat.conversationId,
      to: edit.branch,
      model: model,
      run: run,
      messages: _forModel(chat.messages.sublist(0, index)),
      thinking: ref.read(prefsProvider).thinking,
    ));
  }

  /// Ends the editing without a new version: any read ahead stops and its saved state is erased.
  void cancelEdit() {
    final edit = state.editing;
    if (edit == null) return;
    editText = null;
    state = state.copyWith(editing: () => null);
    final backend = ref.read(backendProvider);
    if (backend is BranchControl) unawaited((backend as BranchControl).cancelReadAhead(edit.branch));
  }

  /// Sends [text] as the new version of the message being edited, with a reply to it in the branch made for it. What
  /// came after the old version stays with it.
  void sendEdit(String text, ModelFile model) {
    text = text.trim();
    final edit = state.editing;
    final chat = state.open;
    if (edit == null || chat == null || chat.id != edit.chatId || text.isEmpty) return;
    if (state.replyingId != null || _benchmarking) return;
    final index = chat.messages.indexWhere((m) => m.node == edit.node);
    if (index < 0) return cancelEdit();
    editText = null;
    state = state.copyWith(editing: () => null);
    _post(chat.copyWith(messages: chat.messages.sublist(0, index)), text, model,
        isNew: false,
        branch: edit.branch,
        forkFrom: chat.conversationId,
        versions: chat.messages[index].versions);
  }

  /// Writes the reply at [index] of the open chat again, from the same messages before it, as a new version of it
  /// in a branch of its own (on an older reply too: the messages after the old version stay with it).
  void regenerate(int index, ModelFile model) {
    final chat = state.open;
    if (chat == null || state.replyingId != null || _benchmarking || index < 1 || index >= chat.messages.length) return;
    final old = chat.messages[index];
    if (old.role != Role.assistant || chat.messages[index - 1].role != Role.user) return;
    cancelEdit();
    final now = DateTime.now();
    final branch = _newBranch(chat.id);
    final reply = ChatMessage(Role.assistant, '',
        node: chat.nextNode, version: old.versions, versions: old.versions + 1, conv: branch);
    final next = chat.copyWith(
        updatedAt: now, messages: [...chat.messages.sublist(0, index), reply], nextNode: chat.nextNode + 1);
    _begin(next, model, isNew: false, now: now, forkFrom: chat.conversationId);
  }

  void _writeReply(Chat chat, List<ChatMessage> history, ModelFile model, bool thinking, EngineRun run) {
    _basis = ReplyStats(
      modelName: ref.read(catalogFilesProvider)[model.id]?.model.name,
      profileName: ref.read(profilesProvider.notifier).active(model).name,
      contextLength: run.contextLength,
    );
    _reply = ref
        .read(backendProvider)
        .reply(chatId: chat.conversationId, model: model, messages: history, thinking: thinking, run: run)
        .listen(
          _onReply,
          onError: (Object error) {
            final failure = error is EngineFailure ? error : EngineFailure('$error');
            _finish(failed: true);
            state = state.copyWith(
              failure: () => ReplyFailure(
                chatId: chat.id,
                message: failure.message,
                log: failure.log,
                model: model,
                thinking: thinking,
                run: run,
              ),
            );
            ref.read(queueProvider.notifier).hold(chat.id, QueueHold.failed);
          },
          onDone: () => _finish(finished: true),
        );
  }

  /// Writes the failed reply of [ReplyFailure] again; what it wrote before failing is replaced.
  void retry() {
    final failure = state.failure;
    final open = state.open;
    if (failure == null || state.replyingId != null || _benchmarking || open == null || open.id != failure.chatId) return;
    final failed = open.messages.isNotEmpty && open.messages.last.role == Role.assistant ? open.messages.last : null;
    final kept = failed == null ? open.messages : open.messages.sublist(0, open.messages.length - 1);
    if (failed?.node case final node?) {
      ref.read(chatStoreProvider).removeMessage(open.id, node);
      ref.read(thinkingProvider.notifier).forget((chatId: open.id, index: node));
    }
    final reply = ChatMessage(Role.assistant, '',
        node: open.nextNode,
        version: failed?.version ?? 0,
        versions: failed?.versions ?? 1,
        conv: failed != null ? failed.conv : kept.lastOrNull?.conv);
    final chat = open.copyWith(messages: [...kept, reply], nextNode: open.nextNode + 1);
    _replying = chat;
    state = state.copyWith(
        open: () => chat,
        replyingId: () => chat.id,
        replyingPath: _placesOf(chat.messages),
        failure: () => null,
        speed: () => null);
    ref.read(queueProvider.notifier).release(chat.id, only: QueueHold.failed);
    _writeReply(chat, _forModel(kept), failure.model, failure.thinking, failure.run);
  }

  /// Stops the reply being written; the words so far are kept.
  void stop() {
    final id = state.replyingId;
    _reply?.cancel();
    _finish();
    if (id != null) ref.read(queueProvider.notifier).hold(id, QueueHold.stopped);
  }

  /// Tells the engine which chats' saved states to keep longest: every branch of a pinned chat.
  void _tellPinned(List<String> pinned) {
    final backend = ref.read(backendProvider);
    if (backend is! EngineControl) return;
    unawaited((backend as EngineControl).setPinnedChats([
      for (final id in pinned) ...[id, ...?_branches[id]],
    ]));
  }

  /// Deletes the chat's saved states and snapshots, those of every branch too.
  void _eraseState(String id) {
    final backend = ref.read(backendProvider);
    if (backend is! EngineControl) return;
    for (final conversation in [id, ...?_branches[id]]) {
      unawaited((backend as EngineControl).eraseChatState(conversation));
    }
  }

  /// The length [model] runs with for the chat [info]: its own, or the one last picked, as far as the model can.
  int _contextFor(ChatInfo info, ModelFile model) => closestContext(
    ref.read(profilesProvider.notifier).active(model).lengths,
    info.contextLength ?? ref.read(libraryProvider).contextLength,
  );

  /// The user picked a model: it is the one new chats start with, and from now on the open chat's. Nothing loads.
  void pickModel(String fileId) {
    ref.read(libraryProvider.notifier).pick(fileId);
    final info = state.byId(state.openId);
    if (info != null) _setChoices(info.withChoices(modelId: fileId, contextLength: info.contextLength));
  }

  /// The user picked a context length: the open chat's from now on, and what new chats start with.
  void pickContext(int contextLength) {
    ref.read(libraryProvider.notifier).pickContext(contextLength);
    final info = state.byId(state.openId);
    if (info != null) _setChoices(info.withChoices(modelId: info.modelId, contextLength: contextLength));
  }

  void _setChoices(ChatInfo info) {
    ref.read(chatStoreProvider).setChoices(info.id, info.modelId, info.contextLength);
    state = state.copyWith(chats: [for (final c in state.chats) c.id == info.id ? info : c]);
  }

  /// Starts the open chat's waiting messages again: the first goes out now, the rest after it.
  void sendQueued(ModelFile model) {
    final open = state.open;
    if (open == null || state.replyingId != null || _benchmarking) return;
    final queue = ref.read(queueProvider.notifier)..release(open.id);
    final text = queue.take(open.id);
    if (text != null) _post(open, text, model, isNew: false);
  }

  /// After a reply in [chat] ended by itself: the next waiting message, unless the queue is on hold.
  void _sendNextQueued(Chat chat) {
    final queue = ref.read(queueProvider.notifier);
    if (ref.read(queueProvider)[chat.id]?.hold != null) return;
    final model = ref.read(catalogFilesProvider)[state.byId(chat.id)?.modelId]?.file ?? ref.read(pickedModelProvider)?.file;
    if (model == null) return queue.hold(chat.id, QueueHold.stopped);
    final text = queue.take(chat.id);
    if (text != null) _post(chat, text, model, isNew: false);
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
    final node = chat.messages[index].node;
    if (node == null) return;
    final bookmark = !chat.messages[index].bookmark;
    List<ChatMessage> marked(List<ChatMessage> messages) =>
        [for (var i = 0; i < messages.length; i++) messages[i].node == node ? messages[i].withBookmark(bookmark) : messages[i]];
    ref.read(chatStoreProvider).setBookmark(chat.id, node, bookmark);
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
    _eraseState(id);
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
    if (state.editing?.chatId == id) cancelEdit();
    if (state.replyingId == id) {
      _reply?.cancel();
      _forgetReply();
    }
    ref.read(chatStoreProvider).delete(id);
    ref.read(thinkingProvider.notifier).forgetFrom(id);
    ref.read(queueProvider.notifier).forget(id);
    _eraseState(id);
    _branches.remove(id);
    _openIn.removeWhere((_, open) => open == id);
    final wasOpen = state.openId == id;
    state = state.copyWith(
      chats: [for (final c in state.chats) if (c.id != id) c],
      pinned: [for (final p in state.pinned) if (p != id) p],
      openId: wasOpen ? () => null : null,
      open: wasOpen ? () => null : null,
      replyingId: state.replyingId == id ? () => null : null,
      replyingPath: state.replyingId == id ? const [] : null,
      loadingModel: state.replyingId == id ? () => null : null,
      speed: state.speed?.chatId == id ? () => null : null,
    );
  }

  void _setPins(List<String> pins) {
    state = state.copyWith(pinned: pins);
    ref.read(chatStoreProvider).setPins(pins);
  }

  void _onReply(ReplyEvent event) {
    switch (event) {
      case ReplyLoading(:final modelName):
        state = state.copyWith(loadingModel: () => modelName);
      case ReplyLoaded():
        state = state.copyWith(loadingModel: () => null);
      case ReplyDone(:final timings, :final wordMillis):
        final basis = _basis;
        _stats = ReplyStats.fromTimings(
          timings,
          wordMillis: wordMillis,
          modelName: basis?.modelName,
          profileName: basis?.profileName,
          contextLength: basis?.contextLength,
        );
      case ReplyProgress():
        break;
      case ReplySpeed(:final live, :final average):
        _averageSpeed = average ?? _averageSpeed;
        final chatId = _replying?.id;
        if (live != null && chatId != null) {
          state = state.copyWith(
              speed: () => ShownSpeed(
                  chatId: chatId, tokensPerSecond: live, done: false, node: _replying?.messages.last.node));
        }
      case ReplyThinking(:final text):
        _beginThinking();
        _growReply((m) => m.copyWith(thinking: m.thinking + text));
      case ReplyText(:final text):
        _growReply((m) => m.copyWith(text: m.text + text, thinkingMillis: m.thinkingMillis ?? _thinkingMillis()));
    }
  }

  /// The model has started to think for the reply being written: its clock starts (once).
  void _beginThinking() {
    final chat = _replying;
    if (chat == null || _thinking != null) return;
    final key = (chatId: chat.id, index: chat.messages.last.node ?? chat.messages.length - 1);
    ref.read(thinkingProvider.notifier).begin(key);
    _thinking = key;
  }

  /// How long the model has thought for the reply being written; null before it starts.
  int? _thinkingMillis() {
    final key = _thinking;
    return key == null ? null : ref.read(thinkingProvider.notifier).elapsedMillis(key);
  }

  void _growReply(ChatMessage Function(ChatMessage) grow) {
    final chat = _replying;
    if (chat == null) return;
    final grown = chat.copyWith(messages: [...chat.messages.sublist(0, chat.messages.length - 1), grow(chat.messages.last)]);
    _replying = grown;
    // (Not while the user looks at another version: the reply grows in the background.)
    if (state.openId == grown.id && !_away) state = state.copyWith(open: () => grown);
    _saveSoon();
  }

  /// Has the reply so far saved once [_saveEvery] has passed (if it has not been already).
  void _saveSoon() => _saveTimer ??= Timer(_saveEvery, () {
    _saveTimer = null;
    final chat = _replying;
    final last = chat?.messages.last;
    if (chat == null || last == null || (last.text.isEmpty && last.thinking.isEmpty)) return;
    _replySaved = true;
    // Until it ends it is saved as one that did not get to its end (the end saves it again as it is).
    _saveReply(chat, last.asStopped(thinkingMillis: _thinkingMillis()));
  });

  /// Saves [reply], the last message of [chat], after the message before it.
  void _saveReply(Chat chat, ChatMessage reply) => ref
      .read(chatStoreProvider)
      .addMessage(chat.id, reply.node ?? chat.messages.length - 1, reply, parent: _parentOf(chat.messages, chat.messages.length - 1));

  /// Lets go of the reply being written: its stream, its thinking time, its speed and its pending save.
  void _forgetReply() {
    _reply = null;
    _replying = null;
    _thinking = null;
    _averageSpeed = null;
    _stats = null;
    _basis = null;
    _replySaved = false;
    _away = false;
    _saveTimer?.cancel();
    _saveTimer = null;
  }

  /// What the model is sent of [messages]: a reply with no words (a stopped thought) is left out, as a reply
  /// stopped before its first word always was.
  static List<ChatMessage> _forModel(List<ChatMessage> messages) => [
    for (final m in messages)
      if (m.role != Role.assistant || m.text.isNotEmpty) m,
  ];

  /// The reply is done (or stopped): it is saved, unless it is still empty. A reply with thinking but no words
  /// stays, marked stopped, so what the model thought can be read. [finished]: it ended by itself (not stopped, no
  /// error), which the bell rings for. The version on screen stays, wherever the user flipped to, unless the reply
  /// [failed]: its Retry is under the failed reply, so that is shown.
  void _finish({bool finished = false, bool failed = false}) {
    final chat = _replying;
    final average = _averageSpeed;
    final stats = _stats;
    final thoughtFor = _thinkingMillis();
    final away = _away && !failed;
    final saved = _replySaved;
    _forgetReply();
    if (chat != null) {
      state = state.copyWith(
        speed: () => average == null
            ? null
            : ShownSpeed(chatId: chat.id, tokensPerSecond: average, done: true, node: chat.messages.last.node),
      );
    }
    if (chat == null) {
      state = state.copyWith(replyingId: () => null, replyingPath: const [], loadingModel: () => null);
      return;
    }
    final last = chat.messages.last;
    // A reply stopped before its first word leaves no empty message behind, unless it thought.
    final thought = last.text.isEmpty && last.thinking.isNotEmpty;
    final keep = last.text.isNotEmpty || thought;
    final message = (thought ? last.asStopped(thinkingMillis: thoughtFor) : last).copyWith(stats: stats);
    final done = chat.copyWith(messages: [...chat.messages.sublist(0, chat.messages.length - 1), if (keep) message]);
    if (keep) {
      _saveReply(chat, message);
    } else if (saved && last.node != null) {
      // Saved empty when the user flipped while it was written: it goes again.
      ref.read(chatStoreProvider).removeMessage(chat.id, last.node!);
    }
    if (finished) {
      ref.read(chimeProvider).replyDone();
      ref.read(prefsProvider.notifier).countReply();
    }
    state = state.copyWith(
      replyingId: () => null,
      replyingPath: const [],
      loadingModel: () => null,
      open: state.openId == chat.id && !away ? () => done : null,
    );
    if (!keep) _forgetDropped(chat);
    // Archived while its reply was written: the reply's state goes too.
    if (state.byId(chat.id)?.archived ?? false) _eraseState(chat.id);
    if (finished) _sendNextQueued(done);
  }

  /// The reply that was the last message of [chat] was dropped, empty. If it was a new version of a reply, the
  /// version shown before comes back, and the branch made for it goes (nothing is saved under it).
  void _forgetDropped(Chat chat) {
    final dropped = chat.messages.last;
    if (dropped.versions < 2) return;
    unawaited(ref.read(chatStoreProvider).path(chat.id).then((path) {
      if (ref.mounted && state.replyingId == null) _showPath(chat.id, path);
    }));
    final branch = dropped.conv;
    if (branch == null || chat.messages.length < 2 || chat.messages[chat.messages.length - 2].conv == branch) return;
    _branches[chat.id]?.remove(branch);
    final backend = ref.read(backendProvider);
    if (backend is EngineControl) unawaited((backend as EngineControl).eraseChatState(branch));
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
