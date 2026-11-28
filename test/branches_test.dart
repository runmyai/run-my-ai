// Editing a message and writing a reply again (ChatsNotifier): each makes a new version in a branch of its own, every
// version keeps its later messages, flipping shows a version and what follows it, what is sent to the engine is the
// path shown, each branch has its own conversation id (copied from the one it came from), an edit of an old message
// starts the engine reading ahead, and pins, archiving and deleting reach every branch. Versions can be flipped while a
// reply is written: only what is shown changes, the reply goes on in its own version and is saved as usual.
// Run: flutter test test/branches_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/engine_process.dart';
import 'package:runmyai/state/benchmark.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/providers.dart';

/// What the engine was asked, and replies that stay open until the test ends them.
class _Backend implements Backend, EngineControl, BranchControl {
  /// Each reply asked for: its conversation id and the texts sent.
  final asked = <({String conversation, List<String> texts})>[];
  final replies = <StreamController<ReplyEvent>>[];
  final forks = <(String, String)>[];
  final readAheads = <({String from, String to, List<String> texts})>[];
  final cancelled = <String>[];
  final erased = <String>[];
  List<String>? pinned;

  /// Whether the engine has the model loaded, so a read ahead may start.
  var loaded = true;

  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) {
    asked.add((conversation: chatId, texts: [for (final m in messages) m.text]));
    final reply = StreamController<ReplyEvent>();
    replies.add(reply);
    return reply.stream;
  }

  @override
  void forkBeforeFirstUse(String from, String to) => forks.add((from, to));

  @override
  Future<bool> readAhead({
    required String from,
    required String to,
    required ModelFile model,
    required EngineRun run,
    required List<ChatMessage> messages,
    bool thinking = false,
  }) async {
    if (!loaded) return false;
    readAheads.add((from: from, to: to, texts: [for (final m in messages) m.text]));
    return true;
  }

  @override
  Future<void> cancelReadAhead(String conversationId) async => cancelled.add(conversationId);
  @override
  Future<void> eraseChatState(String chatId) async => erased.add(chatId);
  @override
  Future<void> setPinnedChats(List<String> chatIds) async => pinned = chatIds;
  @override
  Future<String?> reportedVersion() async => null;
  @override
  Future<void> startEngine(ModelFile file, EngineRun run, {bool restart = false}) async {}
  @override
  Future<void> stopEngine() async {}
  @override
  ValueListenable<EngineState> get engineState => ValueNotifier(const EngineState(EnginePhase.ready));
  @override
  List<String> get logLines => const [];
  @override
  Listenable get logChanged => ChangeNotifier();
  @override
  Map<int, String> autoCommands(ModelFile file) => const {defaultContextLength: '-c $defaultContextLength'};
  @override
  int maxContext(ModelFile file) => defaultContextLength;
  @override
  Future<List<CatalogModel>> loadCatalog() async => const [];
  @override
  Stream<double> download(ModelFile file) => const Stream.empty();
  @override
  Future<void> deleteDownload(ModelFile file) async {}
}

/// A benchmark that is on or off as the test says.
class _Benchmark extends BenchmarkNotifier {
  @override
  BenchmarkState build() => const BenchmarkState();

  void run(bool on) => state = BenchmarkState(phase: on ? BenchmarkPhase.measuring : BenchmarkPhase.idle);
}

