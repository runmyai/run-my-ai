// The VRAM headroom setting: the graphics card memory the engine leaves free for the desktop and other apps.
// Run: flutter test test/vram_headroom_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/backend/engine_backend.dart';
import 'package:runmyai/benchmark/benchmark.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/commands.dart';
import 'package:runmyai/engine/tuning.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/prefs.dart';
import 'package:runmyai/state/profiles.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/context_settings.dart';
import 'package:runmyai/ui/pages/settings_page.dart';

const _file = ModelFile(id: 'm/f', quantization: 'q', sizeBytes: 1);

class _Backend implements Backend {
  @override
  Map<int, String> autoCommands(ModelFile file) => const {4096: '-c 4096 --moe-stream-vram-free 200MiB --x 1'};
  @override
  int maxContext(ModelFile file) => 4096;
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
  Future<List<CatalogModel>> loadCatalog() async => const [];
  @override
  Stream<double> download(ModelFile file) => const Stream.empty();
  @override
  Future<void> deleteDownload(ModelFile file) async {}
}

/// A backend with the cards it is told of, and a tune that can end.
class _GpuBackend extends _Backend implements TuneControl {
  @override
  List<({String key, String name, String desc, int mib})> cards = const [(key: 'CUDA0', name: 'CUDA0', desc: '', mib: 12288)];
  @override
  bool sharesRam = false;
  final tuned = ValueNotifier<String?>(null);
  @override
  ValueListenable<String?> get tuning => tuned;
  @override
  Map<String, dynamic>? savedTune(ModelFile file) => null;
  @override
  Future<Map<String, dynamic>?> tune(ModelFile file) async => null;
}

