// What a benchmark run does and keeps: the order of its messages, the machine and engine readings it collects, its
// phases, the flags it adds, the history. No model and no GPU are used.
// Run: flutter test test/benchmark_test.dart
import 'dart:async';
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
      _ticks.add(SystemSample(0.004 * ++_n, {'cpu.load': 5, 'cpu.other': 1, 'gpu.0.load': 1, 'sys.battery': 0}));
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
  Future<void> startEngine(ModelFile file, EngineRun run, {bool restart = false}) async => calls.add('start:${run.flags}');
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

void main() {
  group('context options', () {
    const m = 1000000;
    test('the standard lengths up to the model\'s longest', () {
      expect(contextOptions(262144).map(contextLabel), ['4k', '8k', '16k', '32k', '65k', '131k', '262k']);
      expect(contextOptions(300000).last, 262144);
    });

    test('at the top of the list', () {
      expect(contextOptions(10485760).map(contextLabel).last, '10M');
      expect(contextOptions(2097152).map(contextLabel).toList().sublist(7), ['524k', '1M', '2M']);
    });

    test('a 15M model: after 10M, 15M', () {
      expect(contextOptions(15000000).map(contextLabel).toList().sublist(10), ['5M', '10M', '15M']);
    });

    test('above 10M the only further option is the model\'s own longest', () {
      final options = contextOptions(20 * m);
      expect(options.map(contextLabel).toList().sublist(11), ['10M', '20M']);
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

  test('a setup from an older version still opens: an unknown prompt is the story', () {
    final setup = BenchmarkSetup.fromJson({'promptId': '8k', 'replyLength': 5});
    expect((setup.promptId, setup.replyLength, setup.contextLength), ('story', 5, defaultContextLength));
  });

  group('a run', () {
    late Directory dir;
    late ChatStore store;
    late _Backend backend;
    late ProviderContainer container;

    Future<void> open(_Backend b) async {
      dir = Directory.systemTemp.createTempSync('runmyai-bench-');
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
            (ref) => PromptCorpus([
              for (var s = 0; s < 4; s++) [for (var p = 0; p < 400; p++) 'Source $s passage $p ${'word ' * 40}'].join('\n\n'),
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
      notifier.setSetup(const BenchmarkSetup(warmups: ['w1', 'w2'], replyLength: 77));
      await notifier.start(_file, 'M', 4096);
      expect(backend.calls, ['stop', 'start:-c 4096 --auto', 'reply:w1:77', 'reply:w2:77', 'reply:Wr:77', 'erase', 'stop']);
      expect(backend.prompts, [1, 3, 5], reason: 'one conversation');
      expect(backend.runs.every((r) => !r.keepState && r.reportProgress), isTrue, reason: 'nothing is saved for a run');
      final state = container.read(benchmarkProvider);
      final result = state.result!;
      expect(state.running, isFalse);
      expect((result.replyTokens, result.promptTokens, result.wordGaps.length), (2, 100, 1));
      expect(result.log, hasLength(2));
      expect(await store.benchmarks(), hasLength(1));
      expect(result.id, isNotNull);
      expect(state.history.single.id, result.id);
    });

    test('it keeps the engine\'s word times, how the reply ended, the phases, the machine and the record', () async {
      await open(_Backend());
      final notifier = container.read(benchmarkProvider.notifier);
      notifier.setSetup(const BenchmarkSetup(warmups: ['w1'], replyLength: 77));
      await notifier.start(_file, 'M', 4096, thinking: ModelThinking.optional);
      final r = container.read(benchmarkProvider).result!;
      expect(r.wordMillis, [30, 10]);
      expect(r.slowestWord, 30);
      expect((r.stopReason, r.replyText), ('stop', 'one two'));
      expect(r.thinking, isNotNull);
      // 40 ms of the reply and 50 ms of the prompt, and the first word is the prompt and the first word's own time.
      expect(r.firstWordMillis, 80);
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
      expect(r.promptText, startsWith('Write me'));
      // It comes back whole from the database.
      final again = (await store.benchmarks()).single;
      expect(again.$2, contains('"wordMillis"'));
    });

    test('the engine\'s counters, once a second, give the parts of a word and each layer; the timing flag is added', () async {
      final insight = _InsightBackend();
      await open(insight);
      final notifier = container.read(benchmarkProvider.notifier);
      notifier.setSetup(const BenchmarkSetup(warmups: [], replyLength: 9));
      await notifier.start(_file, 'M', 4096);
      final r = container.read(benchmarkProvider).result!;
      expect(insight.calls[1], 'start:-c 4096 --auto --moe-stream-timing 1');
      expect(r.flags, endsWith('--moe-stream-timing 1'));
      expect(r.environment.addedFlags, ['--moe-stream-timing 1']);
      expect(r.environment.modelFileBytes, 1234567);
      expect(r.timeParts.keys, containsAll(['SSD wait', 'CPU', 'GPU']));
      expect(r.timeParts['CPU'], closeTo(10, 0.001), reason: '100 ms for 10 words');
      expect(r.layers, hasLength(2));
      expect(container.read(benchmarkProvider).counters, EngineCounters.available);
    });

    test('the timing flag is left out when the engine does not know it, or the user set it', () async {
      final insight = _InsightBackend()..accepts = false;
      await open(insight);
      final notifier = container.read(benchmarkProvider.notifier);
      notifier.setSetup(const BenchmarkSetup(warmups: []));
      await notifier.start(_file, 'M', 4096);
      expect(insight.calls[1], 'start:-c 4096 --auto');
      expect(container.read(benchmarkProvider).result!.environment.addedFlags, isEmpty);

      insight.accepts = true;
      notifier.setSetup(const BenchmarkSetup(profileId: 'test', testFlags: '-c 4096 --moe-stream-timing 0', warmups: []));
      await notifier.start(_file, 'M', 4096);
      expect(insight.calls.where((c) => c.startsWith('start:')).last, 'start:-c 4096 --moe-stream-timing 0');
    });

    test('a long prompt is cut to its size by the engine\'s own count', () async {
      await open(_InsightBackend());
      final notifier = container.read(benchmarkProvider.notifier);
      notifier.setSetup(const BenchmarkSetup(warmups: [], promptId: '1k', replyLength: 9));
      await notifier.start(_file, 'M', 65536);
      final r = container.read(benchmarkProvider).result!;
      expect(r.promptLabel, '1k');
      // (The stand-in counts a token for four characters.)
      expect((r.promptText.length / 4 - 1000).abs(), lessThan(40));
      expect(r.promptText, startsWith('Below is a collection'));
    });

    test('Test mode runs its own flags; a bad command cannot start', () async {
      await open(_Backend());
      final notifier = container.read(benchmarkProvider.notifier);
      notifier.setSetup(const BenchmarkSetup(profileId: 'test', testFlags: '-m x', warmups: []));
      expect(notifier.problem(_file), contains('the app sets it'));
      notifier.setSetup(const BenchmarkSetup(profileId: 'test', testFlags: '-c 8192 --mine', warmups: []));
      expect(notifier.problem(_file), isNull);
      await notifier.start(_file, 'M', 4096);
      expect(backend.calls[1], 'start:-c 8192 --mine');
      expect(container.read(benchmarkProvider).result!.profileName, 'Test');
    });

    test('a prompt that does not fit the context cannot start', () async {
      await open(_Backend());
      final notifier = container.read(benchmarkProvider.notifier);
      notifier.setSetup(const BenchmarkSetup(promptId: '32k'));
      expect(notifier.problem(_file, contextLength: 32768), contains('does not fit'));
      expect(notifier.problem(_file, contextLength: 65536), isNull);
    });

    test('Stop keeps nothing', () async {
      await open(_Backend());
      final notifier = container.read(benchmarkProvider.notifier);
      notifier.setSetup(const BenchmarkSetup(warmups: ['w1', 'w2']));
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

    test('a run can be deleted from the history, and the history stays bounded in the store', () async {
      await open(_Backend());
      final notifier = container.read(benchmarkProvider.notifier);
      notifier.setSetup(const BenchmarkSetup(warmups: []));
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
      container.read(benchmarkProvider.notifier).setSetup(const BenchmarkSetup(testFlags: '-c 1', replyLength: 5, contextLength: 8192));
      final again = BenchmarkSetup.fromJson(Storage(dir).readBenchmarkSetup()!);
      expect((again.testFlags, again.replyLength, again.contextLength), ('-c 1', 5, 8192));
    });
  });
}
