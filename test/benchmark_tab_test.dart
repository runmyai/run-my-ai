// The Benchmark tab as widgets, with made-up numbers: every part draws without an error at a desktop width and at a
// narrow one, rows and folds open, a word picked in the result moves the graphs' cursor, a history row opens, and a
// prompt that does not fit the context is greyed. No engine runs and no machine is read.
// Run: flutter test test/benchmark_tab_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/benchmark/benchmark.dart';
import 'package:runmyai/benchmark/hardware.dart';
import 'package:runmyai/benchmark/memory_layout.dart';
import 'package:runmyai/benchmark/series.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/benchmark.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/benchmark/live_graphs.dart';
import 'package:runmyai/ui/pages/engine_page.dart';

const _file = ModelFile(id: 'm/f', quantization: 'q', sizeBytes: 1);
const _model = CatalogModel(
  id: 'm',
  name: 'Test Model',
  lab: 'L',
  description: '',
  parameters: '1B',
  activeParameters: '1B',
  files: [_file],
  thinking: ModelThinking.optional,
);

class _Backend implements Backend, EngineControl {
  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) => const Stream.empty();
  @override
  Future<void> startEngine(ModelFile file, EngineRun run, {bool restart = false}) async {}
  @override
  Future<void> stopEngine() async {}
  @override
  Future<void> eraseChatState(String chatId) async {}
  @override
  Future<void> setPinnedChats(List<String> chatIds) async {}
  @override
  Future<String?> reportedVersion() async => null;
  @override
  ValueListenable<EngineState> get engineState => ValueNotifier(const EngineState(EnginePhase.stopped));
  @override
  List<String> get logLines => const [];
  @override
  Listenable get logChanged => ChangeNotifier();
  @override
  Map<int, String> autoCommands(ModelFile file) => const {4096: '-c 4096 --a 1', 65536: '-c 65536 --a 1'};
  @override
  int maxContext(ModelFile file) => 65536;
  @override
  Future<List<CatalogModel>> loadCatalog() async => const [_model];
  @override
  Stream<double> download(ModelFile file) => const Stream.empty();
  @override
  Future<void> deleteDownload(ModelFile file) async {}
}

/// A benchmark notifier that starts in the state it is given.
class _Fake extends BenchmarkNotifier {
  _Fake(this.initial);
  final BenchmarkState initial;

  @override
  BenchmarkState build() => initial;
}

class _TabBenchmark extends EngineTabNotifier {
  @override
  bool build() => true;
}

/// A run of [seconds] with every series the live view draws.
RunSeries _series(double seconds) {
  final s = RunSeries();
  for (var t = 0.0; t <= seconds; t += 0.5) {
    final reply = t > seconds * 0.6;
    s.add(t, {
      'speed.words': reply ? 40 + (t % 3) : null,
      'speed.prompt': !reply && t > seconds * 0.4 ? 420 : null,
      'speed.ttft': reply ? 1.7 : null,
      'gpu.0.load': 20 + (t * 7) % 70,
      'gpu.0.power': 30 + (t * 5) % 90,
      'gpu.0.powerLimit': 140,
      'gpu.0.powerMax': 140,
      'gpu.0.clock': 1700 + (t * 11) % 600,
      'gpu.0.clockMax': 3285,
      'gpu.0.temp': 50 + t / 4,
      'gpu.0.tempMax': 99,
      'gpu.0.vram': 9.8,
      'gpu.0.vramTotal': 11.9,
      'gpu.0.pcieTx': 300 + t,
      'gpu.0.pcieRx': 1200 + t,
      'gpu.0.pcieMax': 7880,
      'gpu.0.reasons': t > 20 && t < 25 ? 4 : 0,
      'cpu.load': 40 + (t * 3) % 40,
      'cpu.other': 3,
      'cpu.mhz': 3200,
      'cpu.mhzMax': 5100,
      'cpu.power': 30,
      'cpu.temp': 70,
      'cpu.core.0.load': 90,
      'cpu.core.1.load': 30,
      'cpu.core.0.mhz': 4800,
      'cpu.core.0.mhzMax': 5100,
      'ram.total': 30,
      'ram.used': 12 + t / 20,
      'ram.engine': 9,
      'ram.other': 3 + t / 20,
      'ram.cache': 5,
      'ram.swap': 0.2,
      'ram.swapTotal': 8,
      'ram.swapActivity': t % 5,
      'ssd.read': 3 + (t % 4),
      'ssd.readMax': 7.9,
      'ssd.busy': 60,
      'ssd.iops': 5000 + t,
      'ssd.queue': 12,
      'ssd.temp': 50,
      'ssd.tempMax': 85,
      'eng.stall': reply ? 5 + t % 2 : null,
      'eng.ramHit': reply ? 96 : null,
      'eng.vramHit': reply ? 30 : null,
      'eng.expRam': 7800,
      'eng.expRamMax': 7831,
      'eng.expVram': 2500,
      'eng.reads': reply ? 3 : null,
      'eng.gInTime': reply ? 70 : null,
      'eng.gLate': reply ? 20 : null,
      'eng.gMissed': reply ? 10 : null,
      'eng.gWasted': reply ? 0 : null,
      'eng.gCancelled': reply ? 0 : null,
      'eng.swaps': reply ? 0.4 : null,
    });
  }
  s
    ..beginPhase(PhaseBand.load, 0)
    ..beginPhase(PhaseBand.warmUp, seconds * 0.2)
    ..beginPhase(PhaseBand.prompt, seconds * 0.4)
    ..beginPhase(PhaseBand.reply, seconds * 0.6)
    ..endPhases(seconds);
  return s;
}

