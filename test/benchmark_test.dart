// What a benchmark run does and keeps: the order of its messages, the machine and engine readings it collects, its
// phases, the flags it adds, the history. No model and no GPU are used.
// Run: flutter test test/benchmark_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/benchmark/benchmark.dart';
import 'package:runmyai/benchmark/hardware.dart';
import 'package:runmyai/benchmark/prompts.dart';
import 'package:runmyai/benchmark/series.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/commands.dart';
import 'package:runmyai/state/benchmark.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/providers.dart';

const _file = ModelFile(id: 'm/f', quantization: 'q', sizeBytes: 1);

/// A machine that reports a little every few milliseconds.
class _Monitor extends HardwareMonitor {
  final _ticks = StreamController<SystemSample>.broadcast();
  Timer? _timer;
  var _n = 0;

  @override
  Stream<SystemSample> get samples => _ticks.stream;
  @override
  HardwareInfo get info => const HardwareInfo(cpu: 'Test CPU', threads: 4, gpus: ['Test GPU'], ramGiB: 16, os: 'Test OS');

  @override
  Future<void> start() async {
    _timer = Timer.periodic(const Duration(milliseconds: 4), (_) {
      _ticks.add(SystemSample(0.004 * ++_n, {'cpu.load': 5, 'cpu.other': 1, 'gpu.0.load': 1, 'gpu.0.powerLimit': 95, 'sys.battery': 0}));
    });
  }

  @override
  Future<SystemSample> look() async => const SystemSample(0, {'cpu.load': 5, 'gpu.0.load': 1, 'ram.available': 12});
  @override
  Future<void> stop() async => _timer?.cancel();
}

class _Backend implements Backend, EngineControl {
  final calls = <String>[];
  final prompts = <int>[];

  /// The text of the message each reply answers, and the most tokens it was allowed.
  final texts = <String>[];
  final caps = <int?>[];

  /// The whole conversation each reply was asked for.
  final asked = <List<ChatMessage>>[];

  /// The request settings of each reply.
  final runs = <EngineRun>[];

  /// What the engine was last told about pinned chats.
  List<String>? pinned;

  /// Replies never end by themselves.
  var hold = false;

  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) async* {
    prompts.add(messages.length);
    asked.add([...messages]);
    texts.add(messages.last.text);
    caps.add(maxTokens);
    runs.add(run);
    calls.add('reply:${messages.last.text.substring(0, 2)}:$maxTokens');
    yield const ReplyProgress(processed: 100, total: 100, millis: 50);
    yield const ReplyText('one');
    if (hold) await Completer<void>().future;
    await Future<void>.delayed(const Duration(milliseconds: 25));
    yield const ReplyText(' two');
    yield const ReplyDone(
      {'prompt_n': 100, 'prompt_ms': 50, 'predicted_n': 2, 'predicted_ms': 40},
      wordMillis: [30, 10],
      finishReason: 'stop',
    );
  }

  @override
  Future<void> startEngine(ModelFile file, EngineRun run, {bool restart = false}) async => calls.add('start:${[run.flags, if (run.addedFlags.isNotEmpty) run.addedFlags].join(' ')}');
  @override
  Future<void> stopEngine() async => calls.add('stop');
  @override
  Future<void> eraseChatState(String chatId) async => calls.add('erase');
  @override
  Future<void> setPinnedChats(List<String> chatIds) async => pinned = chatIds;
  @override
  Future<String?> reportedVersion() async => null;
  @override
  ValueListenable<EngineState> get engineState => ValueNotifier(const EngineState(EnginePhase.stopped));
  @override
  List<String> get logLines => const [
    'llama_moe_stream: 14.20 GiB of pools = 191 slots per layer x 41 layers',
    'vx_setup: VRAM experts: 62 per layer x 41 streamed layers = 5.3 GiB',
  ];
  @override
  Listenable get logChanged => ChangeNotifier();
  @override
  Map<int, String> autoCommands(ModelFile file) => const {4096: '-c 4096 --auto', 65536: '-c 65536 --auto'};
  @override
  int maxContext(ModelFile file) => 262144;
  @override
  Future<List<CatalogModel>> loadCatalog() async => const [];
  @override
  Stream<double> download(ModelFile file) => const Stream.empty();
  @override
  Future<void> deleteDownload(ModelFile file) async {}
}

/// An engine that can say more about itself.
class _InsightBackend extends _Backend implements EngineInsight {
  var accepts = true;
  var polls = 0;

  @override
  Future<bool> acceptsFlag(String flag) async => accepts && flag == '--moe-stream-timing';