void main() {
  group('the command', () {
    test('the default reaches every Auto command with a card; the rest of the command stays', () {
      for (final length in autoContextLengths) {
        final command = autoCommand(length, vramFree: '200MiB', elastic: true);
        final set = withVramFree(command, vramSize(defaultVramHeadroomGiB));
        expect(set, contains('--moe-stream-vram-free 512MiB'));
        expect(set.replaceAll('512MiB', '200MiB'), command);
      }
    });

    test('a set value reaches the command', () {
      expect(withVramFree('-c 4096 --moe-stream-vram-free 200MiB --x 1', vramSize(1)), '-c 4096 --moe-stream-vram-free 1024MiB --x 1');
      expect(withVramFree('--moe-stream-vram-free=200MiB', vramSize(0.25)), '--moe-stream-vram-free=256MiB');
      expect(withVramFree('--moe-stream-vram-free 200MiB', vramSize(1.5)), '--moe-stream-vram-free 1536MiB');
      expect(withVramFree('--x --moe-stream-vram-free 200MiB', 'CUDA0=1GiB,CUDA1=512MiB'), '--x --moe-stream-vram-free CUDA0=1GiB,CUDA1=512MiB');
    });

    test('a command for the CPU has no VRAM flag, and gets none', () {
      for (final length in autoContextLengths) {
        final command = autoCommand(length);
        expect(command, isNot(contains('vram-free')));
        expect(withVramFree(command, vramSize(1)), command);
      }
    });
  });

  test('the value of --moe-stream-vram-free: the list form for named cards, the pool\'s card first; one size for an unnamed card', () {
    const a = (name: 'CUDA2', mib: 12288), b = (name: 'CUDA1', mib: 12288), pool = (name: 'CUDA0', mib: 8192);
    expect(vramFreeValue([a, b, pool], [1, 0.75, 0.5]), 'CUDA0=512MiB,CUDA2=1024MiB,CUDA1=768MiB');
    expect(vramFreeValue([b, pool], [0.25, 2]), 'CUDA0=2048MiB,CUDA1=256MiB');
    expect(vramFreeValue([pool], [1.5]), 'CUDA0=1536MiB');
    expect(vramFreeValue([(name: '', mib: 12288)], [0.5]), '512MiB');
  });

  group('the setting', () {
    late Directory dir;
    late ProviderContainer container;
    ProviderContainer open() => ProviderContainer(
      overrides: [storageProvider.overrideWithValue(Storage(dir)), backendProvider.overrideWithValue(_Backend())],
    );

    setUp(() {
      dir = Directory.systemTemp.createTempSync('runmyai-vram-');
      container = open();
    });
    tearDown(() {
      container.dispose();
      dir.deleteSync(recursive: true);
    });

    VramHeadroom setting(ProviderContainer c) => c.read(prefsProvider).vramHeadroomSetting;

    test('0.5 GB for a card without a value, and a run carries what is set', () {
      expect(setting(container).of('CUDA0'), 0.5);
      container.read(prefsProvider.notifier).setVramHeadroom('CUDA0', 1);
      expect(setting(container).of('CUDA0'), 1);
      expect(setting(container).of('CUDA1'), 0.5, reason: 'another card keeps the default');
      expect(container.read(profilesProvider.notifier).runFor(_file, 4096).vramHeadroom.of('CUDA0'), 1);
      expect(container.read(profilesProvider.notifier).runWith(_file, autoProfileId, 4096).vramHeadroom.of('CUDA0'), 1);
    });

    test('never under 0.25 GB', () {
      container.read(prefsProvider.notifier).setVramHeadroom('CUDA0', 0.1);
      expect(setting(container).of('CUDA0'), minVramHeadroomGiB);
      // (A file edited by hand is raised too.)
      File('${dir.path}/settings.json').writeAsStringSync('{"vramHeadroom": {"CUDA0": 0.01}, "vramHeadroomGiB": 0.02}');
      final edited = open();
      addTearDown(edited.dispose);
      expect(setting(edited).of('CUDA0'), minVramHeadroomGiB);
      expect(setting(edited).of('CUDA1'), minVramHeadroomGiB);
    });

    test('each card keeps its own value across a restart', () {
      container.read(prefsProvider.notifier)
        ..setVramHeadroom('CUDA0', 2)
        ..setVramHeadroom('CUDA1', 0.75);
      final restarted = open();
      addTearDown(restarted.dispose);
      expect(setting(restarted).of('CUDA0'), 2);
      expect(setting(restarted).of('CUDA1'), 0.75);
      expect(setting(restarted).of('CUDA2'), 0.5);
    });

    test('the single value older versions saved is the value of every card without its own, and is not changed', () {
      File('${dir.path}/settings.json').writeAsStringSync('{"vramHeadroomGiB": 1.5}');
      final old = open();
      addTearDown(old.dispose);
      expect(setting(old).of('CUDA0'), 1.5);
      expect(setting(old).of('CUDA1'), 1.5);
      old.read(prefsProvider.notifier).setVramHeadroom('CUDA0', 0.5);
      expect(setting(old).of('CUDA0'), 0.5, reason: 'its own value, even the default');
      expect(setting(old).of('CUDA1'), 1.5);
      final saved = jsonDecode(File('${dir.path}/settings.json').readAsStringSync()) as Map;
      expect(saved['vramHeadroomGiB'], 1.5, reason: 'kept as it was');
      expect(saved['vramHeadroom'], {'CUDA0': 0.5});
    });

    test('a change starts the engine again at the next load', () {
      const a = EngineRun(flags: '-c 4096', contextLength: 4096);
      const b = EngineRun(flags: '-c 4096', contextLength: 4096, vramHeadroom: VramHeadroom(byCard: {'CUDA0': 1}));
      const other = EngineRun(flags: '-c 4096', contextLength: 4096, vramHeadroom: VramHeadroom(byCard: {'CUDA1': 1}));
      expect(EngineBackend.startedWith(a), isNot(EngineBackend.startedWith(b)));
      expect(EngineBackend.startedWith(b), isNot(EngineBackend.startedWith(other)));
      expect(EngineBackend.startedWith(b), EngineBackend.startedWith(b.withFlags('-c 4096')));
      expect(EngineBackend.startedWith(b.forBenchmark()), EngineBackend.startedWith(b));
    });

    testWidgets('a card\'s box: a value under the minimum is raised and saved; Reset puts the saved one back', (tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: VramHeadroomInput(card: 'CUDA0'))),
        ),
      );
      final box = find.byKey(const Key('vram-headroom-CUDA0'));
      final save = find.byKey(const Key('vram-headroom-save-CUDA0'));
      expect(tester.widget<TextField>(box).controller!.text, '0.5');
      expect(save, findsNothing);
      await tester.enterText(box, '0.1');
      await tester.pump();
      await tester.tap(save);
      await tester.pump();
      expect(setting(container).of('CUDA0'), 0.25);
      expect(tester.widget<TextField>(box).controller!.text, '0.25');
      await tester.enterText(box, 'lots');
      await tester.pump();
      await tester.tap(save);
      await tester.pump();
      expect(find.textContaining('Enter a number'), findsOneWidget);
      expect(setting(container).of('CUDA0'), 0.25);
      await tester.tap(find.byKey(const Key('vram-headroom-reset-CUDA0')));
      await tester.pump();
      expect(tester.widget<TextField>(box).controller!.text, '0.25');
    });
  });

  test('a benchmark record keeps the values per card, and an old record without them still reads', () {
    final json = <String, Object?>{
      'at': 0, 'modelName': 'm', 'contextLength': 4096, 'profileName': 'Auto', 'flags': '-c 4096',
      'promptLabel': 'p', 'replyLength': 10, 'warmups': <String>[], 'loadMillis': 1, 'firstTokenMillis': 1,
      'promptTokens': 1, 'promptMillis': 1, 'replyTokens': 1, 'replyMillis': 1, 'tokenGaps': <num>[],
      'engineStats': <String, Object?>{}, 'log': <String>[], 'disturbed': <String>[],
    };
    expect(BenchmarkResult.fromJson(json).vramHeadroom, isEmpty);
    final kept = BenchmarkResult.fromJson({'vramHeadroom': {'CUDA0': 0.75, 'CUDA1': 1}, ...json});
    expect(BenchmarkResult.fromJson(kept.toJson()).vramHeadroom, {'CUDA0': 0.75, 'CUDA1': 1.0});
  });

  group('Settings: one row per graphics card the engine can use', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('runmyai-vramrow-'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<ProviderContainer> show(WidgetTester tester, Backend backend) async {
      final container = ProviderContainer(
        overrides: [
          storageProvider.overrideWithValue(Storage(dir)),
          backendProvider.overrideWithValue(backend),
          shownModelProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.dark),
            home: const Scaffold(body: SettingsPage()),
          ),
        ),
      );
      return container;
    }

    testWidgets('a row for each card, with its name and memory; none without a card; the saved values stay', (tester) async {
      Storage(dir).writePrefs(const PrefsData(vramHeadroom: {'CUDA1': 2}));
      final backend = _GpuBackend()
        ..cards = const [
          (key: 'CUDA1', name: 'CUDA1', desc: 'NVIDIA GeForce RTX 4070', mib: 12288),
          (key: 'CUDA0', name: 'CUDA0', desc: '', mib: 8192),
        ];
      final container = await show(tester, backend);
      expect(find.text('VRAM headroom'), findsOneWidget, reason: 'one heading above the rows');
      expect(find.byType(VramHeadroomInput), findsNothing, reason: 'a drop-down, closed at first');
      await tester.tap(find.byKey(const Key('fold-VRAM headroom')));
      await tester.pump();
      expect(find.text('NVIDIA GeForce RTX 4070, CUDA1, 12 GB'), findsOneWidget, reason: 'the full name first when known');
      expect(find.text('CUDA0, 8 GB'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const Key('vram-headroom-CUDA1'))).controller!.text, '2');
      expect(tester.widget<TextField>(find.byKey(const Key('vram-headroom-CUDA0'))).controller!.text, '0.5');
      // one card, not yet named (before the autotuner's first run)
      backend.cards = const [(key: 'gpu', name: '', desc: '', mib: 12288)];
      backend.tuned.value = 'm';
      await tester.pump();
      backend.tuned.value = null;
      await tester.pump();
      expect(find.text('Graphics card, 12 GB'), findsOneWidget);
      expect(find.byKey(const Key('vram-headroom-CUDA1')), findsNothing);
      backend.cards = const [];
      backend.tuned.value = 'm';
      await tester.pump();
      backend.tuned.value = null;
      await tester.pump();
      expect(find.text('VRAM headroom'), findsNothing);
      expect(find.byType(VramHeadroomInput), findsNothing);
      expect(container.read(prefsProvider).vramHeadroom, {'CUDA1': 2});
      expect(Storage(dir).readPrefs().vramHeadroom, {'CUDA1': 2});
    });

    testWidgets('no section when the backend does not measure the PC (no engine)', (tester) async {
      await show(tester, _Backend());
      expect(find.text('VRAM headroom'), findsNothing);
    });

    testWidgets('no heading at all when the only GPU is built in and shares the RAM', (tester) async {
      final backend = _GpuBackend()
        ..cards = const [(key: 'Vulkan0', name: 'Vulkan0', desc: 'Radeon 890M', mib: 16384)]
        ..sharesRam = true;
      await show(tester, backend);
      expect(find.text('VRAM headroom'), findsNothing);
      expect(find.byKey(const Key('fold-VRAM headroom')), findsNothing);
    });

    Future<EngineBackend> withCards(List<Map<String, Object?>> cards, {List<int> built = const []}) async {
      File('${dir.path}/autotuner.json').writeAsStringSync(
        jsonEncode({
          'version': 2,
          'gpus': cards,
          'igpus': [for (final m in built) {'name': 'i', 'mib': m}],
          'models': <String, Object?>{},
        }),
      );
      return EngineBackend(Storage(dir));
    }

    Map<String, Object?> card(String name, int mib, int gbps, [String? desc]) =>
        {'name': name, 'mib': mib, 'gbps': gbps, 'desc': ?desc};

    test('the cards: separate ones of any size or make, a built-in GPU only with 24 GiB or more; same names get their place', () async {
      expect((await withCards([card('CUDA0', 12 * 1024, 20)])).cards, [(key: 'CUDA0', name: 'CUDA0', desc: '', mib: 12288)]);
      expect((await withCards([card('Vulkan0', 2 * 1024, 5)])).cards, hasLength(1), reason: 'under 4 GB too, any make');
      expect((await withCards([])).cards, isEmpty);
      expect((await withCards([], built: [8 * 1024])).cards, isEmpty, reason: 'a small built-in GPU is not used');
      expect((await withCards([], built: [32 * 1024])).cards, hasLength(1), reason: 'a built-in GPU the app uses as its card');
      expect((await withCards([card('CUDA0', 12 * 1024, 20, 'NVIDIA GeForce RTX 4070')])).cards.single.desc, 'NVIDIA GeForce RTX 4070',
          reason: 'the autotuner\'s full name');
      final same = (await withCards([card('Vulkan0', 8192, 20), card('Vulkan0', 8192, 10)])).cards;
      expect([for (final c in same) c.key], ['Vulkan0#0', 'Vulkan0#1']);
    });

    test('elastic RAM beside a separate card and on the CPU alone: a built-in GPU used as the card runs with fixed memory, no VRAM row', () async {
      final separate = await withCards([card('CUDA0', 12 * 1024, 10)]);
      final file = (await separate.loadCatalog()).first.files.first;
      expect(separate.sharesRam, isFalse);
      expect(separate.autoCommands(file)[4096], contains('--moe-stream-elastic 1'));
      final built = await withCards([], built: [32 * 1024]);
      expect(built.sharesRam, isTrue);
      expect(built.autoCommands(file)[4096], isNot(contains('--moe-stream-elastic')));
      expect((await withCards([])).sharesRam, isFalse, reason: 'no card at all');
      expect((await withCards([])).autoCommands(file)[4096], contains('--moe-stream-elastic 1'), reason: 'the CPU alone: elastic RAM too');
    });

    test('one card with a name: its own list form; nothing else about the cards from the app', () async {
      final backend = await withCards([card('CUDA0', 12 * 1024, 10)]);
      final file = (await backend.loadCatalog()).first.files.first;
      Storage(dir).writePrefs(const PrefsData(vramHeadroom: {'CUDA0': 1.5}));
      expect(backend.autoCommands(file)[4096], autoCommand(4096, vramFree: 'CUDA0=1536MiB', elastic: true));
      Storage(dir).writePrefs(const PrefsData());
      expect(backend.autoCommands(file)[4096], contains('--moe-stream-vram-free CUDA0=512MiB '));
    });

    test("several cards: each keeps its own value free; which card does what is the autotuner's and the engine's", () async {
      final backend = await withCards([card('CUDA0', 12 * 1024, 10), card('CUDA1', 12 * 1024, 20)]);
      final file = (await backend.loadCatalog()).first.files.first;
      Storage(dir).writePrefs(const PrefsData(vramHeadroom: {'CUDA0': 1, 'CUDA1': 0.75}));
      final c = backend.autoCommands(file)[4096]!;
      expect(c, autoCommand(4096, vramFree: 'CUDA0=1024MiB,CUDA1=768MiB', elastic: true));
      for (final flag in [' -ts ', '--device', '--moe-stream-vram-device', 'gpu-layers']) {
        expect(c, isNot(contains(flag)));
      }
      // a card without a value takes the default
      Storage(dir).writePrefs(const PrefsData(vramHeadroom: {'CUDA1': 4}));
      expect(backend.autoCommands(file)[4096], contains('--moe-stream-vram-free CUDA0=512MiB,CUDA1=4096MiB '));
      // the older single value reaches every card without one of its own
      Storage(dir).writePrefs(const PrefsData(vramHeadroomGiB: 2));
      expect(backend.autoCommands(file)[4096], contains('--moe-stream-vram-free CUDA0=2048MiB,CUDA1=2048MiB '));
    });

    test("no card: the CPU. A small separate card is the engine's to use", () async {
      final none = await withCards([]);
      final file = (await none.loadCatalog()).first.files.first;
      expect(none.autoCommands(file)[4096], autoCommand(4096, elastic: true));
      expect((await withCards([card('CUDA0', 2 * 1024, 5)])).autoCommands(file)[4096],
          autoCommand(4096, vramFree: 'CUDA0=512MiB', elastic: true));
    });

    test('a model whose data files have their own names: named in its command, the VRAM list only with a card', () async {
      final backend = await withCards([card('CUDA0', 12 * 1024, 10)]);
      final qwen = (await backend.loadCatalog()).last.files.first;
      final c = backend.autoCommands(qwen)[4096]!;
      expect(c, contains('--moe-stream-correction {models}/Qwen3.8-Flash-Next-WV-v5-3.5bpw.correction'));
      expect(c, contains('--moe-stream-vram-experts-file {models}/Qwen3.8-Flash-Next-WV-v5-3.5bpw.vram-experts.json'));
      final onCpu = (await withCards([])).autoCommands(qwen)[4096]!;
      expect(onCpu, contains('--moe-stream-correction {models}/Qwen3.8-Flash-Next-WV-v5-3.5bpw.correction'));
      expect(onCpu, isNot(contains('vram-experts')));
    });
  });
}
