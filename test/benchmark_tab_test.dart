// The Benchmark tab as widgets, with made-up numbers: every part draws without an error at a desktop width and at a
// narrow one, rows and folds open, a token picked in a chart moves the graphs' cursor, each turn has its own stretch of
// the graphs and its own details (and the whole run its own tab, with the numbers of all the turns together), a run that
// ends stays on Live, a history row opens, no disturbance message is shown, and the setup (three drop-downs, a line on
// what the test does, Start; a prompt test that does not fit the context is greyed; a saved setup of an older version
// opens). No engine runs and no machine is read.
// Run: flutter test test/benchmark_tab_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:runmyai/ui/benchmark/fold.dart';
import 'package:runmyai/ui/benchmark/live_graphs.dart';
import 'package:runmyai/ui/buttons.dart';
import 'package:runmyai/ui/pages/engine_page.dart';
import 'package:runmyai/ui/select_box.dart';

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

  /// Moves the state on, as a run does while the tab is on screen.
  void put(BenchmarkState next) => state = next;
}

class _TabBenchmark extends EngineTabNotifier {
  @override
  bool build() => true;
}

class _TabRun extends EngineTabNotifier {
  @override
  bool build() => false;
}

/// A run of [seconds] with every series the live view draws.
RunSeries _series(double seconds) {
  final s = RunSeries();
  for (var t = 0.0; t <= seconds; t += 0.5) {
    final reply = t > seconds * 0.6;
    s.add(t, {
      'speed.tokens': reply ? 40 + (t % 3) : null,
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

/// The turns of a run with two warm-ups: the first slow and with all the engine's counters, the second with only a wait on
/// the SSD, the last measured and with none.
List<TurnRecord> _turns() => const [
  TurnRecord(
    warmup: true,
    firstTokenMillis: 4200,
    promptTokens: 100,
    promptMillis: 500,
    replyTokens: 50,
    replyMillis: 2000,
    totalMillis: 6500,
    stopReason: 'stop',
    tokenMillis: [40, 41, 42, 90],
    engineStats: {
      'prompt': {'mib_read': 100.0},
      'reply': {
        'stall_ms_per_token': 8.0,
        'hit_rate_percent': 61.5,
        'expert_uses': 1000.0,
        'ram_hit_percent': 60.0,
        'vram_hit_percent': 10.0,
        'misses': 300.0,
        'mib_read': 900.0,
        'stall_ms': 400.0,
        'guesses': {'in_time': 50.0, 'late': 30.0, 'missed': 20.0},
      },
      'time_per_word': {'ssd_wait_ms': 8.0, 'cpu_ms': 20.0, 'gpu_ms': 9.0, 'handoff_ms': 4.0, 'rest_ms': 1.0},
      'per_layer': [
        {'hits': 10.0, 'misses': 5.0, 'stall_ms': 20.0},
        {'hits': 12.0, 'misses': 3.0, 'stall_ms': 10.0},
        {'hits': 14.0, 'misses': 1.0, 'stall_ms': 5.0},
      ],
    },
  ),
  TurnRecord(
    warmup: true,
    firstTokenMillis: 2600,
    promptTokens: 90,
    promptMillis: 300,
    replyTokens: 48,
    replyMillis: 1500,
    totalMillis: 3000,
    stopReason: 'stop',
    tokenMillis: [24, 25, 26, 55],
    engineStats: {'reply': {'stall_ms_per_token': 4.0, 'hit_rate_percent': 80.0}},
  ),
  TurnRecord(
    warmup: false,
    firstTokenMillis: 1700,
    promptTokens: 1000,
    promptMillis: 2400,
    replyTokens: 300,
    replyMillis: 7500,
    totalMillis: 10000,
    stopReason: 'stop',
    tokenMillis: [20, 21, 22, 70],
    engineStats: {
      'prompt': {'mib_read': 100.0},
      'reply': {
        'stall_ms_per_token': 5.4,
        'hit_rate_percent': 90.0,
        'expert_uses': 1000.0,
        'ram_hit_percent': 60.0,
        'vram_hit_percent': 30.0,
        'misses': 100.0,
        'mib_read': 900.0,
        'stall_ms': 400.0,
        'guesses': {'in_time': 50.0, 'late': 30.0, 'missed': 20.0, 'wasted': 10.0, 'cancelled': 5.0},
      },
      'time_per_word': {'ssd_wait_ms': 5.4, 'cpu_ms': 10.0, 'gpu_ms': 9.0, 'handoff_ms': 4.0, 'rest_ms': 1.0},
      'per_layer': [
        {'hits': 10.0, 'misses': 5.0, 'stall_ms': 20.0},
        {'hits': 12.0, 'misses': 3.0, 'stall_ms': 10.0},
        {'hits': 14.0, 'misses': 1.0, 'stall_ms': 5.0},
      ],
    },
  ),
];

/// [turns] placed on the run's time axis, turn by turn at the given (start, end) seconds.
List<TurnRecord> _timed(List<TurnRecord> turns, List<(double, double)> places) => [
  for (var i = 0; i < turns.length; i++)
    TurnRecord(
      warmup: turns[i].warmup,
      firstTokenMillis: turns[i].firstTokenMillis,
      promptTokens: turns[i].promptTokens,
      promptMillis: turns[i].promptMillis,
      replyTokens: turns[i].replyTokens,
      replyMillis: turns[i].replyMillis,
      totalMillis: turns[i].totalMillis,
      stopReason: turns[i].stopReason,
      tokenMillis: turns[i].tokenMillis,
      engineStats: turns[i].engineStats,
      startSeconds: places[i].$1,
      endSeconds: places[i].$2,
    ),
];

/// A run of [seconds], one tick a second, whose CPU load is the second it is at: a moment can be read off the row.
RunSeries _ramp(int seconds) {
  final s = RunSeries();
  for (var t = 0; t <= seconds; t++) {
    s.add(t.toDouble(), {'cpu.load': t.toDouble()});
  }
  s
    ..beginPhase(PhaseBand.load, 0)
    ..beginPhase(PhaseBand.prompt, seconds * 0.5)
    ..endPhases(seconds.toDouble());
  return s;
}

BenchmarkResult _result({
  int id = 1,
  double speed = 40,
  RunSeries? series,
  String flags = '-c 65536 --a 1 --temp 0',
  List<TurnRecord> turns = const [],
}) {
  final tokens = [for (var i = 0; i < 300; i++) 20 + (i % 17) + (i % 50 == 0 ? 60 : 0).toDouble()];
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
    firstTokenMillis: 1700,
    promptTokens: 1000,
    promptMillis: 2400,
    replyTokens: 300,
    replyMillis: 300 * 1000 / speed,
    tokenGaps: const [],
    tokenMillis: tokens,
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
    timeParts: const {'SSD wait': 6.0, 'CPU': 9.0, 'GPU': 6.0, 'CPU→GPU copies': 0.4, 'CPU-GPU sync': 0.6},
    layers: [for (var i = 0; i < 41; i++) {'misses': 10.0 + i, 'stall_ms': 100.0 + i * 3}],
    turns: turns,
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

  group('the span of the axis', _span);
  group('graphs of a window', _window);
  group('the tab', _tab);
}

void _span() {
  test('without a window it is the whole run, from 0 to its end, and at least a second long', () {
    final whole = AxisSpan.of(60, null);
    expect((whole.from, whole.to, whole.length, whole.windowed), (0, 60, 60, false));
    expect(AxisSpan.of(0, null).to, 1, reason: 'a run with no tick yet still has an axis');
    expect(AxisSpan.of(0.4, null).to, 1);
  });

  test('a window is exactly that stretch, at least a second wide', () {
    final w = AxisSpan.of(100, (20, 40));
    expect((w.from, w.to, w.length, w.windowed), (20, 40, 20, true));
    expect(AxisSpan.of(100, (20, 20.2)).to, 21, reason: 'a turn that has only just begun');
    expect(AxisSpan.of(100, (20, 20)).to, 21);
    expect(AxisSpan.of(100, (30, 10)).to, 31, reason: 'an end before the start is not a negative stretch');
    expect(AxisSpan.of(10, (20, 40)).to, 40, reason: 'the run\'s own end does not limit a window');
  });

  test('a moment and a place on the axis map both ways, from the window\'s start', () {
    final w = AxisSpan.of(100, (20, 40));
    expect((w.x(20, 200), w.x(30, 200), w.x(40, 200)), (0, 100, 200));
    expect(w.x(10, 200), -100, reason: 'a moment before the window is left of the axis');
    expect((w.timeAt(0, 200), w.timeAt(100, 200), w.timeAt(200, 200)), (20, 30, 40));
    expect((w.timeAt(-5, 200), w.timeAt(250, 200)), (20, 40), reason: 'outside the axis counts as its edge');
    // The whole run maps as it always did: seconds over the run's length, across the width.
    final whole = AxisSpan.of(60, null);
    expect((whole.x(30, 300), whole.timeAt(150, 300), whole.timeAt(400, 300)), (150, 30, 60));
    expect((w.contains(20), w.contains(40), w.contains(19.9), w.contains(40.1)), (true, true, false, false));
  });

  test('a phase is cut to the window, one outside it is left out, and one still going on reaches its end', () {
    final w = AxisSpan.of(100, (20, 40));
    expect(w.band(0, 10), isNull);
    expect(w.band(0, 20), isNull, reason: 'it ended where the window begins');
    expect(w.band(40, 50), isNull, reason: 'it begins where the window ends');
    expect(w.band(10, 30), (20, 30));
    expect(w.band(25, 35), (25, 35));
    expect(w.band(35, 60), (35, 40));
    expect(w.band(0, 100), (20, 40));
    expect(w.band(30, 30, open: true), (30, 40), reason: 'no end yet: it goes on to the window\'s end');
    expect(w.band(5, 5, open: true), (20, 40));
    expect(w.band(30, 30), (30, 30), reason: 'a closed phase of no length stays a mark');
    // The whole run draws every phase as it is, even where it passes the last tick.
    expect(AxisSpan.of(60, null).band(0, 70), (0, 70));
    expect(AxisSpan.of(60, null).band(50, 50, open: true), (50, 50));
  });

  test('spans with the same stretch are equal, so the graphs paint again only when it moves', () {
    expect(AxisSpan.of(100, (20, 40)), AxisSpan.of(50, (20, 40)));
    expect(AxisSpan.of(100, (20, 40)), isNot(AxisSpan.of(100, (20, 41))));
    expect(AxisSpan.of(40, null), isNot(AxisSpan.of(40, (0, 40))), reason: 'a window of the same stretch clips; the whole run does not');
    expect(AxisSpan.of(100, (20, 40)).hashCode, AxisSpan.of(5, (20, 40)).hashCode);
  });
}

void _window() {
  /// The graphs alone on a page, with [window] and [cursor].
  Future<void> pumpGraphs(WidgetTester tester, RunSeries series, {(double, double)? window, ValueNotifier<double?>? cursor, bool running = false}) async {
    tester.view
      ..physicalSize = const Size(1000, 3000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: LiveGraphs(series: series, cursor: cursor ?? ValueNotifier<double?>(null), revision: 1, running: running, window: window),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// The pointer of the test, made the first time it is needed.
  TestGesture? mouse;
  setUp(() => mouse = null);

  /// Puts the pointer on the CPU row's chart, [fraction] of the way across it.
  Future<void> hoverAt(WidgetTester tester, double fraction) async {
    final row = tester.getRect(find.byKey(const Key('graph-row-cpu')));
    var pointer = mouse;
    if (pointer == null) {
      pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: Offset.zero);
      addTearDown(pointer.removePointer);
      mouse = pointer;
    }
    await pointer.moveTo(Offset(row.left + row.width * fraction, row.center.dy + 40));
    await tester.pump();
  }

  testWidgets('without a window the rows say the latest moment, and hovering reads the moment across the whole run', (tester) async {
    await pumpGraphs(tester, _ramp(100));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('100 of 100 %'), findsOneWidget);
    await hoverAt(tester, 0.5);
    expect(find.textContaining('50 of 100 %'), findsOneWidget);
    await hoverAt(tester, 0.25);
    expect(find.textContaining('25 of 100 %'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a window says the moment at its end, and hovering reads the moments inside it only', (tester) async {
    await pumpGraphs(tester, _ramp(100), window: (60, 80));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('80 of 100 %'), findsOneWidget, reason: 'the end of the window, not of the run');
    await hoverAt(tester, 0.5);
    expect(find.textContaining('70 of 100 %'), findsOneWidget);
    await hoverAt(tester, 0.01);
    expect(find.textContaining('60 of 100 %'), findsOneWidget);
    await hoverAt(tester, 0.99);
    expect(find.textContaining('80 of 100 %'), findsOneWidget);
    expect(find.textContaining('50 of 100 %'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a moment pinned from outside is marked in a window only when it lies inside it', (tester) async {
    final cursor = ValueNotifier<double?>(10);
    addTearDown(cursor.dispose);
    await pumpGraphs(tester, _ramp(100), window: (60, 80), cursor: cursor);
    expect(find.textContaining('80 of 100 %'), findsOneWidget, reason: 'second 10 is not in this window');
    expect(find.textContaining('10 of 100 %'), findsNothing);
    cursor.value = 65;
    await tester.pump();
    expect(find.textContaining('65 of 100 %'), findsOneWidget, reason: 'second 65 is');
    // Over the whole run every moment is on the axis.
    cursor.value = 10;
    await pumpGraphs(tester, _ramp(100), cursor: cursor);
    expect(find.textContaining('10 of 100 %'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the opened line says its lowest, average and highest over the window, and over the run without one', (tester) async {
    await pumpGraphs(tester, _ramp(100), window: (60, 80));
    await tester.tap(find.byKey(const Key('graph-row-cpu')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const Key('meter-cpu.load')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Load: lowest 60, average 70, highest 80 %'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The same graphs without the window (the row and the line stay open): the whole run.
    await pumpGraphs(tester, _ramp(100));
    expect(find.text('Load: lowest 0, average 50, highest 100 %'), findsOneWidget);
  });

  testWidgets('a window just begun, one past the last tick, and one of a run still going on draw without an error', (tester) async {
    await pumpGraphs(tester, _ramp(100), window: (100, 100));
    expect(tester.takeException(), isNull);
    await pumpGraphs(tester, _ramp(100), window: (130, 140));
    expect(tester.takeException(), isNull);
    await pumpGraphs(tester, _ramp(100), window: (50, 100), running: true);
    await hoverAt(tester, 0.5);
    expect(find.textContaining('75 of 100 %'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// Scrolls the page until [finder] is inside the window (a widget the list has built is not always on screen).
Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 300, scrollable: find.byType(Scrollable).first);
  for (var i = 0; i < 30 && tester.getCenter(finder).dy > 2700; i++) {
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Scrolls the page back up until [finder], which is above the window, is inside it.
Future<void> showAbove(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30 && tester.getTopLeft(finder).dy < 0; i++) {
    await tester.drag(find.byType(ListView).first, const Offset(0, 500));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _tab() {
  late Directory dir;
  late ChatStore store;
  // every store a test opened (some pump the tab several times): Windows cannot delete the folder while one is open
  final stores = <ChatStore>[];

  /// The tab, with [state] as what the benchmark notifier holds, in a window [width] wide.
  Future<void> pump(WidgetTester tester, BenchmarkState state, {double width = 1300, bool runTab = false}) async {
    tester.view
      ..physicalSize = Size(width, 3000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async => stores.add(store = await ChatStore.open(dir)));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(Storage(dir)),
          chatStoreProvider.overrideWithValue(store),
          backendProvider.overrideWithValue(_Backend()),
          shownModelProvider.overrideWithValue((model: _model, file: _file)),
          shownContextProvider.overrideWithValue((options: const [4096, 65536], value: 65536)),
          benchmarkProvider.overrideWith(() => _Fake(state)),
          engineTabProvider.overrideWith(runTab ? _TabRun.new : _TabBenchmark.new),
        ],
        child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: EnginePage())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  setUp(() => dir = Directory.systemTemp.createTempSync('runmyai-tab-'));
  tearDown(() async {
    for (final s in stores) {
      await s.close();
    }
    stores.clear();
    dir.deleteSync(recursive: true);
  });

  testWidgets('a first look is the setup, the run steps are locked, and history is its own page', (tester) async {
    await pump(tester, const BenchmarkState());
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('benchmark-setup')), findsOneWidget);
    expect(find.text('SETTINGS'), findsNothing, reason: 'the step above is called Setup; the panel has no heading of its own');
    expect(find.byKey(const Key('bench-step-3')), findsNothing, reason: 'a run\'s result is on the live step');
    expect(find.text('Result'), findsNothing);
    expect(find.byKey(const Key('benchmark-start')), findsOneWidget);
    expect(find.text('Close other apps for accurate results.'), findsOneWidget);
    // Detail stays behind a click.
    expect(find.textContaining('--a 1'), findsNothing);
    // The live step is locked, and says why.
    expect(find.text('start a run first'), findsOneWidget);
    // History is a page of its own.
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump();
    expect(find.text('HISTORY'), findsOneWidget);
    expect(find.text('Finished runs are kept here.'), findsOneWidget);
  });

  /// The text on a drop-down's closed face.
  String faceText(WidgetTester tester, String key) =>
      tester.widget<Text>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text))).data!;

  /// Opens the drop-down [box] and lets its list settle.
  Future<void> open(WidgetTester tester, String box) async {
    await tester.tap(find.byKey(Key(box)));
    await tester.pump(const Duration(milliseconds: 250));
  }

  /// Chooses [entry] in the drop-down [box] with the pointer.
  Future<void> choose(WidgetTester tester, String box, String entry) async {
    await open(tester, box);
    await tester.tap(find.byKey(Key('$box-$entry')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));
  }

  /// Whether a drop-down's entry can be chosen.
  bool chosable(WidgetTester tester, String key) => tester.widget<MenuItemButton>(find.byKey(Key(key))).onPressed != null;

  testWidgets('the setup is four choices and one Start: model, context length, KV cache, test', (tester) async {
    await pump(tester, const BenchmarkState());
    final panel = find.byKey(const Key('benchmark-setup'));
    for (final label in ['Model', 'Context length', 'KV cache', 'Test']) {
      expect(find.descendant(of: panel, matching: find.text(label)), findsOneWidget, reason: label);
    }
    expect([for (final k in ['benchmark-model', 'benchmark-context', 'benchmark-kv', 'benchmark-test']) faceText(tester, k)], [
      'Test Model  q',
      '65k',
      'Balanced (Q8_0)',
      'Reply speed',
    ]);
    expect(find.text('Two warm-up messages, then a long story.'), findsOneWidget);
    // Everything else that was on the setup is gone.
    for (final key in [
      'benchmark-test-mode',
      'benchmark-prompt-story',
      'benchmark-prompt-32k',
      'benchmark-custom-text',
      'benchmark-reply-length',
      'benchmark-warmups',
      'benchmark-test-flags',
      'benchmark-test-cap',
      'benchmark-copy-flags',
      'benchmark-thinking',
      'thinking-toggle',
      'benchmark-context-65536-pill',
    ]) {
      expect(find.byKey(Key(key)), findsNothing, reason: key);
    }
    expect(find.descendant(of: panel, matching: find.byType(TextField)), findsNothing);
    expect(find.descendant(of: panel, matching: find.byType(OptionPill)), findsNothing);
    expect(find.descendant(of: panel, matching: find.byType(Fold)), findsNothing);
    final words = [for (final t in tester.widgetList<Text>(find.descendant(of: panel, matching: find.byType(Text)))) (t.data ?? '').toLowerCase()];
    expect(words.where((w) => w.contains('profile') || w.contains('flags') || w.trim() == 'test mode'), isEmpty);
    // One button: Start.
    expect(find.descendant(of: panel, matching: find.byType(MainButton)), findsOneWidget);
    expect(find.descendant(of: panel, matching: find.byType(AppButton)), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the rows are tidy: labels at one edge, drop-downs of one width at another, the line below, the footer under a divider', (tester) async {
    await pump(tester, const BenchmarkState());
    final labels = [for (final l in ['Model', 'Context length', 'KV cache', 'Test']) tester.getTopLeft(find.text(l))];
    expect(labels.map((o) => o.dx).toSet(), hasLength(1), reason: 'all labels on one left edge');
    final boxes = [for (final k in ['benchmark-model', 'benchmark-context', 'benchmark-kv', 'benchmark-test']) tester.getRect(find.byKey(Key(k)))];
    expect(boxes.map((r) => r.left).toSet(), hasLength(1), reason: 'all drop-downs start at one edge');
    expect(boxes.map((r) => r.width).toSet(), hasLength(1), reason: 'all drop-downs are as wide as each other');
    expect(boxes.first.left, greaterThan(labels.first.dx + 100), reason: 'the labels have a column of their own');
    expect(boxes.map((r) => r.height).toSet(), {SelectBox.height});
    final line = tester.getRect(find.byKey(const Key('benchmark-test-line')));
    expect(line.top, greaterThan(boxes.last.bottom), reason: 'the line is under the rows');
    final status = tester.getRect(find.byKey(const Key('benchmark-status')));
    final start = tester.getRect(find.byKey(const Key('benchmark-start')));
    expect(status.top, greaterThan(line.bottom + 10), reason: 'the footer is under the line, with the divider between');
    expect(status.left, lessThan(start.left), reason: 'the status on the left, Start on the right');
    expect(start.right, closeTo(tester.getRect(find.byKey(const Key('benchmark-setup'))).right - 16, 1));
    expect(find.text('Context length'), findsOneWidget);
  });

  testWidgets('a drop-down is as high as the app\'s text boxes', (tester) async {
    await pump(tester, const BenchmarkState(), runTab: true);
    expect(tester.getSize(find.byKey(const Key('memory-cap'))).height, closeTo(SelectBox.height, 0.5));
  });

  testWidgets('the setup\'s rows, list and footer do not overflow in a narrow window', (tester) async {
    // (The stepper above the setup is not part of it: it is the page's own, and overflows at the narrowest widths.)
    final problems = <String>[];
    final original = FlutterError.onError;
    FlutterError.onError = (details) => problems.add(details.toString(minLevel: DiagnosticLevel.debug));
    addTearDown(() => FlutterError.onError = original);
    for (final width in [700.0, 500.0, 380.0]) {
      await pump(tester, const BenchmarkState(), width: width);
      await open(tester, 'benchmark-test');
      expect(find.byKey(const Key('benchmark-test-prompt-8k')), findsOneWidget, reason: '$width');
      await tester.pumpWidget(const SizedBox());
    }
    FlutterError.onError = original;
    expect(problems.where((p) => p.contains('_BenchmarkSettings') || p.contains('SelectBox')), isEmpty, reason: problems.join('\n'));
  });

  testWidgets('the context length lists the preset\'s lengths, and 100k and 200k greyed in their place', (tester) async {
    await pump(tester, const BenchmarkState());
    await open(tester, 'benchmark-context');
    final entries = ['4096', '65536', '100000', '200000'];
    final tops = [for (final e in entries) tester.getTopLeft(find.byKey(Key('benchmark-context-$e'))).dy];
    expect(tops, [...tops]..sort(), reason: 'in their numeric place');
    expect([for (final e in entries) chosable(tester, 'benchmark-context-$e')], [true, true, false, false]);
    expect(find.descendant(of: find.byType(MenuItemButton), matching: find.text('100k')), findsOneWidget);
    expect(find.descendant(of: find.byType(MenuItemButton), matching: find.text('200k')), findsOneWidget);
    // (Greyed: a click does nothing, and the list stays open.)
    await tester.tap(find.byKey(const Key('benchmark-context-100000')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(faceText(tester, 'benchmark-context'), '65k');
    expect(find.byKey(const Key('benchmark-context-4096')), findsOneWidget);
    await tester.tap(find.byKey(const Key('benchmark-context-4096')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));
    expect(faceText(tester, 'benchmark-context'), '4k');
    expect(find.byKey(const Key('benchmark-context-4096')), findsNothing, reason: 'the list closed');
    expect(Storage(dir).readBenchmarkSetup()!['contextLength'], 4096, reason: 'kept for next time');
  });

  testWidgets('a prompt test that does not fit the context length is greyed, with the reason', (tester) async {
    await pump(tester, const BenchmarkState(setup: BenchmarkSetup(contextLength: 4096)));
    await open(tester, 'benchmark-test');
    expect([for (final t in BenchmarkTest.all) chosable(tester, 'benchmark-test-${t.id}')], [true, false, false, false, false]);
    expect(find.text('Needs a longer context'), findsNWidgets(4));
    await tester.tap(find.byKey(const Key('benchmark-test-prompt-8k')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(faceText(tester, 'benchmark-test'), 'Reply speed', reason: 'a greyed test cannot be chosen');
    // A longer context, and the tests that fit are open.
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 250));
    await choose(tester, 'benchmark-context', '65536');
    await open(tester, 'benchmark-test');
    expect([for (final t in BenchmarkTest.all) chosable(tester, 'benchmark-test-${t.id}')], [true, true, true, true, false]);
    expect(find.text('Needs a longer context'), findsOneWidget);
    await tester.tap(find.byKey(const Key('benchmark-test-prompt-25k')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));
    expect(faceText(tester, 'benchmark-test'), 'Prompt 25k');
    expect(find.text('Two warm-up messages, then a story of 25k tokens and a short review.'), findsOneWidget);
    expect(find.text('Two warm-up messages, then a long story.'), findsNothing);
    expect(Storage(dir).readBenchmarkSetup()!['test'], 'prompt-25k');
  });

  testWidgets('a chosen test that no longer fits shows why nothing can start, in the danger colour, and Start waits', (tester) async {
    await pump(tester, BenchmarkState(setup: BenchmarkSetup(contextLength: 4096, test: BenchmarkTest.prompts[1])));
    final status = find.byKey(const Key('benchmark-status'));
    expect(tester.widget<Text>(status).data, 'Prompt 25k needs a longer context length.');
    expect(tester.widget<Text>(status).style!.color, buildTheme(Brightness.dark).extension<AppColors>()!.danger);
    expect(tester.widget<MainButton>(find.byKey(const Key('benchmark-start'))).onTap, isNull);
    expect(find.text('Close other apps for accurate results.'), findsNothing);
    // The test that fits brings Start back.
    await choose(tester, 'benchmark-test', 'reply');
    expect(tester.widget<Text>(status).data, 'Close other apps for accurate results.');
    expect(tester.widget<MainButton>(find.byKey(const Key('benchmark-start'))).onTap, isNotNull);
  });

  testWidgets('the KV cache has the Run page\'s three types; a choice is kept and shown', (tester) async {
    await pump(tester, const BenchmarkState());
    await open(tester, 'benchmark-kv');
    for (final (id, label) in [('q4_0', 'Efficient (Q4_0)'), ('q8_0', 'Balanced (Q8_0)'), ('fp16', 'Full Quality (FP16)')]) {
      expect(find.descendant(of: find.byKey(Key('benchmark-kv-$id')), matching: find.text(label)), findsOneWidget, reason: id);
      expect(chosable(tester, 'benchmark-kv-$id'), isTrue);
    }
    await tester.tap(find.byKey(const Key('benchmark-kv-q4_0')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));
    expect(faceText(tester, 'benchmark-kv'), 'Efficient (Q4_0)');
    expect(Storage(dir).readBenchmarkSetup()!['kvCache'], 'q4_0');
    // Nothing else moves: the test, the context length and Start stay as they were.
    expect((faceText(tester, 'benchmark-context'), faceText(tester, 'benchmark-test')), ('65k', 'Reply speed'));
    expect(tester.widget<MainButton>(find.byKey(const Key('benchmark-start'))).onTap, isNotNull);
  });

  testWidgets('a drop-down works with the keyboard: Tab to it, Enter opens, arrows move, Enter chooses, Escape closes', (tester) async {
    await pump(tester, const BenchmarkState());
    bool focused(String key) {
      final node = FocusManager.instance.primaryFocus?.context;
      var inside = false;
      node?.visitAncestorElements((e) {
        if (e.widget.key == Key(key)) inside = true;
        return !inside;
      });
      return inside;
    }

    for (var i = 0; i < 40 && !focused('benchmark-kv'); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(focused('benchmark-kv'), isTrue, reason: 'Tab reaches the KV cache box');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('benchmark-kv-q4_0')), findsOneWidget, reason: 'Enter opens the list');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('benchmark-kv-q4_0')), findsNothing, reason: 'Enter chooses and closes');
    expect(faceText(tester, 'benchmark-kv'), 'Full Quality (FP16)', reason: 'the list opens on the chosen entry; Down moves to the next');
    expect(focused('benchmark-kv'), isTrue, reason: 'the focus is back on the box');
    // Escape closes an open list without choosing.
    final chosen = faceText(tester, 'benchmark-kv');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('benchmark-kv-q4_0')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('benchmark-kv-q4_0')), findsNothing);
    expect(faceText(tester, 'benchmark-kv'), chosen);
    expect(focused('benchmark-kv'), isTrue, reason: 'Escape leaves the focus on the box');
  });

  testWidgets('a setup saved by the version before opens on the defaults, with its context length kept', (tester) async {
    Storage(dir).writeBenchmarkSetup(const {
      'profileId': 'test',
      'contextLength': 4096,
      'promptId': '16k',
      'customText': 'my own text',
      'replyLength': 512,
      'warmups': ['one', 'two'],
      'testFlags': '-c 4096 --something 1',
      'testMemoryCapGiB': 12.5,
    });
    // (The notifier of a real app reads the saved setup; the tab is given what it makes of it.)
    await pump(tester, BenchmarkState(setup: BenchmarkSetup.fromJson(Storage(dir).readBenchmarkSetup()!)));
    expect(tester.takeException(), isNull);
    expect([for (final k in ['benchmark-context', 'benchmark-kv', 'benchmark-test']) faceText(tester, k)], ['4k', 'Balanced (Q8_0)', 'Reply speed']);
    expect(tester.widget<MainButton>(find.byKey(const Key('benchmark-start'))).onTap, isNotNull);
  });

  testWidgets('the live cards: modular hardware cards show meters and limits', (tester) async {
    final series = _series(60);
    await pump(tester, BenchmarkState(live: series, revision: 5, counters: EngineCounters.available, hardware: const HardwareInfo(gpus: ['Test GPU'])));
    expect(tester.takeException(), isNull);
    // The cards are on the live step.
    await tester.tap(find.byKey(const Key('bench-step-2')));
    await tester.pump();
    expect(find.text('Press Start. The graphs fill in while the run goes on.'), findsOneWidget);
    expect(find.byKey(const Key('card-gpu.0')), findsOneWidget);
    expect(find.textContaining('of 140 W'), findsWidgets);

    expect(find.byKey(const Key('meter-gpu.0.power')), findsOneWidget);
    expect(find.byKey(const Key('meter-gpu.0.pcieRx')), findsOneWidget);
    expect(find.byKey(const Key('card-cpu')), findsOneWidget);
    expect(find.byKey(const Key('meter-cpu.load')), findsOneWidget);
    expect(find.byKey(const Key('card-ram')), findsOneWidget);
    expect(find.byKey(const Key('meter-ram.used')), findsOneWidget);
    expect(find.byKey(const Key('card-ssd')), findsOneWidget);
    expect(find.byKey(const Key('card-engine')), findsOneWidget);
    expect(find.byKey(const Key('meter-eng.gInTime')), findsOneWidget);
  });

  testWidgets('a row says so when the machine or the engine gives nothing', (tester) async {
    final bare = RunSeries();
    for (var t = 0.0; t < 5; t += 0.5) {
      bare.add(t, {'cpu.load': 10, 'ram.total': 30, 'ram.used': 10});
    }
    await pump(tester, BenchmarkState(live: bare, revision: 1, counters: EngineCounters.missing));
    await tester.tap(find.byKey(const Key('bench-step-2')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('no graphics card could be read'), findsOneWidget);
    expect(find.textContaining('does not report its counters'), findsOneWidget);
  });

  testWidgets('a run that has ended is on Live, on the whole run, with the folds of the run under it', (tester) async {
    final shown = _result(id: 2, turns: _turns());
    final earlier = _result(id: 1, speed: 36, flags: '-c 65536 --a 2 --temp 0 --extra 1');
    await pump(
      tester,
      BenchmarkState(setup: const BenchmarkSetup(), result: shown, live: shown.series, revision: 5, turns: shown.turns, history: [shown, earlier], disturbed: shown.disturbed),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.text('FULL RESULT'), findsNothing);
    expect(find.byKey(const Key('bench-step-3')), findsNothing);
    expect(find.byKey(const Key('scrubber-overall')), findsOneWidget);
    expect(find.byKey(const Key('card-gpu.0')), findsOneWidget);

    // The folds of the run, each closed until clicked.
    for (final title in [
      'The run',
      'Memory layout',
      'Hardware over the run',
    ]) {
      final fold = find.byKey(Key('fold-$title')).first;
      await reveal(tester, fold);
      await tester.tap(fold);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull, reason: title);
    }
    expect(find.textContaining('191 slots per layer'), findsOneWidget);

    // Removed / hidden folds are not rendered.
    for (final title in ['Phases', 'Sanity: the reply and why it ended', 'Setup record', 'Compare with another run', 'Engine output']) {
      expect(find.byKey(Key('fold-$title')), findsNothing, reason: title);
    }
  });

  testWidgets('the folds closed under the whole run keep clean titles', (tester) async {
    final shown = _result(turns: _turns());
    await pump(tester, BenchmarkState(setup: const BenchmarkSetup(), result: shown, live: shown.series, turns: shown.turns, history: [shown]));
    expect(find.byKey(const Key('fold-The run')), findsOneWidget);
    expect(find.byKey(const Key('fold-Memory layout')), findsOneWidget);
    expect(find.byKey(const Key('fold-Hardware over the run')), findsOneWidget);
  });

  testWidgets('a run in the history is a row; a click opens its result with the graphs it was made with; delete asks twice', (tester) async {
    final run = _result(id: 7);
    await pump(tester, BenchmarkState(history: [run]));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump();
    expect(find.text('FULL RESULT'), findsNothing);
    expect(find.textContaining('Test Model  ·  Auto  ·  65k  ·  Story chat'), findsOneWidget);
    expect(find.textContaining('Disturbed'), findsNothing, reason: 'the run was disturbed, and no row says so');
    expect(find.text('40.0 tokens/s'), findsOneWidget);

    await tester.tap(find.byKey(const Key('history-7')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('graph-row-gpu.0')), findsOneWidget, reason: 'the stored graphs');
    expect(find.byKey(const Key('result-reply-speed')), findsOneWidget);
    // The whole result of a saved run: the memory layout and hardware folds are present.
    for (final title in ['Memory layout', 'Hardware over the run']) {
      expect(find.byKey(Key('fold-$title')), findsOneWidget, reason: title);
    }
    expect(find.textContaining('Disturbed'), findsNothing);

    await tester.tap(find.byKey(const Key('history-delete-7')));
    await tester.pump();
    expect(find.text('Delete this run'), findsOneWidget, reason: 'one click only asks');
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Delete this run'), findsNothing, reason: 'and the question goes away by itself');
  });

  testWidgets('History toggles back to the view that was on screen: the live step after a run, the setup', (tester) async {
    final shown = _result();
    await pump(tester, BenchmarkState(result: shown, live: shown.series, history: [shown]));
    expect(find.text('LIVE'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump();
    expect(find.text('HISTORY'), findsOneWidget);
    expect(find.text('LIVE'), findsNothing);
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.text('HISTORY'), findsNothing);

    // From the setup step it goes back to the setup step.
    await tester.tap(find.byKey(const Key('bench-step-1')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('benchmark-setup')), findsOneWidget);
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump();
    expect(find.text('HISTORY'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('benchmark-setup')), findsOneWidget);
    expect(find.text('HISTORY'), findsNothing);

    // A step picked inside History is the way back the next time.
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bench-step-2')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('LIVE'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('LIVE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('History toggles back to the setup when nothing has run', (tester) async {
    await pump(tester, const BenchmarkState());
    expect(find.byKey(const Key('benchmark-setup')), findsOneWidget);
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump();
    expect(find.text('HISTORY'), findsOneWidget);
    expect(find.byKey(const Key('benchmark-setup')), findsNothing);
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump();
    expect(find.byKey(const Key('benchmark-setup')), findsOneWidget);
    expect(find.text('HISTORY'), findsNothing);
  });

  testWidgets('after a run finishes: scrubber is at top with Overall selected, flat run facts show under cards', (tester) async {
    final shown = _result(turns: _turns());
    await pump(
      tester,
      BenchmarkState(setup: const BenchmarkSetup(), result: shown, live: shown.series, revision: 5, turns: shown.turns, history: [shown]),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('scrubber-overall')), findsOneWidget);
    expect(find.byKey(const Key('card-speed')), findsOneWidget);
    expect(find.textContaining('not counted'), findsNothing);

    // Speed card shows overall numbers and latency percentiles (Turn 3)
    expect(find.text('40.0 tokens/s'), findsOneWidget);
    expect(find.text('417 tokens/s'), findsOneWidget);
    expect(find.text('1.70 s'), findsOneWidget);
    expect(find.textContaining('p50:'), findsOneWidget);
    expect(find.textContaining('p90:'), findsOneWidget);
    expect(find.textContaining('p99:'), findsOneWidget);

    // The run fold under cards
    final runFold = find.byKey(const Key('fold-The run'));
    expect(runFold, findsOneWidget);
    await reveal(tester, runFold);
    await tester.tap(runFold);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Cache hits'), findsOneWidget);
    expect(find.text('Misses'), findsOneWidget);
    expect(find.text('SSD wait'), findsWidgets);
    expect(find.text('Correct guesses'), findsOneWidget);
    expect(find.text('Wrong guesses'), findsOneWidget);
  });

  testWidgets('during a run the live header transitions in-place: Warm-up 1 -> Warm-up 2 -> Benchmark Run', (tester) async {
    final turns = _turns();
    const setup = BenchmarkSetup();
    final live = _series(60);
    await pump(tester, BenchmarkState(phase: BenchmarkPhase.warmingUp, setup: setup, live: live, revision: 5));
    final fake = ProviderScope.containerOf(tester.element(find.byType(EnginePage))).read(benchmarkProvider.notifier) as _Fake;

    // The first turn is going on: header says Warm-up 1.
    expect(tester.takeException(), isNull);
    expect(find.text('Warm-up 1'), findsOneWidget);

    // The first turn ends and the second goes on: header transitions in-place to Warm-up 2.
    fake.put(BenchmarkState(phase: BenchmarkPhase.warmingUp, warmup: 1, setup: setup, live: live, revision: 6, turns: turns.sublist(0, 1)));
    await tester.pump();
    expect(find.text('Warm-up 2'), findsOneWidget);
    expect(find.text('Warm-up 1'), findsNothing);

    // The measured turn goes on: header transitions in-place to Benchmark Run.
    fake.put(BenchmarkState(phase: BenchmarkPhase.measuring, setup: setup, live: live, revision: 7, turns: turns.sublist(0, 2), replyTokens: 12));
    await tester.pump();
    expect(find.text('Benchmark Run'), findsOneWidget);
    expect(find.text('Writing reply: 12 tokens…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('token scrubber allows stepping, input, picking tokens, and returning to Overall', (tester) async {
    final turns = _turns();
    final shown = _result(turns: turns);
    await pump(
      tester,
      BenchmarkState(setup: const BenchmarkSetup(), result: shown, live: shown.series, revision: 5, turns: turns, history: [shown]),
    );
    expect(tester.takeException(), isNull);

    // Starts in Overall mode
    expect(find.byKey(const Key('scrubber-overall')), findsOneWidget);
    expect(find.byKey(const Key('scrubber-next')), findsOneWidget);

    // Step to first token using [▶]
    await tester.tap(find.byKey(const Key('scrubber-next')));
    await tester.pump();
    expect(find.textContaining('Token'), findsWidgets);
    expect(find.byKey(const Key('scrubber-input')), findsOneWidget);

    // Step further using [▶]
    await tester.tap(find.byKey(const Key('scrubber-next')));
    await tester.pump();

    // Step back using [◀]
    await tester.tap(find.byKey(const Key('scrubber-prev')));
    await tester.pump();

    // Click [ Overall ] to snap back
    await tester.tap(find.byKey(const Key('scrubber-overall')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('picking a token in the scrubber updates speed card to show token duration', (tester) async {
    final turns = _turns();
    final shown = _result(turns: turns);
    await pump(
      tester,
      BenchmarkState(setup: const BenchmarkSetup(), result: shown, live: shown.series, revision: 5, turns: turns, history: [shown]),
    );

    // In Overall mode: Speed card shows Turn 3 40.0 tokens/s
    expect(find.text('40.0 tokens/s'), findsOneWidget);

    // Step to token 0
    await tester.tap(find.byKey(const Key('scrubber-next')));
    await tester.pump();

    // Speed card reflects the specific token
    expect(find.descendant(of: find.byKey(const Key('card-speed')), matching: find.text('50.0 tokens/s (20.0 ms)')), findsOneWidget);

    // Snap back to Overall
    await tester.tap(find.byKey(const Key('scrubber-overall')));
    await tester.pump();
    expect(find.text('40.0 tokens/s'), findsOneWidget);
  });

  testWidgets('a run without times or a run that is loading renders cards cleanly', (tester) async {
    final shown = _result(turns: _turns());
    await pump(
      tester,
      BenchmarkState(setup: const BenchmarkSetup(), result: shown, live: shown.series, revision: 5, turns: shown.turns, history: [shown]),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('card-speed')), findsOneWidget);

    // Stopped before any turn ended, and loading
    await pump(tester, BenchmarkState(live: _series(20), revision: 3));
    await tester.tap(find.byKey(const Key('bench-step-2')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('card-gpu.0')), findsOneWidget);

    final fake = ProviderScope.containerOf(tester.element(find.byType(EnginePage))).read(benchmarkProvider.notifier) as _Fake;
    fake.put(BenchmarkState(phase: BenchmarkPhase.loading, setup: const BenchmarkSetup(), live: _series(20), revision: 4));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('during a run the live header shows progress and cards render live series', (tester) async {
    final turns = _turns();
    const setup = BenchmarkSetup();
    await pump(tester, BenchmarkState(phase: BenchmarkPhase.warmingUp, setup: setup, live: _series(15), revision: 5));
    final fake = ProviderScope.containerOf(tester.element(find.byType(EnginePage))).read(benchmarkProvider.notifier) as _Fake;

    expect(find.text('Warm-up 1'), findsOneWidget);
    expect(find.byKey(const Key('card-gpu.0')), findsOneWidget);

    // PCIe inbound during running shows clean live rate, never "of <limit>" or "avg ... of ..."
    expect(find.descendant(of: find.byKey(const Key('meter-gpu.0.pcieRx')), matching: find.textContaining('of 7 880')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('meter-gpu.0.pcieRx')), matching: find.textContaining('avg ')), findsNothing);

    fake.put(BenchmarkState(phase: BenchmarkPhase.warmingUp, warmup: 1, setup: setup, live: _series(18.5), revision: 7, turns: turns.sublist(0, 1)));
    await tester.pump();
    expect(find.text('Warm-up 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the whole run overall view shows speed card with latency percentiles and The run fold', (tester) async {
    final shown = _result(turns: _turns());
    await pump(tester, BenchmarkState(setup: const BenchmarkSetup(), result: shown, live: shown.series, revision: 5, turns: shown.turns, history: [shown]));
    expect(tester.takeException(), isNull);

    // Speed card: generation speed, prompt processing, TTFT (Turn 3 exclusive)
    expect(find.text('40.0 tokens/s'), findsOneWidget);
    expect(find.text('417 tokens/s'), findsOneWidget);
    expect(find.text('1.70 s'), findsOneWidget);

    // PCIe inbound in overall view shows average and peak, but never "of <limit>" in the card
    expect(find.descendant(of: find.byKey(const Key('meter-gpu.0.pcieRx')), matching: find.textContaining('of 7 880')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('meter-gpu.0.pcieRx')), matching: find.textContaining('avg ')), findsOneWidget);

    // Where the time per token went (Turn 3 only)
    expect(find.text('Where the time per token went'), findsOneWidget);

    // The run fold
    final runFold = find.byKey(const Key('fold-The run'));
    expect(runFold, findsOneWidget);
    await reveal(tester, runFold);
    await tester.tap(runFold);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('12.0 s'), findsOneWidget);
    expect(find.text('Cache hits'), findsOneWidget);
    expect(find.text('Misses'), findsOneWidget);
    expect(find.text('SSD wait'), findsWidgets);
    expect(find.text('Correct guesses'), findsOneWidget);
  });

  testWidgets('when a run ends the page stays on Live and selects Overall; a stopped run goes back to setup', (tester) async {
    final turns = _turns();
    const setup = BenchmarkSetup();
    await pump(tester, BenchmarkState(phase: BenchmarkPhase.measuring, warmup: 1, setup: setup, live: _series(60), revision: 5, turns: turns.sublist(0, 2)));
    final fake = ProviderScope.containerOf(tester.element(find.byType(EnginePage))).read(benchmarkProvider.notifier) as _Fake;

    expect(find.text('LIVE'), findsOneWidget);

    // The run ends with its result: the page stays on Live and Overall is selected.
    final shown = _result(turns: turns);
    fake.put(BenchmarkState(setup: setup, result: shown, live: shown.series, revision: 6, turns: turns, history: [shown]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.byKey(const Key('scrubber-overall')), findsOneWidget);

    // A run that was stopped has no result: the page goes to setup.
    fake.put(BenchmarkState(phase: BenchmarkPhase.warmingUp, setup: setup, live: _series(9), revision: 8, turns: turns.sublist(0, 1)));
    await tester.pump();
    fake.put(BenchmarkState(setup: setup, live: _series(9), revision: 9, turns: turns.sublist(0, 1), note: 'Stopped. Nothing was saved.'));
    await tester.pump();
    expect(find.byKey(const Key('benchmark-setup')), findsOneWidget);
    expect(find.text('LIVE'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a saved run opens in the history with a fold for each turn, for the streaming numbers and for each layer', (tester) async {
    final run = _result(id: 4, turns: _turns());
    await pump(tester, BenchmarkState(history: [run]));
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('history-4')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('The turns: each with its own numbers, the warm-ups not counted'), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    // One fold per turn, named by what the turn was, closed until clicked.
    const titles = ['Turn 1: warm-up, not counted', 'Turn 2: warm-up, not counted', 'Turn 3: measured'];
    for (final title in titles) {
      expect(find.byKey(Key('fold-$title')), findsOneWidget, reason: title);
    }
    expect(find.text('4.20 s to the first token'), findsNothing);
    for (final (title, ttft) in [(titles[0], '4.20 s to the first token'), (titles[2], '1.70 s to the first token')]) {
      final fold = find.byKey(Key('fold-$title'));
      await reveal(tester, fold);
      await tester.tap(fold);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(ttft), findsOneWidget, reason: title);
    }
    expect(find.text('2.60 s to the first token'), findsNothing, reason: 'turn 2 stayed closed');
    expect(find.text('8.00 ms/token'), findsNWidgets(2), reason: 'the table\'s and the fold\'s SSD wait of turn 1');
    for (final title in ['Streaming from the SSD', 'Each layer']) {
      final fold = find.byKey(Key('fold-$title'));
      await reveal(tester, fold);
      await tester.tap(fold);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull, reason: title);
    }
    expect(find.textContaining('Found in memory'), findsWidgets);
  });

  testWidgets('no disturbance message is shown on the page: not while a run goes on, not after it, not in the history', (tester) async {
    final run = _result(id: 3, turns: _turns());
    expect(run.disturbed, isNotEmpty, reason: 'the run was disturbed, and the saved data says so');
    const setup = BenchmarkSetup();
    await pump(
      tester,
      BenchmarkState(phase: BenchmarkPhase.measuring, setup: setup, live: _series(60), revision: 5, turns: run.turns.sublist(0, 2), disturbed: run.disturbed),
    );
    final fake = ProviderScope.containerOf(tester.element(find.byType(EnginePage))).read(benchmarkProvider.notifier) as _Fake;
    void none() {
      expect(find.textContaining('Disturbed'), findsNothing);
      expect(find.textContaining('The computer was on battery.'), findsNothing);
      expect(find.byKey(const Key('benchmark-disturbed')), findsNothing);
    }

    none();
    fake.put(BenchmarkState(setup: setup, result: run, live: run.series, revision: 6, turns: run.turns, history: [run], disturbed: run.disturbed));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('LIVE'), findsOneWidget);
    none();
    final mem = find.byKey(const Key('fold-Memory layout'));
    await reveal(tester, mem);
    await tester.tap(mem);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Video Memory (VRAM)'), findsOneWidget);
    none();

    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump();
    expect(find.text('HISTORY'), findsOneWidget);
    none();
    await tester.tap(find.byKey(const Key('history-3')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('result-reply-speed')), findsOneWidget);
    none();
    final saved = find.byKey(const Key('fold-Memory layout'));
    await reveal(tester, saved);
    await tester.tap(saved);
    await tester.pump(const Duration(milliseconds: 200));
    none();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a run saved before the turns existed opens in the history with no turns table and no turn folds', (tester) async {
    final run = _result(id: 5);
    await pump(tester, BenchmarkState(history: [run]));
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('history-5')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('result-reply-speed')), findsOneWidget);
    expect(find.byType(Table), findsNothing);
    expect(find.textContaining('The turns:'), findsNothing);
    expect(find.textContaining('Turn 1:'), findsNothing);
    expect(find.byKey(const Key('fold-Memory layout')), findsOneWidget, reason: 'the rest of the result is there');
  });

  testWidgets('the cards, scrubber, facts and folds fit a narrow window without overflow', (tester) async {
    final turns = _timed(_turns(), const [(12, 18), (18, 24), (24, 60)]);
    final shown = _result(turns: turns);
    await pump(
      tester,
      BenchmarkState(setup: const BenchmarkSetup(), result: shown, live: shown.series, turns: turns, history: [shown]),
      width: 700,
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('scrubber-overall')), findsOneWidget);
    expect(find.byKey(const Key('card-speed')), findsOneWidget);
    expect(find.byKey(const Key('card-gpu.0')), findsOneWidget);

    for (final title in ['The run', 'Memory layout', 'Hardware over the run']) {
      final fold = find.byKey(Key('fold-$title'));
      await reveal(tester, fold);
      await tester.tap(fold);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull, reason: title);
    }
    expect(tester.takeException(), isNull);
  });
}