  /// Counters that grow with every look, with the numbers per layer.
  @override
  Future<Map<String, Object?>?> liveStats() async {
    polls++;
    return {
      'slots': 191,
      'layers': 2,
      'tokens': 10.0 * polls,
      'stall_ms': 20.0 * polls,
      'cpu_ms': 100.0 * polls,
      'gpu_ms': 40.0 * polls,
      'per_layer': [
        {'misses': 2.0 * polls, 'stall_ms': 5.0 * polls},
        {'misses': 4.0 * polls, 'stall_ms': 9.0 * polls},
      ],
    };
  }

  @override
  Future<({int bytes, DateTime modified})?> modelFileInfo(ModelFile file) async => (bytes: 1234567, modified: DateTime(2026, 1, 2));
  @override
  Future<int?> countTokens(String text) async => text.length ~/ 4;
}

/// An engine whose automatic preset already sets the timing flag.
class _TimedPresetBackend extends _InsightBackend {
  @override
  Map<int, String> autoCommands(ModelFile file) => const {4096: '-c 4096 --auto --moe-stream-timing 0'};
}

/// An engine whose [holdAt]-th reply never ends by itself; the ones before it do.
class _HoldAtBackend extends _Backend {
  _HoldAtBackend(this.holdAt);

  final int holdAt;
  var _started = 0;

  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) {
    hold = ++_started >= holdAt;
    return super.reply(chatId: chatId, model: model, messages: messages, run: run, thinking: thinking, maxTokens: maxTokens);
  }
}

/// An engine whose every reply carries counters of its own, higher with each turn of the conversation.
class _CountersBackend extends _Backend {
  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) async* {
    final turn = (messages.length + 1) ~/ 2;
    yield const ReplyText('one');
    yield ReplyDone(
      {
        'prompt_n': 100,
        'prompt_ms': 50,
        'predicted_n': 2,
        'predicted_ms': 40,
        'moe_stream': {
          'reply': {'stall_ms_per_token': 1.5 * turn, 'hit_rate_percent': 90.0 + turn},
        },
      },
      wordMillis: const [30, 10],
      finishReason: 'stop',
    );
  }
}

