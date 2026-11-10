// What a reply leaves behind: a thought kept when the reply is stopped, the reply saved as it grows, a chat deleted
// mid-reply, and what may not start while a benchmark runs.
// Run: flutter test test/reply_save_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/engine_process.dart';
import 'package:runmyai/state/benchmark.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/state/queue.dart';
import 'package:runmyai/ui/close_guard.dart';

/// Replies stay open until the test ends them.
class _Backend implements Backend {
  final asked = <List<String>>[];
  final replies = <StreamController<ReplyEvent>>[];

  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) {
    asked.add([for (final m in messages) m.text]);
    final reply = StreamController<ReplyEvent>();
    replies.add(reply);
    return reply.stream;
  }

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
    description: '',
    parameters: '1B',
    activeParameters: '1B',
    files: [file],
  );
  late Directory dir;
  late ChatStore store;
  late _Backend backend;
  late ProviderContainer container;
  Future<void> settle([int millis = 20]) => Future<void>.delayed(Duration(milliseconds: millis));

  ChatsNotifier chats() => container.read(chatsProvider.notifier);
  ChatsState state() => container.read(chatsProvider);
  StreamController<ReplyEvent> reply() => backend.replies.last;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('runmyai-reply-');
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

  group('stopped while thinking', () {
    test('the thought stays, marked stopped, saved like a message, and the next message is sent without it', () async {
      chats().send('hi', file);
      final id = state().openId!;
      reply().add(const ReplyThinking('let me see'));
      await settle();
      chats().stop();
      await settle();
      final last = state().open!.messages.last;
      expect((last.role, last.text, last.thinking, last.stopped), (Role.assistant, '', 'let me see', true));
      expect(last.thinkingMillis, isNotNull, reason: 'it says how long it thought');
      final saved = (await store.messages(id)).last;
      expect((saved.text, saved.thinking, saved.stopped, saved.thinkingMillis), ('', 'let me see', true, last.thinkingMillis));

      chats().send('again', file);
      expect(backend.asked.last, ['hi', 'again'], reason: 'an empty reply is not sent to the model');
      expect(state().open!.messages.map((m) => m.text), ['hi', '', 'again', '']);
    });

    test('a reply that fails while it thought keeps the thought too', () async {
      chats().send('hi', file);
      reply()
        ..add(const ReplyThinking('hmm'))
        ..addError(const EngineFailure('The engine stopped unexpectedly.'));
      await settle();
      expect(state().failure, isNotNull);
      final last = state().open!.messages.last;
      expect((last.thinking, last.stopped), ('hmm', true));
    });

    test('words are kept as they were, and a reply with neither thought nor words leaves nothing behind', () async {
      chats().send('hi', file);
      final id = state().openId!;
      reply()
        ..add(const ReplyThinking('hmm'))
        ..add(const ReplyText('part'));
      await settle();
      chats().stop();
      await settle();
      expect(state().open!.messages.last.stopped, isFalse);
      expect((await store.messages(id)).map((m) => m.text), ['hi', 'part']);

      chats().send('and?', file);
      await settle();
      chats().stop();
      await settle();
      expect(state().open!.messages.map((m) => m.text), ['hi', 'part', 'and?']);
      expect((await store.messages(id)).map((m) => m.text), ['hi', 'part', 'and?']);
    });
  });

  test('the reply is saved as it grows (about once a second), and as it is at its end', () async {
    chats().send('hi', file);
    final id = state().openId!;
    reply()
      ..add(const ReplyThinking('hmm'))
      ..add(const ReplyText('one'));
    await settle(200);
    expect((await store.messages(id)).map((m) => m.text), ['hi'], reason: 'not yet');
    reply().add(const ReplyText(' two'));
    await settle(1100);
    final partial = (await store.messages(id)).last;
    expect((partial.text, partial.thinking, partial.stopped), ('one two', 'hmm', true));
    expect(state().replyingId, id, reason: 'still being written');

    reply().add(const ReplyText(' three'));
    await reply().close();
    await settle();
    final all = await store.messages(id);
    expect(all.map((m) => m.text), ['hi', 'one two three']);
    expect(all.last.stopped, isFalse);
  });

  test('a chat deleted mid-reply leaves no thinking time or speed for the next reply', () async {
    chats().send('hi', file);
    final id = state().openId!;
    reply()
      ..add(const ReplyThinking('hmm'))
      ..add(const ReplySpeed(live: 20, average: 12));
    await settle();
    chats().delete(id);
    expect(state().replyingId, isNull);
    expect(state().speed, isNull);
    await settle(300);

    chats().send('next', file);
    reply()
      ..add(const ReplyThinking('quick'))
      ..add(const ReplyText('done'));
    await reply().close();
    await settle();
    final last = state().open!.messages.last;
    expect(last.thinkingMillis, lessThan(250), reason: 'timed from this reply, not the deleted one');
    expect(state().speed, isNull, reason: 'no average of the deleted reply');
  });

  group('while a benchmark runs', () {
    test('nothing starts: not Send, not Try again, not Send next', () async {
      final benchmark = container.read(benchmarkProvider.notifier) as _Benchmark;
      chats().send('hi', file);
      final id = state().openId!;
      reply().addError(const EngineFailure('The engine stopped unexpectedly.'));
      await settle();
      expect(state().failure, isNotNull);
      container.read(queueProvider.notifier).add(id, 'waiting');
      expect(backend.asked, hasLength(1));

      benchmark.run(true);
      chats().retry();
      chats().send('another', file);
      chats().sendQueued(file);
      expect(backend.asked, hasLength(1), reason: 'the engine was not asked');
      expect(state().replyingId, isNull);
      expect(state().failure, isNotNull, reason: 'the failure waits');
      expect(container.read(queueProvider)[id]!.messages, hasLength(1));

      benchmark.run(false);
      chats().retry();
      expect(backend.asked, hasLength(2));
    });
  });

  group('closing the window', () {
    test('asks while a reply or a benchmark is running, not otherwise', () {
      expect(closeQuestion(replying: true, benchmarking: false), 'A reply is still running. Close anyway?');
      expect(closeQuestion(replying: false, benchmarking: true), 'A benchmark is still running. Close anyway?');
      expect(closeQuestion(replying: false, benchmarking: false), isNull);
    });
  });
}
