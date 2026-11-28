// The Benchmark tab as widgets, with made-up numbers: every part draws without an error at a desktop width and at a
// narrow one; the live cards (one per row, bars against the limits the PC reports, the speed of the phase); a run that
// ends stays on Live with its result, the same result a history row opens (the chosen tests' numbers only); no
// disturbance message is shown; and the setup (three drop-downs and the tests, a line on what they do, Start; a test that
// does not fit the context is greyed; a saved setup of an older version opens). No engine runs and no machine is read.
// Run: flutter test test/benchmark_tab_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/benchmark/benchmark.dart';
import 'package:runmyai/benchmark/hardware.dart';
import 'package:runmyai/benchmark/memory_layout.dart';
import 'package:runmyai/benchmark/metrics.dart';
import 'package:runmyai/benchmark/series.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/benchmark.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/benchmark/fold.dart';
import 'package:runmyai/ui/benchmark/result_view.dart';
import 'package:runmyai/ui/buttons.dart';
import 'package:runmyai/ui/context_settings.dart';
import 'package:runmyai/ui/pages/engine_page.dart';
import 'package:runmyai/ui/select_box.dart';

const _file = ModelFile(id: 'm/f', quantization: 'q', sizeBytes: 1);
const _model = CatalogModel(
  id: 'm',
  name: 'Test Model',
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
      'gpu.0.powerTop': 140,
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

BenchmarkResult _result({
  int id = 1,
  double speed = 40,
  RunSeries? series,
  String flags = '-c 65536 --a 1 --temp 0',
  List<TurnRecord> turns = const [],
  String label = 'Story chat',
  List<TestResult> tests = const [],
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
    promptLabel: label,
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
    tests: tests,
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

/// A run of several tests ([tests] by id, in the order they ran): the reply speed's turn is the third of [_turns] (40
/// tokens/s, its time split [parts]); prompt 8k reads at 2000 tokens/s, prompt 25k at 1250.
BenchmarkResult _multi({
  int id = 1,
  List<String> tests = const ['reply', 'prompt-8k', 'prompt-25k'],
  Map<String, double> parts = const {'SSD wait': 5.4, 'CPU': 10.0, 'GPU': 9.0, 'CPU-GPU sync': 4.0, 'Other': 1.0},
}) {
  TurnRecord prompt(int tokens, double millis, int ttft) => TurnRecord(
    warmup: false,
    firstTokenMillis: ttft,
    promptTokens: tokens,
    promptMillis: millis,
    replyTokens: 60,
    replyMillis: 1500,
    totalMillis: ttft + 1500,
  );
  final turn = TurnRecord(
    warmup: false,
    firstTokenMillis: 1700,
    promptTokens: 40,
    promptMillis: 100,
    replyTokens: 300,
    replyMillis: 7500,
    totalMillis: 9300,
    tokenMillis: const [20, 21, 22, 70],
  );
  final all = {
    'reply': TestResult(testId: 'reply', label: 'Reply speed', turn: turn, timeParts: parts),
    'prompt-8k': TestResult(testId: 'prompt-8k', label: 'Prompt 8k', turn: prompt(8000, 4000, 4100)),
    'prompt-25k': TestResult(testId: 'prompt-25k', label: 'Prompt 25k', turn: prompt(25000, 20000, 20200)),
  };
  final chosen = [for (final t in tests) all[t]!];
  return _result(id: id, label: chosen.map((t) => t.label).join(' + '), tests: chosen, turns: [..._turns().take(2), for (final t in chosen) t.turn]);
}

void main() {
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
  Future<void> pump(WidgetTester tester, BenchmarkState state, {double width = 1300}) async {
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

  testWidgets('the setup is four choices and one Start: model, context length, KV cache, tests', (tester) async {
    await pump(tester, const BenchmarkState());
    final panel = find.byKey(const Key('benchmark-setup'));
    for (final label in ['Model', 'Context length', 'KV cache', 'Tests']) {
      expect(find.descendant(of: panel, matching: find.text(label)), findsOneWidget, reason: label);
    }
    expect([for (final k in ['benchmark-model', 'benchmark-context', 'benchmark-kv', 'benchmark-test']) faceText(tester, k)], [
      'Test Model  q',
      '65k',
      'Balanced (Q8_0)',
      'Reply speed, Prompt 25k',
    ]);
    expect(
      find.text('Two warm-up messages, then a long story; a story of 25k tokens and a short review. Each test starts from right after the warm-ups.'),
      findsOneWidget,
    );
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
    final labels = [for (final l in ['Model', 'Context length', 'KV cache', 'Tests']) tester.getTopLeft(find.text(l))];
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
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storageProvider.overrideWithValue(Storage(dir)), backendProvider.overrideWithValue(_Backend())],
        child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: VramHeadroomInput(card: 'CUDA0'))),
      ),
    );
    expect(tester.getSize(find.byKey(const Key('vram-headroom-CUDA0'))).height, closeTo(SelectBox.height, 0.5));
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

  testWidgets('the context length lists the preset\'s lengths, each one to be chosen', (tester) async {
    await pump(tester, const BenchmarkState());
    await open(tester, 'benchmark-context');
    final entries = ['4096', '65536'];
    expect([for (final e in entries) chosable(tester, 'benchmark-context-$e')], [true, true]);
    expect(find.byKey(const Key('benchmark-context-100000')), findsNothing, reason: 'not a length of this model');
    await tester.tap(find.byKey(const Key('benchmark-context-4096')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));
    expect(faceText(tester, 'benchmark-context'), '4k');
    expect(find.byKey(const Key('benchmark-context-4096')), findsNothing, reason: 'the list closed');
    expect(Storage(dir).readBenchmarkSetup()!['contextLength'], 4096, reason: 'kept for next time');
  });

  testWidgets('several tests are chosen in one list; one that does not fit the context length is greyed, with the reason', (tester) async {
    await pump(tester, const BenchmarkState(setup: BenchmarkSetup(contextLength: 4096)));
    await open(tester, 'benchmark-test');
    expect([for (final t in BenchmarkTest.all) chosable(tester, 'benchmark-test-${t.id}')], [true, false, false, false, false]);
    expect(find.text('Needs a longer context'), findsNWidgets(4));
    await tester.tap(find.byKey(const Key('benchmark-test-prompt-8k')));
    await tester.pump(const Duration(milliseconds: 250));
    // A greyed test cannot be chosen, and the chosen one that does not fit is not named.
    expect(faceText(tester, 'benchmark-test'), 'Reply speed');
    expect(find.text('Two warm-up messages, then a long story.'), findsOneWidget);
    // A longer context, and the tests that fit are open; the 25k chosen by default is back.
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 250));
    await choose(tester, 'benchmark-context', '65536');
    expect(faceText(tester, 'benchmark-test'), 'Reply speed, Prompt 25k');
    await open(tester, 'benchmark-test');
    expect([for (final t in BenchmarkTest.all) chosable(tester, 'benchmark-test-${t.id}')], [true, true, true, true, false]);
    expect(find.text('Needs a longer context'), findsOneWidget);
    // Each click turns one on or off, and the list stays open; they run in the list's order.
    await tester.tap(find.byKey(const Key('benchmark-test-prompt-8k')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('benchmark-test-reply')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));
    expect(faceText(tester, 'benchmark-test'), 'Prompt 8k, Prompt 25k');
    expect(
      find.text(
        'Two warm-up messages, then a story of 8k tokens and a short review; a story of 25k tokens and a short review. '
        'Each test starts from right after the warm-ups.',
      ),
      findsOneWidget,
    );
    expect(Storage(dir).readBenchmarkSetup()!['tests'], ['prompt-8k', 'prompt-25k']);
  });

  testWidgets('a chosen test that no longer fits shows why nothing can start, in the danger colour, and Start waits', (tester) async {
    await pump(tester, BenchmarkState(setup: BenchmarkSetup(contextLength: 4096, tests: [BenchmarkTest.prompts[1]])));
    final status = find.byKey(const Key('benchmark-status'));
    expect(tester.widget<Text>(status).data, 'The chosen tests need a longer context length.');
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
    expect((faceText(tester, 'benchmark-context'), faceText(tester, 'benchmark-test')), ('65k', 'Reply speed, Prompt 25k'));
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

  /// The texts on the page, for checking that a word is nowhere.
  List<String> pageTexts(WidgetTester tester) => [for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? t.textSpan?.toPlainText() ?? ''];

  /// The state of a run writing the reply of its first test.
  BenchmarkState replying(RunSeries series, {int tokens = 12}) => BenchmarkState(
    phase: BenchmarkPhase.measuring,
    live: series,
    revision: 5,
    replyTokens: tokens,
    tests: BenchmarkSetup.defaultTests,
    hardware: const HardwareInfo(gpus: ['Test GPU']),
  );

  testWidgets('the live cards: one per row, Speed, GPU, CPU, RAM, SSD, each value with a bar against a limit the PC reports', (tester) async {
    await pump(tester, replying(_series(60)));
    expect(tester.takeException(), isNull);
    final cards = [for (final id in ['speed', 'gpu.0', 'cpu', 'ram', 'ssd']) tester.getRect(find.byKey(Key('card-$id')))];
    for (var i = 1; i < cards.length; i++) {
      expect(cards[i].top, greaterThanOrEqualTo(cards[i - 1].bottom), reason: 'one card per row, in order');
      expect((cards[i].left, cards[i].width), (cards[0].left, cards[0].width));
    }
    expect(find.byKey(const Key('card-engine')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('card-gpu.0')), matching: find.text('Test GPU')), findsOneWidget);
    // Writing the reply: only the reply's speed.
    expect(find.byKey(const Key('meter-speed.tokens')), findsOneWidget);
    expect(find.byKey(const Key('meter-speed.prompt')), findsNothing);
    expect(find.byKey(const Key('meter-speed.ttft')), findsNothing);
    // The fields as listed; no PCIe, no other programs, no "Package", no engine, no inner tiles, never a dash.
    for (final id in ['gpu.0.load', 'gpu.0.power', 'gpu.0.clock', 'gpu.0.temp', 'gpu.0.vram', 'cpu.load', 'cpu.mhz', 'cpu.power', 'cpu.temp', 'ram.used', 'ram.swap', 'ssd.read', 'ssd.busy', 'ssd.iops', 'ssd.queue', 'ssd.temp']) {
      expect(find.byKey(Key('meter-$id')), findsOneWidget, reason: id);
    }
    for (final id in ['gpu.0.pcieTx', 'gpu.0.pcieRx', 'cpu.other', 'ram.engine', 'ram.other', 'ram.cache', 'ram.swapActivity', 'eng.stall']) {
      expect(find.byKey(Key('meter-$id')), findsNothing, reason: id);
    }
    final words = pageTexts(tester);
    expect(words.where((w) => w.toLowerCase().contains('package') || w.contains('–') || w.trim() == '-'), isEmpty, reason: '$words');
    // Bars where there is a limit: the highest power limit seen, the target temperature, the memory totals, 100 % of a load.
    for (final id in ['gpu.0.load', 'gpu.0.power', 'gpu.0.temp', 'gpu.0.vram', 'cpu.load', 'ram.used', 'ram.swap', 'ssd.busy', 'ssd.temp']) {
      expect(find.byKey(Key('bar-$id')), findsOneWidget, reason: id);
    }
    for (final id in ['gpu.0.clock', 'cpu.mhz', 'ssd.read', 'ssd.iops', 'ssd.queue']) {
      expect(find.byKey(Key('bar-$id')), findsNothing, reason: id);
    }
    // This CPU reports no power or temperature limit: plain values.
    expect(find.byKey(const Key('bar-cpu.temp')), findsNothing);
    expect(find.byKey(const Key('bar-cpu.power')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('meter-gpu.0.power')), matching: find.textContaining('of 140 W')), findsOneWidget);
    // The RAM: in use and file cache in one bar, against the total.
    expect(find.descendant(of: find.byKey(const Key('meter-ram.used')), matching: find.text('15.0 / 5.0 of 30.0 GB')), findsOneWidget);
  });

  testWidgets('a value near its limit is amber; what the PC does not give is not shown, nor a card with nothing', (tester) async {
    final bare = RunSeries();
    for (var t = 0.0; t < 5; t += 0.5) {
      bare.add(t, {'cpu.load': 10, 'cpu.temp': 95, 'cpu.tempMax': 100, 'ram.total': 30, 'ram.used': 10});
    }
    await pump(tester, replying(bare));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('near-cpu.temp')), findsOneWidget);
    expect(find.byKey(const Key('near-cpu.load')), findsNothing);
    expect(find.byKey(const Key('card-gpu.0')), findsNothing, reason: 'no graphics card');
    expect(find.byKey(const Key('card-ssd')), findsNothing, reason: 'no reading of the drive');
    expect(find.byKey(const Key('meter-ram.swap')), findsNothing);
    expect(find.byKey(const Key('meter-cpu.mhz')), findsNothing);
    expect(find.byKey(const Key('meter-speed.tokens')), findsNothing, reason: 'no speed yet');
    expect(find.byKey(const Key('card-speed')), findsOneWidget);
    expect(pageTexts(tester).where((w) => w.contains('–') || w.trim() == '-'), isEmpty);
  });

  /// What the result page no longer shows (all of it stays in the saved run).
  void nothingRemoved(WidgetTester tester) {
    for (final title in ['The run', 'Memory layout', 'Hardware over the run', 'Streaming from the SSD', 'Each layer']) {
      expect(find.byKey(Key('fold-$title')), findsNothing, reason: title);
    }
    expect(find.byType(Fold), findsNothing);
    expect(find.byType(Table), findsNothing, reason: 'no rows per turn');
    expect(find.textContaining('Turn 1'), findsNothing);
    expect(find.byKey(const Key('scrubber-overall')), findsNothing, reason: 'no time graph');
    expect(find.byKey(const Key('graph-row-gpu.0')), findsNothing, reason: 'no time graph');
    for (final key in ['first-token', 'load', 'slowest-1', 'slowest-token', 'total', 'hits', 'guesses', 'ssd-reads']) {
      expect(find.byKey(Key('result-$key')), findsNothing, reason: key);
    }
  }

  testWidgets('a run that has ended is on Live with its result: the time per token on top, then the chosen tests\' numbers', (tester) async {
    final shown = _multi(id: 2);
    await pump(tester, BenchmarkState(result: shown, live: shown.series, revision: 5, turns: shown.turns, history: [shown]));
    expect(tester.takeException(), isNull);
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.byKey(const Key('card-gpu.0')), findsNothing, reason: 'the cards are the live readings');
    expect(find.textContaining('Test Model  ·  65k  ·  Auto  ·  Reply speed + Prompt 8k + Prompt 25k'), findsOneWidget);
    // The time per token comes first.
    final time = tester.getRect(find.text('Where the time per token went'));
    final tiles = tester.getRect(find.byKey(const Key('result-reply-speed')));
    expect(time.top, lessThan(tiles.top));
    expect(find.textContaining('Server and streaming'), findsNothing);
    expect(find.textContaining('CPU 10.0 ms'), findsOneWidget);
    // The reply speed, and a line per prompt test with its speed and time to first token.
    expect(find.descendant(of: find.byKey(const Key('result-reply-speed')), matching: find.text('Reply speed')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('result-reply-speed')), matching: find.textContaining('40.0')), findsOneWidget);
    String line(String id) => (tester.widget<Text>(find.descendant(of: find.byKey(Key('result-$id')), matching: find.byType(Text))).textSpan!).toPlainText();
    expect(line('prompt-8k'), '8k → ${formatNumber(2000, 0)} tokens/s  ·  TTFT 4.10 s');
    expect(line('prompt-25k'), '25k → ${formatNumber(1250, 0)} tokens/s  ·  TTFT 20.20 s');
    nothingRemoved(tester);
  });

  testWidgets('only the chosen tests\' numbers: no prompt speed without a prompt test, no reply speed or time split without the reply test', (tester) async {
    final replyOnly = _multi(id: 3, tests: const ['reply']);
    await pump(tester, BenchmarkState(result: replyOnly, live: replyOnly.series, history: [replyOnly]));
    expect(find.byKey(const Key('result-reply-speed')), findsOneWidget);
    expect(find.byKey(const Key('result-prompt-speed')), findsNothing);
    expect(find.text('Where the time per token went'), findsOneWidget);

    final promptOnly = _multi(id: 4, tests: const ['prompt-25k']);
    await tester.pumpWidget(const SizedBox());
    await pump(tester, BenchmarkState(result: promptOnly, live: promptOnly.series, history: [promptOnly]));
    expect(find.byKey(const Key('result-reply-speed')), findsNothing);
    expect(find.byKey(const Key('result-prompt-25k')), findsOneWidget);
    expect(find.text('Where the time per token went'), findsNothing);
    // A history row names its figure.
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump();
    expect(find.text('25k → ${formatNumber(1250, 0)} tokens/s'), findsOneWidget);

    // An engine that gave only the SSD wait: no bar, no heading.
    final unsplit = _multi(id: 5, tests: const ['reply'], parts: const {'SSD wait': 5.4});
    await tester.pumpWidget(const SizedBox());
    await pump(tester, BenchmarkState(result: unsplit, live: unsplit.series, history: [unsplit]));
    expect(find.text('Where the time per token went'), findsNothing);
    expect(find.byKey(const Key('result-reply-speed')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a run in the history is a row; a click opens the same result as right after the run; delete asks twice', (tester) async {
    final run = _multi(id: 7);
    await pump(tester, BenchmarkState(result: run, live: run.series, history: [run]));
    // Right after the run: what the Live step shows.
    List<String> shownTexts() => [
      for (final t in tester.widgetList<Text>(find.descendant(of: find.byType(ResultView), matching: find.byType(Text))))
        t.data ?? t.textSpan!.toPlainText(),
    ];
    final afterRun = shownTexts();
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump();
    expect(find.text('FULL RESULT'), findsNothing);
    expect(find.textContaining('Test Model  ·  Auto  ·  65k  ·  Reply speed + Prompt 8k + Prompt 25k'), findsOneWidget);
    expect(find.textContaining('Disturbed'), findsNothing, reason: 'the run was disturbed, and no row says so');
    expect(find.text('40.0 tokens/s'), findsOneWidget);

    await tester.tap(find.byKey(const Key('history-7')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(shownTexts(), afterRun, reason: 'one result page in both places');
    nothingRemoved(tester);
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


  testWidgets('during a run the heading follows it: the warm-ups, then each test; the speed of the phase only', (tester) async {
    final turns = _turns();
    const setup = BenchmarkSetup();
    const tests = BenchmarkSetup.defaultTests;
    final live = _series(60);
    await pump(tester, BenchmarkState(phase: BenchmarkPhase.warmingUp, setup: setup, live: live, revision: 5, tests: tests));
    final fake = ProviderScope.containerOf(tester.element(find.byType(EnginePage))).read(benchmarkProvider.notifier) as _Fake;
    String title() => tester.widget<Text>(find.byKey(const Key('live-title'))).data!;
    Finder inSpeed(Finder f) => find.descendant(of: find.byKey(const Key('card-speed')), matching: f);

    // The warm-ups: the heading says so, and the Speed card shows nothing but that.
    expect(tester.takeException(), isNull);
    expect(title(), 'Warm-up 1 of 2');
    expect(inSpeed(find.text('warming up')), findsOneWidget);
    expect(inSpeed(find.byKey(const Key('meter-speed.tokens'))), findsNothing);
    expect(inSpeed(find.byKey(const Key('meter-speed.prompt'))), findsNothing);
    expect(find.byKey(const Key('card-gpu.0')), findsOneWidget);

    fake.put(BenchmarkState(phase: BenchmarkPhase.warmingUp, warmup: 1, setup: setup, live: live, revision: 6, turns: turns.sublist(0, 1), tests: tests));
    await tester.pump();
    expect(title(), 'Warm-up 2 of 2');

    // A test reading its prompt: only the prompt's speed.
    final reading = _series(60)..add(60.5, {'speed.prompt': 420});
    fake.put(
      BenchmarkState(phase: BenchmarkPhase.measuring, setup: setup, live: reading, revision: 7, turns: turns.sublist(0, 2), tests: tests, promptProgress: (1000, 25000)),
    );
    await tester.pump();
    expect(title(), 'Reply speed (1 of 2)');
    expect(find.text('Reading the prompt: 1000 of ${formatNumber(25000, 0)} tokens…'), findsOneWidget);
    expect(inSpeed(find.byKey(const Key('meter-speed.prompt'))), findsOneWidget);
    expect(inSpeed(find.byKey(const Key('meter-speed.tokens'))), findsNothing);
    expect(inSpeed(find.text('warming up')), findsNothing);

    // Writing its reply: only the reply's speed.
    fake.put(BenchmarkState(phase: BenchmarkPhase.measuring, setup: setup, live: live, revision: 8, turns: turns.sublist(0, 2), tests: tests, replyTokens: 12));
    await tester.pump();
    expect(find.text('Writing the reply: 12 tokens…'), findsOneWidget);
    expect(inSpeed(find.byKey(const Key('meter-speed.tokens'))), findsOneWidget);
    expect(inSpeed(find.byKey(const Key('meter-speed.prompt'))), findsNothing);

    // The next test.
    fake.put(BenchmarkState(phase: BenchmarkPhase.measuring, setup: setup, live: live, revision: 9, turns: turns, tests: tests, testIndex: 1));
    await tester.pump();
    expect(title(), 'Prompt 25k (2 of 2)');
    expect(tester.takeException(), isNull);
  });


  testWidgets('a run that is loading shows the cards; a stopped one keeps none', (tester) async {
    await pump(tester, BenchmarkState(live: _series(20), revision: 3));
    await tester.tap(find.byKey(const Key('bench-step-2')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('card-gpu.0')), findsNothing, reason: 'the cards are the live readings of a run going on');

    final fake = ProviderScope.containerOf(tester.element(find.byType(EnginePage))).read(benchmarkProvider.notifier) as _Fake;
    fake.put(BenchmarkState(phase: BenchmarkPhase.loading, setup: const BenchmarkSetup(), live: _series(20), revision: 4, tests: BenchmarkSetup.defaultTests));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.widget<Text>(find.byKey(const Key('live-title'))).data, 'Loading the model');
    expect(find.byKey(const Key('card-gpu.0')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('card-speed')), matching: find.text('loading the model')), findsOneWidget);
  });

  testWidgets('one card per row fits a narrow window while a run goes on', (tester) async {
    await pump(tester, replying(_series(60)), width: 700);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('card-ram')), findsOneWidget);
  });

  testWidgets('when a run ends the page stays on Live with its result; a stopped run goes back to setup', (tester) async {
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
    expect(find.byKey(const Key('result-reply-speed')), findsOneWidget);

    // A run that was stopped has no result: the page goes to setup.
    fake.put(BenchmarkState(phase: BenchmarkPhase.warmingUp, setup: setup, live: _series(9), revision: 8, turns: turns.sublist(0, 1)));
    await tester.pump();
    fake.put(BenchmarkState(setup: setup, live: _series(9), revision: 9, turns: turns.sublist(0, 1), note: 'Stopped. Nothing was saved.'));
    await tester.pump();
    expect(find.byKey(const Key('benchmark-setup')), findsOneWidget);
    expect(find.text('LIVE'), findsNothing);
    expect(tester.takeException(), isNull);
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

    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump();
    expect(find.text('HISTORY'), findsOneWidget);
    none();
    await tester.tap(find.byKey(const Key('history-3')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('result-reply-speed')), findsOneWidget);
    none();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a run of one test saved before several tests opens in the history as that test\'s result', (tester) async {
    final run = _result(id: 5);
    final prompt = _result(id: 6, label: 'Prompt 25k');
    await pump(tester, BenchmarkState(history: [run, prompt]));
    await tester.tap(find.byKey(const Key('bench-history')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('history-5')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('result-reply-speed')), findsOneWidget);
    expect(find.text('Where the time per token went'), findsOneWidget);
    nothingRemoved(tester);
    await tester.tap(find.byKey(const Key('history-5')));
    await tester.tap(find.byKey(const Key('history-6')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('result-reply-speed')), findsNothing);
    expect(find.byKey(const Key('result-prompt-25k')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the result fits a narrow window without overflow', (tester) async {
    final shown = _multi();
    await pump(tester, BenchmarkState(result: shown, live: shown.series, turns: shown.turns, history: [shown]), width: 700);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('result-prompt-speed')), findsOneWidget);
  });
}