void main() {
  const file = ModelFile(id: 'm/f', quantization: 'q', sizeBytes: 1);
  const model = CatalogModel(
    id: 'm',
    name: 'M',
    lab: 'L',
    madeBy: '',
    country: '',
    released: '',
    type: '',
    input: '',
    output: '',
    maxContext: '',
    parameters: '1B',
    activeParameters: '1B',
    files: [file],
  );
  late Directory dir;
  late ChatStore store;
  late _Backend backend;
  late ProviderContainer container;
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 25));

  ChatsNotifier chats() => container.read(chatsProvider.notifier);
  ChatsState state() => container.read(chatsProvider);
  List<String> shown() => [for (final m in state().open!.messages) m.text];
  List<(int, int)> versions() => [for (final m in state().open!.messages) (m.version, m.versions)];

  /// Ends the reply being written, after [text].
  Future<void> finish([String text = 'reply']) async {
    final reply = backend.replies.last;
    reply.add(ReplyText(text));
    await reply.close();
    await settle();
  }

  /// Sends [text] and has it answered with "A" plus its number.
  Future<void> exchange(String text, String answer) async {
    chats().send(text, file);
    await finish(answer);
  }

  /// A chat of three exchanges: one / A1, two / A2, three / A3.
  Future<String> threeExchanges() async {
    await exchange('one', 'A1');
    await exchange('two', 'A2');
    await exchange('three', 'A3');
    return state().openId!;
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('runmyai-branches-');
    store = await ChatStore.open(dir);
    backend = _Backend();
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        chatStoreProvider.overrideWithValue(store),
        backendProvider.overrideWithValue(backend),
        pickedModelProvider.overrideWithValue((model: model, file: file)),
        benchmarkProvider.overrideWith(_Benchmark.new),
      ],
    );
    await settle();
  });

  tearDown(() async {
    container.dispose();
    await store.close();
    dir.deleteSync(recursive: true);
  });

  group('editing a message', () {
    test('makes a new version in a branch of its own, and sends only the path to it', () async {
      final id = await threeExchanges();
      expect(shown(), ['one', 'A1', 'two', 'A2', 'three', 'A3']);
      expect(backend.asked.every((a) => a.conversation == id), isTrue, reason: 'one conversation, the chat\'s own');

      chats().beginEdit(2, file);
      expect(state().editing?.node, 2);
      expect(chats().editText, 'two');
      chats().sendEdit('two, edited', file);
      expect(state().editing, isNull);
      final branch = backend.asked.last.conversation;
      expect(branch, isNot(id));
      expect(backend.asked.last.texts, ['one', 'A1', 'two, edited'], reason: 'the path only, not what followed the old one');
      expect(backend.forks, [(id, branch)], reason: 'the new conversation starts as a copy of the old');

      await finish('B2');
      expect(shown(), ['one', 'A1', 'two, edited', 'B2']);
      expect(versions(), [(0, 1), (0, 1), (1, 2), (0, 1)]);
      expect(state().open!.conversationId, branch);

      // Going on in this branch stays in its conversation, with no new copy.
      await exchange('four', 'B4');
      expect(backend.asked.last.conversation, branch);
      expect(backend.asked.last.texts, ['one', 'A1', 'two, edited', 'B2', 'four']);
      expect(backend.forks, hasLength(1));
    });

    test('every version keeps its later messages, and flipping shows a version with what follows it', () async {
      await threeExchanges();
      chats().beginEdit(2, file);
      chats().sendEdit('two, edited', file);
      await finish('B2');

      await chats().flip(2, -1);
      expect(shown(), ['one', 'A1', 'two', 'A2', 'three', 'A3']);
      expect(versions()[2], (0, 2));
      await chats().flip(2, -1);
      expect(versions()[2], (0, 2), reason: 'no version before the first');
      await chats().flip(2, 1);
      expect(shown(), ['one', 'A1', 'two, edited', 'B2']);

      // Sending in the original version goes on in its own conversation.
      await chats().flip(2, -1);
      final id = state().openId!;
      await exchange('four', 'A4');
      expect(backend.asked.last.conversation, id);
      expect(backend.asked.last.texts.last, 'four');
      expect(backend.forks, hasLength(1));
    });

    test('the version left on is the one the chat opens on again', () async {
      final id = await threeExchanges();
      chats().beginEdit(2, file);
      chats().sendEdit('two, edited', file);
      await finish('B2');
      await chats().flip(2, -1);
      chats().newChat();
      await chats().open(id);
      expect(shown(), ['one', 'A1', 'two', 'A2', 'three', 'A3']);
      await chats().flip(2, 1);
      chats().newChat();
      await chats().open(id);
      expect(shown(), ['one', 'A1', 'two, edited', 'B2']);
      expect(state().open!.nextNode, 8);
    });

    test('the first message edited starts the chat over, and no state is copied', () async {
      final id = await threeExchanges();
      chats().beginEdit(0, file);
      expect(backend.readAheads, isEmpty);
      chats().sendEdit('zero', file);
      await finish('Z');
      expect(shown(), ['zero', 'Z']);
      expect(backend.asked.last.conversation, isNot(id));
      expect(backend.forks, isEmpty);
      await chats().flip(0, -1);
      expect(shown(), ['one', 'A1', 'two', 'A2', 'three', 'A3']);
    });

    test('only a sent message can be edited, and not while a reply or a benchmark runs', () async {
      await exchange('one', 'A1');
      chats().beginEdit(1, file);
      expect(state().editing, isNull, reason: 'a reply is not edited');
      chats().send('two', file);
      chats().beginEdit(0, file);
      expect(state().editing, isNull, reason: 'a reply is being written');
      await finish('A2');
      final benchmark = container.read(benchmarkProvider.notifier) as _Benchmark..run(true);
      chats().beginEdit(0, file);
      chats().regenerate(3, file);
      expect(state().editing, isNull);
      expect(backend.asked, hasLength(2));
      benchmark.run(false);
      chats().beginEdit(0, file);
      expect(state().editing, isNotNull);
    });
  });

  group('flipping while a reply is written', () {
    /// A chat of one exchange whose reply is being written again (still empty).
    Future<void> writingAgain() async {
      await exchange('one', 'A1');
      chats().regenerate(1, file);
    }

    Future<void> write(ReplyEvent event) async {
      backend.replies.last.add(event);
      await settle();
    }

    test('what is shown changes, and the reply goes on in its own version', () async {
      await writingAgain();
      await chats().flip(1, -1);
      expect(shown(), ['one', 'A1']);
      expect(versions().last, (0, 2));
      expect(state().replyingId, state().openId);
      await write(const ReplyText('A1b so far'));
      expect(shown(), ['one', 'A1'], reason: 'the reply grows in the background');
      await chats().flip(1, 1);
      expect(shown(), ['one', 'A1b so far']);
      await write(const ReplyText(' and more'));
      expect(shown(), ['one', 'A1b so far and more']);
    });

    test('when writing ends the view stays on the version chosen, and the reply is saved', () async {
      await writingAgain();
      final id = state().openId!;
      await chats().flip(1, -1);
      await write(const ReplyText('A1b'));
      await finish(' done');
      expect(state().replyingId, isNull);
      expect(state().replyingPath, isEmpty);
      expect(shown(), ['one', 'A1']);
      chats().newChat();
      await chats().open(id);
      expect(shown(), ['one', 'A1'], reason: 'the chat opens on the version left on');
      await chats().flip(1, 1);
      expect(shown(), ['one', 'A1b done']);
    });

    test('leaving the chat and coming back shows the version chosen, the reply still going on', () async {
      await writingAgain();
      final id = state().openId!;
      await chats().flip(1, -1);
      chats().newChat();
      await chats().open(id);
      expect(shown(), ['one', 'A1']);
      await write(const ReplyText('A1b'));
      expect(shown(), ['one', 'A1']);
      await chats().flip(1, 1);
      chats().newChat();
      await chats().open(id);
      expect(shown(), ['one', 'A1b'], reason: 'flipped back to the reply, which is the version shown now');
    });

    test('Stop stops the reply wherever the user is looking, and keeps the words so far', () async {
      await writingAgain();
      await chats().flip(1, -1);
      await write(const ReplyText('A1b so far'));
      final reply = backend.replies.last;
      chats().stop();
      await settle();
      expect(reply.hasListener, isFalse);
      expect(state().replyingId, isNull);
      expect(shown(), ['one', 'A1']);
      await chats().flip(1, 1);
      expect(shown(), ['one', 'A1b so far']);
    });

    test('Edit, Regenerate and Send stay blocked while it runs, whichever version is shown', () async {
      await writingAgain();
      await chats().flip(1, -1);
      expect(backend.asked, hasLength(2));
      chats().regenerate(1, file);
      chats().beginEdit(0, file);
      chats().send('two', file);
      expect(backend.asked, hasLength(2));
      expect(state().editing, isNull);
      expect(shown(), ['one', 'A1']);
    });

    test('a message before the reply can be flipped too, and the reply stays in its own version', () async {
      await exchange('one', 'A1');
      await exchange('two', 'A2');
      chats().beginEdit(2, file);
      chats().sendEdit('two, edited', file);
      await chats().flip(2, -1);
      expect(shown(), ['one', 'A1', 'two', 'A2']);
      expect(writingLabel(state().open!.messages, state().replyingPath, 2), '2 writing');
      await write(const ReplyText('B2'));
      expect(shown(), ['one', 'A1', 'two', 'A2']);
      await chats().flip(2, 1);
      expect(shown(), ['one', 'A1', 'two, edited', 'B2']);
      expect(writingLabel(state().open!.messages, state().replyingPath, 3), 'writing');
    });

    test('the thinking and the speed belong to the reply being written, not to what is shown', () async {
      await writingAgain();
      await chats().flip(1, -1);
      await write(const ReplyThinking('hmm'));
      await write(const ReplySpeed(live: 12));
      expect(state().speed!.node, state().replyingPath.last.node);
      expect(state().open!.messages.last.thinking, isEmpty);
      await chats().flip(1, 1);
      expect(state().open!.messages.last.thinking, 'hmm');
      expect(state().open!.messages.last.node, state().speed!.node);
    });

    test('a reply stopped before its first word goes again, and the version shown stays', () async {
      await writingAgain();
      final id = state().openId!;
      await chats().flip(1, -1);
      chats().stop();
      await settle();
      expect(shown(), ['one', 'A1']);
      expect(versions().last, (0, 1));
      chats().newChat();
      await chats().open(id);
      expect(versions().last, (0, 1), reason: 'nothing is left in the database either');
    });

    test('a reply that fails brings its version up, where the Retry for it is', () async {
      await writingAgain();
      await chats().flip(1, -1);
      await write(const ReplyText('A1b'));
      backend.replies.last.addError(const EngineFailure('boom'));
      await settle();
      expect(state().failure, isNotNull);
      expect(shown(), ['one', 'A1b']);
    });

    test('the label on the arrows: "writing" on the reply, the number to flip to elsewhere', () {
      ChatMessage message(Role role, int node, int version, int versions) =>
          ChatMessage(role, '', node: node, version: version, versions: versions);
      // The reply being written: message 5, the second version of its place, under message 4.
      const path = <ReplyPlace>[(node: 0, version: 0), (node: 1, version: 0), (node: 2, version: 0), (node: 5, version: 1)];
      final same = [
        message(Role.user, 0, 0, 1),
        message(Role.assistant, 1, 0, 1),
        message(Role.user, 2, 0, 1),
        message(Role.assistant, 5, 1, 2),
      ];
      expect([for (var i = 0; i < 4; i++) writingLabel(same, path, i)], [null, null, null, 'writing']);
      final reply = [...same.sublist(0, 3), message(Role.assistant, 3, 0, 2)];
      expect([for (var i = 0; i < 4; i++) writingLabel(reply, path, i)], [null, null, null, '2 writing']);
      // Flipped at an earlier place: only that place says it; what follows is another line of messages.
      final earlier = [message(Role.user, 0, 0, 1), message(Role.assistant, 1, 0, 1), message(Role.user, 7, 1, 2), message(Role.assistant, 8, 0, 1)];
      expect([for (var i = 0; i < 4; i++) writingLabel(earlier, path, i)], [null, null, '1 writing', null]);
      expect(writingLabel(same, const [], 3), isNull);
    });
  });

  group('writing a reply again', () {
    test('on the latest reply: a new version, from the same messages, in its own conversation', () async {
      await exchange('one', 'A1');
      await exchange('two', 'A2');
      final id = state().openId!;
      chats().regenerate(3, file);
      final branch = backend.asked.last.conversation;
      expect(branch, isNot(id));
      expect(backend.asked.last.texts, ['one', 'A1', 'two']);
      expect(backend.forks, [(id, branch)]);
      await finish('A2b');
      expect(shown(), ['one', 'A1', 'two', 'A2b']);
      expect(versions().last, (1, 2));
      await chats().flip(3, -1);
      expect(shown(), ['one', 'A1', 'two', 'A2']);
    });

    test('on an older reply: a new branch, and what followed the old reply stays with it', () async {
      await exchange('one', 'A1');
      await exchange('two', 'A2');
      chats().regenerate(1, file);
      expect(backend.asked.last.texts, ['one']);
      await finish('A1b');
      expect(shown(), ['one', 'A1b'], reason: 'the messages after the old reply belong to it');
      expect(versions()[1], (1, 2));
      await chats().flip(1, -1);
      expect(shown(), ['one', 'A1', 'two', 'A2']);
      // Sending after the new version goes on in its branch.
      await chats().flip(1, 1);
      final branch = state().open!.conversationId;
      await exchange('next', 'N');
      expect(backend.asked.last.conversation, branch);
      expect(backend.asked.last.texts, ['one', 'A1b', 'next']);
    });

    test('only a reply to a sent message, and not while a reply runs', () async {
      await exchange('one', 'A1');
      chats().regenerate(0, file);
      expect(backend.asked, hasLength(1));
      chats().send('two', file);
      chats().regenerate(1, file);
      expect(backend.asked, hasLength(2));
    });

    test('stopped before its first word, the reply shown before comes back and its branch is erased', () async {
      await exchange('one', 'A1');
      await exchange('two', 'A2');
      chats().regenerate(3, file);
      final branch = backend.asked.last.conversation;
      chats().stop();
      await settle();
      expect(shown(), ['one', 'A1', 'two', 'A2']);
      expect(versions().last, (0, 1));
      expect(backend.erased, [branch]);
    });
  });

  group('starting early', () {
    test('an edit of a message older than the latest exchange has the engine read the chat up to it', () async {
      final id = await threeExchanges();
      chats().beginEdit(2, file);
      await settle();
      final edit = state().editing!;
      expect(backend.readAheads, hasLength(1));
      expect(backend.readAheads.single.from, id);
      expect(backend.readAheads.single.to, edit.branch);
      expect(backend.readAheads.single.texts, ['one', 'A1']);
      chats().sendEdit('two, edited', file);
      expect(backend.asked.last.conversation, edit.branch, reason: 'the branch made when the editing started');
      expect(backend.cancelled, isEmpty);
    });

    test('not for the latest message, nor the first, and not when the engine is not ready', () async {
      await threeExchanges();
      chats().beginEdit(4, file);
      expect(backend.readAheads, isEmpty, reason: 'the latest message: its saved state is there');
      chats().cancelEdit();
      chats().beginEdit(0, file);
      expect(backend.readAheads, isEmpty);
      chats().cancelEdit();
      backend.loaded = false;
      chats().beginEdit(2, file);
      await settle();
      expect(backend.readAheads, isEmpty);
      // Sending still works, with the copy made when the reply starts.
      chats().sendEdit('two, edited', file);
      expect(backend.forks, hasLength(1));
    });

    test('cancelling stops it and erases the branch, and the draft in the box is not touched', () async {
      await threeExchanges();
      chats().beginEdit(2, file);
      final branch = state().editing!.branch;
      chats().cancelEdit();
      expect(state().editing, isNull);
      expect(chats().editText, isNull);
      expect(backend.cancelled, [branch]);
      expect(state().open!.messages, hasLength(6));
      expect(backend.asked, hasLength(3));
    });

    test('opening another chat or flipping a version cancels the editing', () async {
      final id = await threeExchanges();
      chats().beginEdit(2, file);
      chats().newChat();
      expect(state().editing, isNull);
      expect(backend.cancelled, hasLength(1));
      await chats().open(id);
      chats().regenerate(5, file);
      await finish('A3b');
      chats().beginEdit(2, file);
      await chats().flip(5, -1);
      expect(state().editing, isNull);
      expect(backend.cancelled, hasLength(2));
    });
  });

  group('the engine\'s states', () {
    test('the pins list holds every branch of a pinned chat', () async {
      final id = await threeExchanges();
      chats().pin(id);
      await settle();
      expect(backend.pinned, [id]);
      chats().regenerate(5, file);
      final branch = backend.asked.last.conversation;
      await settle();
      expect(backend.pinned, [id, branch]);
      await finish('A3b');
      chats().unpin(id);
      await settle();
      expect(backend.pinned, isEmpty);
    });

    test('archiving and deleting erase every branch of the chat', () async {
      final id = await threeExchanges();
      chats().regenerate(5, file);
      final first = backend.asked.last.conversation;
      await finish('A3b');
      chats().beginEdit(2, file);
      chats().sendEdit('edited', file);
      final second = backend.asked.last.conversation;
      await finish('B');
      chats().archive(id);
      expect(backend.erased, unorderedEquals([id, first, second]));
      backend.erased.clear();
      chats().delete(id);
      expect(backend.erased, unorderedEquals([id, first, second]));
    });
  });

  group('search and bookmarks', () {
    test('search finds the text of every version, and opening a hit shows its version', () async {
      final id = await threeExchanges();
      chats().beginEdit(2, file);
      chats().sendEdit('about zebras', file);
      await finish('B2');
      await chats().flip(2, -1);
      expect(shown()[2], 'two');
      final hits = (await store.search('zebras', ChatKind.chat))!;
      expect(hits.single.chatId, id);
      final at = await chats().openAt(id, hits.single.messageIndex!);
      expect(at, 2);
      expect(shown(), ['one', 'A1', 'about zebras', 'B2']);
    });

    test('a bookmark is on the version it was set on', () async {
      await threeExchanges();
      chats().beginEdit(2, file);
      chats().sendEdit('edited', file);
      await finish('B2');
      chats().toggleBookmark(2);
      await settle();
      expect(state().open!.messages[2].bookmark, isTrue);
      await chats().flip(2, -1);
      expect(state().open!.messages[2].bookmark, isFalse);
      await chats().flip(2, 1);
      expect(state().open!.messages[2].bookmark, isTrue);
    });
  });
}