BenchmarkResult _result({int id = 1, double speed = 40, RunSeries? series, String flags = '-c 65536 --a 1 --temp 0'}) {
  final words = [for (var i = 0; i < 300; i++) 20 + (i % 17) + (i % 50 == 0 ? 60 : 0).toDouble()];
  return BenchmarkResult(
    id: id,
    at: DateTime(2026, 3, 4, 5, 6),
    modelName: 'Test Model',
    contextLength: 65536,
    profileName: 'Auto',
    flags: flags,
    memoryCapGiB: null,
    promptLabel: 'Story chat',
    replyLength: 1024,
    warmups: const ['warm 1', 'warm 2'],
    loadMillis: 12000,
    firstWordMillis: 1700,
    promptTokens: 1000,
    promptMillis: 2400,
    replyTokens: 300,
    replyMillis: 300 * 1000 / speed,
    wordGaps: const [],
    wordMillis: words,
    engineStats: const {
      'layers': 41,
      'slots': 191,
      'hit_rate_percent': 95.0,
      'prompt': {'mib_read': 900.0, 'hit_rate_percent': 80.0},
      'reply': {'mib_read': 2400.0, 'mib_per_token': 8.0, 'misses': 700.0, 'misses_per_token': 2.3, 'hit_rate_percent': 96.0, 'stall_ms_per_token': 6.0},
    },
    log: const ['llama_moe_stream: 14.20 GiB of pools = 191 slots per layer x 41 layers'],
    disturbed: const ['The computer was on battery.'],
    promptText: 'Write me a long story.',
    thinking: false,
    replyText: 'Once upon a time',
    stopReason: 'stop',
    totalMillis: 10000,
    timeParts: const {'SSD wait': 6.0, 'CPU': 9.0, 'GPU': 6.0, 'CPU-GPU sync': 1.0},
    layers: [for (var i = 0; i < 41; i++) {'misses': 10.0 + i, 'stall_ms': 100.0 + i * 3}],
    series: series ?? _series(60),
    memory: const MemoryLayout(ramSlots: 191, streamedLayers: 41, vramExpertsPerLayer: 62, gpuLayers: 2, kvMiB: 1020, freeRamGiB: 22),
    environment: RunEnvironment(
      engineVersion: '0.8.0',
      appVersion: '0.1.0',
      modelFileBytes: 70147512048,
      modelFileModified: DateTime(2026, 1, 2),
      onBattery: true,
      addedFlags: const ['--moe-stream-timing 1'],
    ),
  );
}

void main() {
  test('time on the axis is written in seconds, then minutes', () {
    expect(formatSeconds(42), '42 s');
    expect(formatSeconds(125), '2:05');
    expect(niceStep(30), 5);
    expect(niceStep(600), 120);
  });

  group('the tab', _tab);
}

