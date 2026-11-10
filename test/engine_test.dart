// The engine connection without a model: reading its flags and its reply stream, the watcher that closes the engine
// with the app, and a failed reply written again.
// Run: flutter test test/engine_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/backend/engine_backend.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/auto_commands.dart';
import 'package:runmyai/engine/chat_stream.dart';
import 'package:runmyai/engine/context_fit.dart';
import 'package:runmyai/engine/engine_flags.dart';
import 'package:runmyai/engine/engine_process.dart';
import 'package:runmyai/engine/live_speed.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/profiles.dart';
import 'package:runmyai/state/providers.dart';

/// First a reply that fails partway, then one that works.
class _FlakyBackend implements Backend {
  var calls = 0;
  List<ChatMessage>? lastAsked;

  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) async* {
    lastAsked = messages;
    if (calls++ == 0) {
      yield const ReplyThinking('hmm');
      yield const ReplyText('part of it');
      throw const EngineFailure('The engine stopped unexpectedly.', log: ['last line']);
    }
    yield const ReplyText('all of it');
    yield const ReplySpeed(live: 40, average: 30);
    yield const ReplySpeed(average: 31.5);
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

void main() {
  group('flags', () {
    test('leading NAME=value words are the environment, the rest are arguments; quotes keep spaces', () {
      final flags = EngineFlags.parse('A=1 B="two words"  -c 65536 --name "x y" --empty \'\'');
      expect(flags.environment, {'A': '1', 'B': 'two words'});
      expect(flags.arguments, ['-c', '65536', '--name', 'x y', '--empty', '']);
    });

    test('a NAME=value after the first argument stays an argument', () {
      expect(EngineFlags.parse('-c 1 A=1').environment, isEmpty);
    });

    test('the commands the models start with leave out what the app supplies', () {
      for (final auto in [lingAuto, flintAuto]) {
        expect(auto.keys, [4096, 8192, 16384, 32768, 65536, 131072, 262144]);
        for (final MapEntry(key: length, value: command) in auto.entries) {
          final flags = EngineFlags.parse(command);
          expect(flags.environment['GGML_CUDA_COPY_KERNEL'], '65536');
          expect(flags.arguments[flags.arguments.indexOf('-c') + 1], '$length');
          for (final supplied in ['-m', '--host', '--port', 'systemd-run']) {
            expect(flags.arguments, isNot(contains(supplied)));
          }
        }
      }
    });
  });

  group('context', () {
    ChatMessage user(String t) => ChatMessage(Role.user, t);
    ChatMessage bot(String t) => ChatMessage(Role.assistant, t);

    test('the closest length the model can run with', () {
      const options = [4096, 65536, 131072];
      expect(closestContext(options, 65536), 65536);
      expect(closestContext(options, 262144), 131072, reason: 'drops to what the model supports');
      expect(closestContext(options, 16384), 4096);
      expect(closestContext(const [65536, 131072], 4096), 65536, reason: 'nothing below: the smallest');
    });

    test('messages that fit are all sent', () {
      final messages = [user('a'), bot('b'), user('c')];
      expect(ContextFit.toDrop(messages, [10, 10, 10], 1000), 0);
      expect(ContextFit.surelyFits(messages, 1000), isTrue);
    });

    test('short of room: the oldest go, down to the target, and it starts with a user message', () {
      final messages = [user('1'), bot('2'), user('3'), bot('4'), user('5')];
      // 5 x 300 tokens + the marks = 1540; room for 875; target 750.
      expect(ContextFit.toDrop(messages, [300, 300, 300, 300, 300], 1000), 4);
      // A cost that fits after two messages: starts on the user message at place 2.
      expect(ContextFit.toDrop(messages, [500, 500, 100, 100, 100], 1000), 2);
      // After dropping one reaches the target, but place 1 is a reply: the next user message.
      expect(ContextFit.toDrop(messages, [900, 100, 100, 100, 100], 1000), 2);
    });

    test('the last message always stays', () {
      expect(ContextFit.toDrop([user('a'), bot('b'), user('c')], [10, 10, 5000], 1000), 2);
    });

    test('a long text is not sure to fit', () {
      expect(ContextFit.surelyFits([user('x' * 400)], 1000), isFalse);
    });
  });

  group('reply stream', () {
    List<String> names(List<ReplyEvent> events) => [
      for (final e in events)
        switch (e) {
          ReplyText(:final text) => 'text:$text',
          ReplyThinking(:final text) => 'think:$text',
          _ => '?',
        },
    ];

    test('thinking and text are told apart; the end is seen', () {
      final reader = ChatStreamReader();
      expect(names(reader.read('data: {"choices":[{"delta":{"reasoning_content":"a"}}]}')), ['think:a']);
      expect(names(reader.read('data: {"choices":[{"delta":{"content":"b"}}]}')), ['text:b']);
      expect(reader.finished, isFalse);
      expect(reader.read('data: [DONE]'), isEmpty);
      expect(reader.finished, isTrue);
    });

    test('other lines say nothing; a finish reason is the end too', () {
      final reader = ChatStreamReader();
      expect(reader.read(''), isEmpty);
      expect(reader.read(': keep-alive'), isEmpty);
      expect(reader.read('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}'), isEmpty);
      expect(reader.finished, isTrue);
    });

    test('the engine\'s count and average are kept from its timings', () {
      final reader = ChatStreamReader();
      reader.read('data: {"choices":[{"delta":{"content":"a"}}],"timings":{"predicted_n":7,"predicted_per_second":41.5}}');
      expect((reader.written, reader.average), (7, 41.5));
    });

    test("the engine's own error message comes through", () {
      final reader = ChatStreamReader();
      expect(
        () => reader.read('data: {"error":{"message":"too long"}}'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', 'too long')),
      );
      expect(
        () => reader.read('error: {"message":"also bad"}'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', 'also bad')),
      );
    });
  });

  group('live speed', () {
    Duration ms(int n) => Duration(milliseconds: n);

    test('the tokens of the last half second; nothing to show before two arrivals', () {
      final speed = LiveSpeed();
      expect(speed.tick(ms(100)), isNull);
      speed.add(ms(100), 1);
      expect(speed.tick(ms(200)), isNull);
      for (var i = 2; i <= 21; i++) {
        speed.add(ms(i * 100), i * 5);
      }
      expect(speed.tick(ms(2100)), closeTo(50, 0.01));
    });

    test('a new high shows at once and is held; then a dip shows', () {
      final speed = LiveSpeed();
      for (var i = 1; i <= 20; i++) {
        speed.add(ms(i * 100), i * 5);
      }
      expect(speed.tick(ms(2000)), closeTo(50, 0.01));
      expect(speed.tick(ms(2100)), isNull, reason: 'slower, but the high is held');
      expect(speed.tick(ms(3000)), closeTo(0, 0.01), reason: 'the hold is over: nothing arrived in the last half second');
    });

    test('a count that does not grow is not an arrival', () {
      final speed = LiveSpeed()
        ..add(ms(100), 10)
        ..add(ms(200), 10);
      expect(speed.tick(ms(300)), isNull);
    });
  });

  group('the engine closes with the app', () {
    Future<EngineProcess> start(String script) =>
        EngineProcess.start(command: ['/bin/sh', '-c', script], modelId: 'm', port: 1);

    test('its pipe closing stops it (what happens when the app ends in any way)', () async {
      final engine = await start('exec sleep 300');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(engine.running, isTrue);
      await engine.stop().timeout(const Duration(seconds: 4));
      expect(engine.running, isFalse);
    });

    test('one that ignores the polite stop is stopped by force', () async {
      final engine = await start("trap '' TERM; while :; do sleep 1; done");
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await engine.stop().timeout(const Duration(seconds: 9));
      expect(engine.running, isFalse);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('its exit code and output come through', () async {
      final engine = await start('echo hello; echo oops >&2; exit 7');
      expect(await engine.exited, 7);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(engine.log, containsAll(['hello', 'oops']));
      expect(engine.lastLines(1), hasLength(1));
    });

    test('waiting for one that ends says it stopped, with its last lines', () async {
      final engine = await start('echo bad flag; exit 1');
      await expectLater(
        engine.waitUntilReady(),
        throwsA(isA<EngineFailure>().having((e) => e.log, 'log', contains('bad flag'))),
      );
    });
  });

  group('which engine a chat may use', () {
    Future<EngineProcess> start(EngineRun run) => EngineProcess.start(
      command: ['/bin/sh', '-c', 'exec sleep 300'],
      modelId: 'm',
      contextLength: run.contextLength,
      port: 1,
      startedWith: EngineBackend.startedWith(run),
    );

    test('only one started with the same model, length, flags and memory cap', () async {
      const run = EngineRun(flags: '-c 4096 --a', contextLength: 4096, memoryCapGiB: 20);
      final engine = await start(run);
      addTearDown(engine.stop);
      expect(EngineBackend.isRunning(engine, 'm', run), isTrue);
      expect(EngineBackend.isRunning(null, 'm', run), isFalse);
      expect(EngineBackend.isRunning(engine, 'other', run), isFalse);
      // A benchmark's test flags left running are not a chat's profile.
      expect(EngineBackend.isRunning(engine, 'm', const EngineRun(flags: '-c 4096 --b', contextLength: 4096, memoryCapGiB: 20)), isFalse);
      expect(EngineBackend.isRunning(engine, 'm', const EngineRun(flags: '-c 4096 --a', contextLength: 4096, memoryCapGiB: 12)), isFalse);
      expect(EngineBackend.isRunning(engine, 'm', const EngineRun(flags: '-c 4096 --a', contextLength: 4096)), isFalse);
      expect(EngineBackend.isRunning(engine, 'm', const EngineRun(flags: '-c 8192 --a', contextLength: 8192, memoryCapGiB: 20)), isFalse);
    });

    test('one that has ended is not running', () async {
      const run = EngineRun(flags: '-c 4096', contextLength: 4096);
      final engine = await start(run);
      await engine.stop();
      expect(EngineBackend.isRunning(engine, 'm', run), isFalse);
    });
  });

  test('Stop while the engine loads ends the load, and says nothing went wrong', () async {
    final dir = Directory.systemTemp.createTempSync('runmyai-load-');
    addTearDown(() => dir.deleteSync(recursive: true));
    // An engine that never becomes ready.
    final folder = Directory('${dir.path}/engine')..createSync();
    final program = File('${folder.path}/llama-server')..writeAsStringSync('#!/bin/sh\nexec sleep 300\n');
    await Process.run('chmod', ['+x', program.path]);
    final storage = Storage(dir)..writePrefs(PrefsData(engineFolder: folder.path));
    final backend = EngineBackend(storage);
    final file = (await backend.loadCatalog()).first.files.first;
    if (!await backend.download(file).first.then((_) => true, onError: (Object _) => false)) {
      markTestSkipped('the model file is not on this computer');
      return;
    }
    const run = EngineRun(flags: '-c 4096', contextLength: 4096);
    final started = backend.startEngine(file, run);
    while (backend.engineState.value.phase != EnginePhase.loading) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await backend.stopEngine().timeout(const Duration(seconds: 10));
    await started.timeout(const Duration(seconds: 10));
    expect(backend.engineState.value.phase, EnginePhase.stopped);
  });

  test('a failed reply keeps what it wrote, and Try again replaces it', () async {
    final dir = Directory.systemTemp.createTempSync('runmyai-engine-');
    final store = await ChatStore.open(dir);
    final backend = _FlakyBackend();
    final container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        chatStoreProvider.overrideWithValue(store),
        backendProvider.overrideWithValue(backend),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await store.close();
      dir.deleteSync(recursive: true);
    });
    const file = ModelFile(id: 'm/f', quantization: 'q', sizeBytes: 1);
    final chats = container.read(chatsProvider.notifier);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    chats.send('hi', file);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    var state = container.read(chatsProvider);
    expect(state.failure?.message, 'The engine stopped unexpectedly.');
    expect(state.failure?.log, ['last line']);
    expect(state.replyingId, isNull);
    expect(state.open!.messages.last.text, 'part of it');
    expect(state.open!.messages.last.thinking, 'hmm');
    final id = state.openId!;
    expect((await store.messages(id)).last.thinking, 'hmm', reason: 'saved with the message');

    chats.retry();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    state = container.read(chatsProvider);
    expect(state.failure, isNull);
    expect(backend.lastAsked!.map((m) => m.text), ['hi'], reason: 'the part written before is not sent');
    expect(state.open!.messages.map((m) => m.text), ['hi', 'all of it']);
    expect((await store.messages(id)).map((m) => m.text), ['hi', 'all of it']);
    expect((state.speed?.tokensPerSecond, state.speed?.done, state.speed?.chatId), (31.5, true, id), reason: 'the average');
  });
}