void main() {
  group('context options', () {
    const m = 1000000;
    test('the standard lengths up to the model\'s longest', () {
      expect(contextOptions(262144).map(contextLabel), ['4k', '8k', '16k', '32k', '65k', '100k', '131k', '200k', '262k']);
      expect(contextOptions(300000).last, 262144);
    });

    test('at the top of the list', () {
      expect(contextOptions(10485760).map(contextLabel).last, '10M');
      expect(contextOptions(2097152).map(contextLabel).toList().sublist(9), ['524k', '1M', '2M']);
    });

    test('a 15M model: after 10M, 15M', () {
      expect(contextOptions(15000000).map(contextLabel).toList().sublist(12), ['5M', '10M', '15M']);
    });

    test('above 10M the only further option is the model\'s own longest', () {
      final options = contextOptions(20 * m);
      expect(options.map(contextLabel).toList().sublist(13), ['10M', '20M']);
      expect(options.last, 20 * m);
    });

    test('a longest that shows as a standard label is that one option, in full', () {
      final options = contextOptions(10723232);
      expect(options.where((n) => contextLabel(n) == '10M'), [10723232]);
      expect(options.last, 10723232);
      expect(contextOptions(524000).last, 524000);
    });

    test('a command gets a new length', () {
      expect(withContextLength('A=1 -c 4096 --x', 8192), 'A=1 -c 8192 --x');
    });
  });

  test('a prompt fits when it and the longest reply stay inside the engine\'s room', () {
    expect(promptFits(1000, 1024, 4096), isTrue);
    expect(promptFits(4000, 1024, 4096), isFalse);
    expect(promptFits(32000, 1024, 32768), isFalse);
    expect(promptFits(32000, 1024, 65536), isTrue);
    expect(promptFits(16000, 1024, 16384), isFalse);
  });

  test('a prompt test fits a context when its text, the warm-ups and its reply stay inside the engine\'s room', () {
    bool fits(BenchmarkTest t, int context) => t.fits(context);
    final [p8, p25, p50, p100] = BenchmarkTest.prompts;
    expect([for (final n in [4096, 8192, 16384, 32768, 65536, 131072, 262144]) fits(p8, n)], [false, false, true, true, true, true, true]);
    expect([for (final n in [4096, 8192, 16384, 32768, 65536, 131072, 262144]) fits(p25, n)], [false, false, false, true, true, true, true]);
    expect([for (final n in [4096, 8192, 16384, 32768, 65536, 131072, 262144]) fits(p50, n)], [false, false, false, false, true, true, true]);
    expect([for (final n in [4096, 8192, 16384, 32768, 65536, 131072, 262144]) fits(p100, n)], [false, false, false, false, false, true, true]);
    expect(BenchmarkTest.replySpeed.fits(4096), isTrue, reason: 'a short message and a reply: fits every length');
  });

  group('the tests', () {
    test('five tests, named as the setup names them, each with its own reply cap', () {
      expect(BenchmarkTest.all.map((t) => t.label), ['Reply speed', 'Prompt 8k', 'Prompt 25k', 'Prompt 50k', 'Prompt 100k']);
      expect(BenchmarkTest.all.map((t) => t.promptTokens), [null, 8000, 25000, 50000, 100000]);
      expect(BenchmarkTest.all.map((t) => t.replyCap), [2000, 200, 200, 200, 200]);
      expect(BenchmarkTest.replySpeed.description, 'a long story');
      expect(BenchmarkTest.prompts[1].description, 'a story of 25k tokens and a short review');
    });

    test('every prompt test has a story of its own in the app, longer than three characters for each of its tokens', () {
      final listed = File('pubspec.yaml').readAsStringSync();
      expect(listed, contains('- assets/benchmark/stories/'));
      expect(BenchmarkTest.replySpeed.story, isNull);
      expect({for (final t in BenchmarkTest.prompts) t.story}, hasLength(BenchmarkTest.prompts.length));
      for (final t in BenchmarkTest.prompts) {
        expect(t.story, startsWith('assets/benchmark/stories/'));
        expect(File(t.story!).lengthSync(), greaterThan(t.promptTokens! * 3), reason: t.label);
      }
    });

    test('the warm-ups and the messages are fixed, word for word', () {
      expect(warmupMessages, [
        'Hello bro, how are you? what are you doing? tell me in 5 sentences.',
        'Tell me about yourself. In 5 sentences.',
      ]);
      expect(replySpeedRequest, 'write a long random story of 1500 words.');
      expect(
        promptReviewRequest,
        'Write a short review of the story above. If the story feels cut off in the middle, just write the review based on '
        'what is covered so far.',
      );
      expect(const BenchmarkSetup().warmups, warmupMessages);
    });

    test('a saved context length is kept when the preset has it, else the default one', () {
      const presets = [4096, 8192, 65536, 131072];
      expect(contextChoice(presets, 8192), 8192);
      expect(contextChoice(presets, 100000), 65536, reason: 'no preset for it');
      expect(contextChoice(autoContextLengths, 100000), 100000, reason: '100k is an Auto length');
      expect(contextChoice(autoContextLengths, 200000), 200000, reason: '200k is an Auto length');
      expect(contextChoice(presets, 12345), 65536);
      expect(contextChoice(const [4096, 8192], 65536), 8192, reason: 'the closest the preset has below the default');
    });
  });

  group('an older saved setup', () {
    /// What the version before wrote: a profile, a prompt, the text and reply length, the warm-ups and Test mode's flags.
    const before = <String, Object?>{
      'profileId': 'test',
      'contextLength': 32768,
      'promptId': '16k',
      'customText': 'my own text',
      'replyLength': 512,
      'warmups': ['one', 'two', 'three'],
      'testFlags': '-c 4096 --something 1',
      'testMemoryCapGiB': 12.5,
    };

    test('opens with the defaults, keeping the context length', () {
      final setup = BenchmarkSetup.fromJson(before);
      expect((setup.contextLength, setup.kvCache, setup.tests), (32768, KvCache.q8, BenchmarkSetup.defaultTests));
      expect(setup.warmups, warmupMessages, reason: 'the warm-ups are the test\'s, not the saved ones');
    });

    test('a setup with nothing, or with the wrong kinds of values, is the default one', () {
      for (final json in <Map<String, Object?>>[
        const {},
        const {'contextLength': 'big', 'kvCache': 7, 'test': null},
        const {'contextLength': null, 'kvCache': 'q5_9', 'test': 'prompt-1m'},
      ]) {
        final setup = BenchmarkSetup.fromJson(json);
        expect((setup.contextLength, setup.kvCache, setup.tests), (defaultContextLength, KvCache.q8, BenchmarkSetup.defaultTests), reason: '$json');
      }
    });

    test('what it writes now reads back', () {
      final setup = BenchmarkSetup(contextLength: 8192, kvCache: KvCache.fp16, tests: [BenchmarkTest.prompts.last]);
      expect(setup.toJson(), {'contextLength': 8192, 'kvCache': 'fp16', 'tests': ['prompt-100k']});
      final again = BenchmarkSetup.fromJson(setup.toJson());
      expect((again.contextLength, again.kvCache, again.tests.single), (8192, KvCache.fp16, BenchmarkTest.prompts.last));
    });
  });

  group('a run', () {
    late Directory dir;
    late ChatStore store;
    late _Backend backend;
    late ProviderContainer container;

    Future<void> open(_Backend b, {Map<String, Object?>? saved}) async {
      dir = Directory.systemTemp.createTempSync('runmyai-bench-');
      if (saved != null) Storage(dir).writeBenchmarkSetup(saved);
      store = await ChatStore.open(dir);
      backend = b;
      container = ProviderContainer(
        overrides: [
          storageProvider.overrideWithValue(Storage(dir)),
          chatStoreProvider.overrideWithValue(store),
          backendProvider.overrideWithValue(backend),
          hardwareMonitorProvider.overrideWithValue(_Monitor.new),
          runVersionsProvider.overrideWithValue(() async => (engine: '1.2.3', app: '0.1.0')),
          promptCorpusProvider.overrideWith(
            (ref, asset) => PromptCorpus([
              [for (var p = 0; p < 3200; p++) 'Story $asset passage $p ${'word ' * 40}'].join('\n\n'),
            ]),
          ),
        ],
      );
      container.listen(benchmarkProvider, (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    tearDown(() async {
      container.dispose();
      await store.close();
      dir.deleteSync(recursive: true);
    });

    test('fresh engine, warm-ups not counted, one conversation; the engine stops afterwards; kept in the history', () async {
      await open(_Backend());
      final notifier = container.read(benchmarkProvider.notifier);
      await notifier.start(_file, 'M', 4096);
      expect(backend.calls, ['stop', 'start:-c 4096 --auto', 'reply:He:2000', 'reply:Te:2000', 'reply:wr:2000', 'erase', 'stop']);
      expect(backend.prompts, [1, 3, 5], reason: 'one conversation');
      expect(backend.runs.every((r) => !r.keepState && r.reportProgress), isTrue, reason: 'nothing is saved for a run');
      final state = container.read(benchmarkProvider);
      final result = state.result!;
      expect(state.running, isFalse);
      expect((result.replyTokens, result.promptTokens, result.tokenGaps.length), (2, 100, 1));
      expect(result.log, hasLength(2));
      expect(await store.benchmarks(), hasLength(1));
      expect(result.id, isNotNull);
      expect(state.history.single.id, result.id);
    });

    test('it keeps the engine\'s token times, how the reply ended, the phases, the machine and the record', () async {
      await open(_Backend());
      final notifier = container.read(benchmarkProvider.notifier);
      await notifier.start(_file, 'M', 4096, thinking: ModelThinking.optional);
      final r = container.read(benchmarkProvider).result!;
      expect(r.tokenMillis, [30, 10]);
      expect(r.slowestToken, 30);
      expect((r.stopReason, r.replyText), ('stop', 'one two'));
      expect(r.thinking, isNotNull);
      // 40 ms of the reply and 50 ms of the prompt, and the first token is the prompt plus the first token's own time.
      expect(r.firstTokenMillis, 80);
      final phases = r.series!.phases.map((p) => p.name).toList();
      expect(phases, [PhaseBand.load, PhaseBand.warmUp, PhaseBand.prompt, PhaseBand.reply]);
      expect(r.series!.length, greaterThan(2), reason: 'the machine was read during the run');
      expect(r.series!.series('cpu.load'), isNotNull);
      expect(r.environment.engineVersion, '1.2.3');
      expect(r.environment.appVersion, '0.1.0');
      expect(r.environment.hardware.cpu, 'Test CPU');
      expect(r.environment.onBattery, isFalse);
      expect(r.memory.ramSlots, 191);
      expect(r.memory.vramExpertsPerLayer, 62);
      expect(r.memory.freeRamGiB, 12);
      expect(r.promptText, 'write a long random story of 1500 words.');
      expect((r.promptLabel, r.replyLength, r.warmups), ('Reply speed', 2000, warmupMessages));
      // It comes back whole from the database.
      final again = (await store.benchmarks()).single;
      expect(again.$2, contains('"tokenMillis"'));
    });

    test("the GPU power bar's top is the card's highest limit on this PC, kept between runs", () async {
      await open(_Backend());
      await container.read(benchmarkProvider.notifier).start(_file, 'M', 4096);
      expect(container.read(benchmarkProvider).result!.series!.peak('gpu.0.powerTop'), 95);
      expect(Storage(dir).readPowerLimits(), {'Test GPU': 95.0});
      // A higher limit given once stays the top when the card runs lower.
      Storage(dir).writePowerLimits({'Test GPU': 105});
      await container.read(benchmarkProvider.notifier).start(_file, 'M', 4096);
      expect(container.read(benchmarkProvider).result!.series!.peak('gpu.0.powerTop'), 105);
      expect(Storage(dir).readPowerLimits(), {'Test GPU': 105.0});
    });

    test('the engine\'s counters, once a second, give the parts of a token and each layer; the timing flag is added', () async {
      final insight = _InsightBackend();
      await open(insight);
      final notifier = container.read(benchmarkProvider.notifier);
      await notifier.start(_file, 'M', 4096);
      final r = container.read(benchmarkProvider).result!;
      expect(insight.calls[1], 'start:-c 4096 --auto --moe-stream-timing 1');
      expect(r.flags, endsWith('--moe-stream-timing 1'));
      expect(r.environment.addedFlags, ['--moe-stream-timing 1']);
      expect(r.environment.modelFileBytes, 1234567);
      expect(r.timeParts.keys, containsAll(['SSD wait', 'CPU', 'GPU']));
      expect(r.timeParts['CPU'], closeTo(10, 0.001), reason: '100 ms for 10 tokens');
      expect(r.layers, hasLength(2));
      expect(container.read(benchmarkProvider).counters, EngineCounters.available);
    });

    test('the timing flag is left out when the engine does not know it, or the preset sets it', () async {
      final insight = _InsightBackend()..accepts = false;
      await open(insight);
      final notifier = container.read(benchmarkProvider.notifier);
      await notifier.start(_file, 'M', 4096);
      expect(insight.calls[1], 'start:-c 4096 --auto');
      expect(container.read(benchmarkProvider).result!.environment.addedFlags, isEmpty);

      final preset = _TimedPresetBackend();
      container.dispose();
      await store.close();
      dir.deleteSync(recursive: true);
      await open(preset);
      await container.read(benchmarkProvider.notifier).start(_file, 'M', 4096);
      expect(preset.calls[1], allOf(startsWith('start:-c 4096 --auto --moe-stream-timing 0'), isNot(contains('timing 1'))));
      expect(container.read(benchmarkProvider).result!.environment.addedFlags, isEmpty);
    });

    test('a prompt test sends its own story and then its request, cut to its size by the engine\'s own count', () async {
      await open(_InsightBackend());
      final notifier = container.read(benchmarkProvider.notifier);
      notifier.setSetup(BenchmarkSetup(tests: [BenchmarkTest.prompts.first]));
      await notifier.start(_file, 'M', 65536);
      final r = container.read(benchmarkProvider).result!;
      expect((r.promptLabel, r.replyLength), ('Prompt 8k', 200));
      final message = backend.texts.last;
      // (The stand-in counts a token for four characters.)
      expect((message.length / 4 - 8000).abs(), lessThan(8000 * 0.002 + 2));
      expect(message, startsWith('Story ${BenchmarkTest.prompts.first.story} passage 0'));
      expect(message, endsWith('\n\n$promptReviewRequest'));
      expect(message, isNot(contains('Below is a collection')), reason: 'no introduction before the text');
      expect(backend.caps, [200, 200, 200]);
    });

    test('every test sends the two warm-ups word for word, then its own message, in one conversation', () async {
      for (final test in BenchmarkTest.all) {
        if (test != BenchmarkTest.replySpeed) {
          // (The last one is closed by the test's own tear-down.)
          container.dispose();
          await store.close();
          dir.deleteSync(recursive: true);
        }
        await open(_InsightBackend());
        final notifier = container.read(benchmarkProvider.notifier);
        notifier.setSetup(BenchmarkSetup(tests: [test]));
        await notifier.start(_file, 'M', 262144);
        expect(backend.texts.take(2), [
          'Hello bro, how are you? what are you doing? tell me in 5 sentences.',
          'Tell me about yourself. In 5 sentences.',
        ], reason: test.label);
        expect(backend.prompts, [1, 3, 5], reason: test.label);
        expect(backend.caps, List.filled(3, test.replyCap), reason: test.label);
        if (test.promptTokens == null) {
          expect(backend.texts.last, 'write a long random story of 1500 words.');
        } else {
          expect(backend.texts.last, endsWith(promptReviewRequest), reason: test.label);
          expect((backend.texts.last.length / 4 - test.promptTokens!).abs(), lessThan(test.promptTokens! * 0.02 + 2), reason: test.label);
        }
        // It records what it always recorded.
        final r = container.read(benchmarkProvider).result!;
        expect((r.promptLabel, r.firstTokenMillis, r.promptTokens, r.replyTokens), (test.label, 80, 100, 2), reason: test.label);
        expect((r.memory.ramSlots, r.turns.length), (191, 3), reason: test.label);
        expect(r.series, isNotNull, reason: test.label);
        expect(r.timeParts, isNotEmpty, reason: test.label);
      }
    });

    test('several tests: the warm-ups once, then each test in order from right after the warm-ups, one result', () async {
      await open(_InsightBackend());
      final notifier = container.read(benchmarkProvider.notifier);
      // (Chosen out of order: they run in the list's order, the reply speed first and the prompts small to large.)
      notifier.setSetup(const BenchmarkSetup(tests: []).toggled(BenchmarkTest.prompt25k).toggled(BenchmarkTest.prompts.first).toggled(BenchmarkTest.replySpeed));
      expect(container.read(benchmarkProvider).setup.tests, [BenchmarkTest.replySpeed, BenchmarkTest.prompts.first, BenchmarkTest.prompt25k]);
      await notifier.start(_file, 'M', 65536);
      expect(backend.texts.take(3), [...warmupMessages, replySpeedRequest]);
      expect(backend.texts, hasLength(5), reason: 'no warm-up between the tests');
      expect(backend.texts[3], startsWith('Story ${BenchmarkTest.prompts.first.story}'));
      expect(backend.texts[4], startsWith('Story ${BenchmarkTest.prompt25k.story}'));
      // Each test is sent after the warm-ups and their replies, without the test before it.
      expect(backend.prompts, [1, 3, 5, 5, 5]);
      for (final later in backend.asked.skip(3)) {
        expect([for (final m in later.take(4)) (m.role, m.text)], [for (final m in backend.asked[2].take(4)) (m.role, m.text)]);
      }
      expect(backend.caps, [2000, 2000, 2000, 200, 200]);
      // The run's conversation is erased once, at its end, and the engine stopped.
      expect(backend.calls.where((c) => c == 'erase'), hasLength(1));
      expect(backend.calls.last, 'stop');
      final r = container.read(benchmarkProvider).result!;
      expect([for (final t in r.tests) t.testId], ['reply', 'prompt-8k', 'prompt-25k']);
      expect(r.turns.map((t) => t.warmup), [true, true, false, false, false]);
      expect(r.tests.every((t) => t.timeParts.isNotEmpty), isTrue);
      expect(r.tests[2].promptText, startsWith('Story ${BenchmarkTest.prompt25k.story}'));
      // The headline is the reply speed's; the label names every test.
      expect((r.promptLabel, r.replyLength, r.promptText), ('Reply speed + Prompt 8k + Prompt 25k', 2000, replySpeedRequest));
      // One saved result holds every test, and reads back whole.
      final saved = (await store.benchmarks()).single;
      final again = BenchmarkResult.fromJson((jsonDecode(saved.$2) as Map).cast<String, Object?>());
      expect([for (final t in again.testResults) (t.testId, t.turn.promptTokens, t.timeParts.keys.length)], [
        for (final t in r.tests) (t.testId, t.turn.promptTokens, t.timeParts.keys.length),
      ]);
    });

    test('a test that does not fit the context is left out of the run; the others run', () async {
      await open(_Backend());
      final notifier = container.read(benchmarkProvider.notifier);
      expect(container.read(benchmarkProvider).setup.tests, BenchmarkSetup.defaultTests);
      expect(notifier.problem(contextLength: 4096), isNull);
      await notifier.start(_file, 'M', 4096);
      expect(backend.texts, [...warmupMessages, replySpeedRequest]);
      expect(container.read(benchmarkProvider).result!.tests.single.testId, 'reply');
      notifier.setSetup(const BenchmarkSetup(tests: []));
      expect(notifier.problem(contextLength: 4096), 'Choose a test.');
    });

    test('a run always uses the model\'s automatic preset at the chosen length, whatever the KV cache choice', () async {
      await open(_Backend());
      final notifier = container.read(benchmarkProvider.notifier);
      await notifier.start(_file, 'M', 65536);
      final first = backend.calls[1];
      expect(first, 'start:-c 65536 --auto');
      final r = container.read(benchmarkProvider).result!;
      expect((r.profileName, r.environment.profileId, r.contextLength), ('Auto', 'auto', 65536));
      // The KV cache choice is a placeholder: it is kept, and changes nothing in the run.
      for (final kv in KvCache.all) {
        notifier.setSetup(BenchmarkSetup(kvCache: kv));
        await notifier.start(_file, 'M', 65536);
        expect(backend.calls.where((c) => c.startsWith('start:')).last, first, reason: kv.id);
      }
      expect(container.read(benchmarkProvider).setup.kvCache, KvCache.fp16);
    });

    test('a prompt test that does not fit the context cannot start; the reply-speed test always can', () async {
      await open(_Backend());
      final notifier = container.read(benchmarkProvider.notifier);
      notifier.setSetup(const BenchmarkSetup(tests: [BenchmarkTest.replySpeed]));
      expect(notifier.problem(contextLength: 4096), isNull);
      notifier.setSetup(BenchmarkSetup(tests: [BenchmarkTest.prompts[2]]));
      expect(notifier.problem(contextLength: 32768), 'The chosen tests need a longer context length.');
      expect(notifier.problem(contextLength: 65536), isNull);
    });

    test('a setup saved by the version before opens with the defaults and runs', () async {
      await open(_Backend(), saved: const {
        'profileId': 'test',
        'contextLength': 32768,
        'promptId': '16k',
        'customText': 'my own text',
        'replyLength': 512,
        'warmups': ['one', 'two', 'three'],
        'testFlags': '-c 4096 --something 1',
        'testMemoryCapGiB': 12.5,
      });
      final notifier = container.read(benchmarkProvider.notifier);
      final setup = container.read(benchmarkProvider).setup;
      expect((setup.contextLength, setup.kvCache, setup.tests), (32768, KvCache.q8, BenchmarkSetup.defaultTests));
      await notifier.start(_file, 'M', setup.contextLength);
      // (The stand-in's presets are 4k and 64k: the run uses what it is given.) Its tests are the default ones.
      expect(backend.texts.take(3), [...warmupMessages, replySpeedRequest]);
      expect(backend.texts, hasLength(4));
      expect(backend.texts.last, endsWith(promptReviewRequest));
      expect(await store.benchmarks(), hasLength(1));
    });

    test('Stop keeps nothing', () async {
      await open(_Backend());
      final notifier = container.read(benchmarkProvider.notifier);
      backend.hold = true;
      final run = notifier.start(_file, 'M', 4096);
      while (container.read(benchmarkProvider).phase != BenchmarkPhase.warmingUp) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      notifier.stop();
      await run;
      final state = container.read(benchmarkProvider);
      expect((state.running, state.result), (false, null));
      expect(state.note, contains('Nothing was saved'));
      expect(await store.benchmarks(), isEmpty);
    });

    test('every message is a turn with its own numbers: the warm-ups marked, the measured one last, kept with the result', () async {
      await open(_Backend());
      final lengths = <int>[];
      container.listen(benchmarkProvider, (_, state) {
        if (state.turns.isNotEmpty && (lengths.isEmpty || lengths.last != state.turns.length)) lengths.add(state.turns.length);
      });
      final notifier = container.read(benchmarkProvider.notifier);
      await notifier.start(_file, 'M', 4096);
      final state = container.read(benchmarkProvider);
      expect(state.turns, hasLength(3));
      expect(state.turns.map((t) => t.warmup), [true, true, false]);
      expect(lengths, [1, 2, 3], reason: 'a turn is added as it ends');
      for (final turn in state.turns) {
        expect((turn.promptTokens, turn.promptMillis, turn.replyTokens, turn.replyMillis), (100, 50.0, 2, 40.0));
        expect((turn.firstTokenMillis, turn.stopReason, turn.tokenGaps.length), (80, 'stop', 1));
        expect(turn.tokenMillis, [30.0, 10.0]);
      }
      // The headline of the result is its last turn, and the turns are in what the history keeps.
      final result = state.result!;
      expect(result.turns, hasLength(3));
      expect(result.turns.map((t) => t.warmup), [true, true, false]);
      expect((result.firstTokenMillis, result.replyTokens), (state.turns.last.firstTokenMillis, state.turns.last.replyTokens));
      final saved = BenchmarkResult.fromJson((jsonDecode((await store.benchmarks()).single.$2) as Map).cast<String, Object?>());
      expect(saved.turns.map((t) => t.warmup), [true, true, false]);
      expect(saved.turns.last.tokenMillis, [30.0, 10.0]);
    });

    test('every turn is placed on the run\'s time axis: from its message to its reply, one after the other, kept with the result', () async {
      await open(_Backend());
      // What the state said of the turn going on, each time it changed.
      final seen = <double>{};
      container.listen(benchmarkProvider, (_, state) {
        final start = state.turnStartSeconds;
        if (start != null) seen.add(start);
      });
      final notifier = container.read(benchmarkProvider.notifier);
      await notifier.start(_file, 'M', 4096);
      final state = container.read(benchmarkProvider);
      final turns = state.turns;
      expect(turns, hasLength(3));
      for (final t in turns) {
        expect(t.startSeconds, isNotNull);
        expect(t.endSeconds, isNotNull);
        expect(t.startSeconds!, greaterThanOrEqualTo(0));
        expect(t.endSeconds!, greaterThan(t.startSeconds!), reason: 'a reply takes time');
        expect((t.endSeconds! - t.startSeconds!) * 1000, greaterThanOrEqualTo(t.totalMillis - 25), reason: 'the same stretch the turn timed itself');
      }
      for (var i = 1; i < turns.length; i++) {
        expect(turns[i].startSeconds!, greaterThanOrEqualTo(turns[i - 1].endSeconds!), reason: 'turn ${i + 1} starts after turn $i ended');
      }
      // The state announced each turn's start while it was going on, and none is left once the run is over.
      expect(seen, {for (final t in turns) t.startSeconds!});
      expect(state.turnStartSeconds, isNull);
      // The measured turn lies inside the series' phases: after the warm-ups began, from where its prompt began.
      final phases = state.live!.phases;
      expect(turns.first.startSeconds!, greaterThanOrEqualTo(phases.firstWhere((p) => p.name == PhaseBand.warmUp).start));
      expect(turns.last.startSeconds!, greaterThanOrEqualTo(phases.firstWhere((p) => p.name == PhaseBand.prompt).start));
      // The times are in the history too, to a millisecond.
      final saved = BenchmarkResult.fromJson((jsonDecode((await store.benchmarks()).single.$2) as Map).cast<String, Object?>());
      for (var i = 0; i < turns.length; i++) {
        expect(saved.turns[i].startSeconds, closeTo(turns[i].startSeconds!, 0.0006));
        expect(saved.turns[i].endSeconds, closeTo(turns[i].endSeconds!, 0.0006));
      }
    });

    test('the start of the turn going on is known while it goes on, and is gone when the run stops', () async {
      final held = _HoldAtBackend(2);
      await open(held);
      final notifier = container.read(benchmarkProvider.notifier);
      final run = notifier.start(_file, 'M', 4096);
      expect(container.read(benchmarkProvider).turnStartSeconds, isNull, reason: 'the engine is loading, no turn has begun');
      // The second warm-up is the one that never ends.
      while (container.read(benchmarkProvider).warmup != 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final going = container.read(benchmarkProvider);
      expect(going.turns, hasLength(1));
      expect(going.turnStartSeconds, isNotNull);
      expect(going.turnStartSeconds!, greaterThanOrEqualTo(going.turns.first.endSeconds!), reason: 'the second turn began after the first ended');
      notifier.stop();
      await run;
      expect(container.read(benchmarkProvider).turnStartSeconds, isNull);
    });

    test('each turn keeps the counters of its own reply, and the result\'s are those of the measured turn', () async {
      await open(_CountersBackend());
      final notifier = container.read(benchmarkProvider.notifier);
      await notifier.start(_file, 'M', 4096);
      final result = container.read(benchmarkProvider).result!;
      expect(result.turns.map((t) => t.ssdWaitPerToken), [1.5, 3.0, 4.5]);
      expect(result.turns.map((t) => t.hitRate), [91.0, 92.0, 93.0]);
      expect((result.ssdWaitPerToken, result.hitRate), (4.5, 93.0));
    });

    test('a new run starts its turns afresh: warm-ups first, the measured turn last', () async {
      await open(_Backend());
      final notifier = container.read(benchmarkProvider.notifier);
      await notifier.start(_file, 'M', 4096);
      expect(container.read(benchmarkProvider).turns, hasLength(3));
      await notifier.start(_file, 'M', 4096);
      final state = container.read(benchmarkProvider);
      expect(state.turns.map((t) => t.warmup), [true, true, false]);
      expect(state.result!.turns, hasLength(3));
    });

    test('Stop during a warm-up keeps no measured turn and no result', () async {
      final held = _HoldAtBackend(2);
      await open(held);
      final notifier = container.read(benchmarkProvider.notifier);
      final run = notifier.start(_file, 'M', 4096);
      // The second warm-up is the one that never ends.
      while (container.read(benchmarkProvider).warmup != 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      notifier.stop();
      await run;
      final state = container.read(benchmarkProvider);
      expect((state.running, state.result), (false, null));
      expect(state.turns.map((t) => t.warmup), [true], reason: 'the first warm-up ended; the stopped one is not a turn');
      expect(held.prompts, [1, 3], reason: 'the measured message was never sent');
      expect(await store.benchmarks(), isEmpty);
    });

    test('a run can be deleted from the history, and the history stays bounded in the store', () async {
      await open(_Backend());
      final notifier = container.read(benchmarkProvider.notifier);
      await notifier.start(_file, 'M', 4096);
      await notifier.start(_file, 'M', 4096);
      expect(container.read(benchmarkProvider).history, hasLength(2));
      notifier.delete(container.read(benchmarkProvider).history.first);
      await store.flush();
      expect(container.read(benchmarkProvider).history, hasLength(1));
      expect(container.read(benchmarkProvider).result, isNull, reason: 'the shown result was the deleted one');
      expect(await store.benchmarks(), hasLength(1));
    });

    test('the engine is told which chats are pinned', () async {
      await open(_Backend());
      final chats = container.read(chatsProvider.notifier);
      expect(backend.pinned, isEmpty, reason: 'told at the start');
      chats.send('hi', _file);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final id = container.read(chatsProvider).openId!;
      chats.pin(id);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(backend.pinned, [id]);
      chats.unpin(id);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(backend.pinned, isEmpty);
    });

    test('the setup is remembered', () async {
      await open(_Backend());
      container.read(benchmarkProvider.notifier).setSetup(BenchmarkSetup(contextLength: 8192, kvCache: KvCache.q4, tests: [BenchmarkTest.prompts.last]));
      final again = BenchmarkSetup.fromJson(Storage(dir).readBenchmarkSetup()!);
      expect((again.contextLength, again.kvCache, again.tests.single), (8192, KvCache.q4, BenchmarkTest.prompts.last));
    });
  });
}