/// Scrolls the page until [finder] is inside the window (a widget the list has built is not always on screen).
Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 300, scrollable: find.byType(Scrollable).first);
  for (var i = 0; i < 30 && tester.getCenter(finder).dy > 2700; i++) {
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _tab() {
  late Directory dir;
  late ChatStore store;

  /// The tab, with [state] as what the benchmark notifier holds, in a window [width] wide.
  Future<void> pump(WidgetTester tester, BenchmarkState state, {double width = 1300}) async {
    tester.view
      ..physicalSize = Size(width, 3000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async => store = await ChatStore.open(dir));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(Storage(dir)),
          chatStoreProvider.overrideWithValue(store),
          backendProvider.overrideWithValue(_Backend()),
          shownModelProvider.overrideWithValue((model: _model, file: _file)),
          shownContextProvider.overrideWithValue((options: const [4096, 65536], value: 65536)),
          benchmarkProvider.overrideWith(() => _Fake(state)),
          engineTabProvider.overrideWith(_TabBenchmark.new),
        ],
        child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: EnginePage())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  setUp(() => dir = Directory.systemTemp.createTempSync('runmyai-tab-'));
  tearDown(() async {
    await store.close();
    dir.deleteSync(recursive: true);
  });

  testWidgets('a first look is the settings, an empty live view and an empty history', (tester) async {
    await pump(tester, const BenchmarkState());
    expect(tester.takeException(), isNull);
    for (final title in ['SETTINGS', 'LIVE', 'HISTORY']) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('FULL RESULT'), findsNothing, reason: 'it appears after a run');
    expect(find.byKey(const Key('benchmark-start')), findsOneWidget);
    expect(find.text('For accurate results, close other apps first.'), findsOneWidget);
    expect(find.text('Press Start. The graphs fill in while the run goes on.'), findsOneWidget);
    expect(find.text('Finished runs are kept here.'), findsOneWidget);
    expect(find.text('Test mode'), findsOneWidget);
    expect(find.byKey(const Key('benchmark-thinking')), findsOneWidget);
    // Detail stays behind a click.
    expect(find.textContaining('--a 1'), findsNothing);
  });

  testWidgets('a prompt that does not fit the context is greyed, and Test mode opens its own flags', (tester) async {
    await pump(tester, const BenchmarkState(setup: BenchmarkSetup(contextLength: 4096)));
    await tester.tap(find.byKey(const Key('benchmark-context-4096')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // (Greyed: no tap does anything.)
    await tester.tap(find.byKey(const Key('benchmark-prompt-32k')), warnIfMissed: false);
    await tester.pump();
    expect(find.text('Varied real text, cut to about 32k tokens as the engine counts them.'), findsNothing);
    await tester.tap(find.byKey(const Key('benchmark-test-mode')));
    await tester.pump();
    expect(find.byKey(const Key('benchmark-test-flags')), findsOneWidget);
    expect(find.byKey(const Key('benchmark-context-4096')), findsNothing, reason: 'Test mode takes the length from its flags');
  });

  testWidgets('the live graphs: rows open to every value against its limit, a line opens its detail, hovering moves the cursor', (tester) async {
    final series = _series(60);
    await pump(tester, BenchmarkState(live: series, revision: 5, counters: EngineCounters.available, hardware: const HardwareInfo(gpus: ['Test GPU'])));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('graph-row-gpu.0')), findsOneWidget);
    expect(find.textContaining('of 140 W'), findsWidgets);

    await tester.tap(find.byKey(const Key('graph-row-gpu.0')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('meter-gpu.0.power')), findsOneWidget);
    expect(find.byKey(const Key('meter-gpu.0.pcieRx')), findsOneWidget);
    await tester.tap(find.byKey(const Key('meter-gpu.0.clock')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('Clock: lowest'), findsOneWidget);

    await tester.tap(find.byKey(const Key('graph-row-cpu')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('Each core'), findsOneWidget);
    await tester.tap(find.byKey(const Key('graph-row-engine')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('meter-eng.gInTime')), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    final at = tester.getCenter(find.byKey(const Key('graph-row-ram'))) + const Offset(0, 40);
    await mouse.moveTo(at);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a row says so when the machine or the engine gives nothing', (tester) async {
    final bare = RunSeries();
    for (var t = 0.0; t < 5; t += 0.5) {
      bare.add(t, {'cpu.load': 10, 'ram.total': 30, 'ram.used': 10});
    }
    await pump(tester, BenchmarkState(live: bare, revision: 1, counters: EngineCounters.missing));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('no graphics card could be read'), findsOneWidget);
    expect(find.textContaining('does not report its counters'), findsOneWidget);
  });

  testWidgets('the full result: numbers first, detail on click, a word moves the graphs\' cursor, compare shows the changes', (tester) async {
    final shown = _result(id: 2);
    final earlier = _result(id: 1, speed: 36, flags: '-c 65536 --a 2 --temp 0 --extra 1');
    await pump(tester, BenchmarkState(result: shown, live: shown.series, history: [shown, earlier], disturbed: shown.disturbed));
    expect(tester.takeException(), isNull);
    expect(find.text('FULL RESULT'), findsOneWidget);
    for (final key in ['reply-speed', 'first-word', 'prompt-speed', 'load', 'slowest-1', 'slowest-word', 'total']) {
      expect(find.byKey(Key('result-$key')), findsOneWidget, reason: key);
    }
    expect(find.textContaining('Disturbed: The computer was on battery.'), findsWidgets);
    expect(find.textContaining('SSD wait 6.0 ms'), findsOneWidget);

    // Picking a word puts the cursor on its moment.
    await tester.tap(find.byKey(const Key('words-chart')).first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);

    for (final title in [
      'Phases',
      'Streaming from the SSD',
      'Memory layout',
      'Each layer',
      'Hardware over the run',
      'Sanity: the reply and why it ended',
      'Setup record',
      'Compare with another run',
      'Engine output',
    ]) {
      final fold = find.byKey(Key('fold-$title')).first;
      await reveal(tester, fold);
      await tester.tap(fold);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull, reason: title);
    }
    expect(find.textContaining('191 per layer'), findsOneWidget);
    expect(find.textContaining('Once upon a time'), findsOneWidget);
    expect(find.textContaining('Added by the benchmark: --moe-stream-timing 1'), findsOneWidget);

    await reveal(tester, find.byKey(const Key('compare-pick')));
    await tester.tap(find.byKey(const Key('compare-pick')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(MenuItemButton), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(MenuItemButton), matching: find.textContaining('36.0 tokens/s')));
    // (The menu runs its item's action as it closes, a frame later.)
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    expect(find.text('Generation speed'), findsWidgets);
    expect(find.textContaining('against'), findsWidgets);
    expect(find.text('better'), findsWidgets);
    expect(find.textContaining('--a'), findsWidgets);
  });

  testWidgets('a run in the history is a row; a click opens its result with the graphs it was made with; delete asks twice', (tester) async {
    final run = _result(id: 7);
    await pump(tester, BenchmarkState(history: [run]));
    expect(tester.takeException(), isNull);
    expect(find.text('FULL RESULT'), findsNothing);
    expect(find.textContaining('Test Model  ·  Auto  ·  65k  ·  Story chat'), findsOneWidget);
    expect(find.textContaining('Disturbed'), findsOneWidget);
    expect(find.text('40.0 tokens/s'), findsOneWidget);

    await tester.tap(find.byKey(const Key('history-7')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('graph-row-gpu.0')), findsOneWidget, reason: 'the stored graphs');
    expect(find.byKey(const Key('result-reply-speed')), findsOneWidget);

    await tester.tap(find.byKey(const Key('history-delete-7')));
    await tester.pump();
    expect(find.text('Delete this run'), findsOneWidget, reason: 'one click only asks');
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Delete this run'), findsNothing, reason: 'and the question goes away by itself');
  });

  testWidgets('a narrow window gives no overflow', (tester) async {
    final shown = _result();
    await pump(tester, BenchmarkState(result: shown, live: shown.series, history: [shown]), width: 700);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('graph-row-gpu.0')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

}

