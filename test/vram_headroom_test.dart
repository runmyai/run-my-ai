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
import 'package:runmyai/engine/auto_commands.dart';
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

/// A backend that says whether this PC has a card, and a tune that can end.
class _GpuBackend extends _Backend implements TuneControl {
  @override
  bool hasCard = true;
  final tuned = ValueNotifier<String?>(null);
  @override
  ValueListenable<String?> get tuning => tuned;
  @override
  Map<String, dynamic>? savedTune(ModelFile file) => null;
  @override
  Future<Map<String, dynamic>?> tune(ModelFile file) async => null;
}

void main() {
  const gpuTables = [lingAuto, lingAutoSmall, flintAuto, flintAutoSmall, qwenAuto, qwenAutoSmall];
  const cpuTables = [lingAutoCpu, flintAutoCpu, qwenAutoCpu];

  group('the command', () {
    test('the default reaches every GPU recipe command; the rest of the command stays', () {
      for (final table in gpuTables) {
        for (final command in table.values) {
          final set = withVramFree(command, defaultVramHeadroomGiB);
          expect(set, contains('--moe-stream-vram-free 512MiB'));
          expect(set.replaceAll('512MiB', '200MiB'), command);
        }
      }
    });

    test('a set value reaches the command', () {
      expect(withVramFree('-c 4096 --moe-stream-vram-free 200MiB --x 1', 1), '-c 4096 --moe-stream-vram-free 1024MiB --x 1');
      expect(withVramFree('--moe-stream-vram-free=200MiB', 0.25), '--moe-stream-vram-free=256MiB');
      expect(withVramFree('--moe-stream-vram-free 200MiB', 1.5), '--moe-stream-vram-free 1536MiB');
    });

    test('a CPU recipe has no VRAM flag, and gets none', () {
      for (final table in cpuTables) {
        for (final command in table.values) {
          expect(command, isNot(contains('vram-free')));
          expect(withVramFree(command, 1), command);
        }
      }
    });
  });

  test('several cards: the headroom is taken off each faster card\'s memory before its whole layers are counted', () {
    final cards = [(name: 'CUDA1', mib: 12288), (name: 'CUDA0', mib: 12288)];
    String fast(double headroom) =>
        cardFlags(cards, 49, 2, 0.49, headroomGiB: headroom).join(' ').replaceFirst(RegExp(r'.*CUDA1='), '');
    expect(fast(0), '30-48'); // (12 - 2.5) / 0.49: 19 layers
    expect(fast(1), '32-48'); // (12 - 2.5 - 1) / 0.49: 17 layers
    expect(fast(8), '46-48'); // 3 layers
    // (A card that is left with less than one layer still gets one.)
    expect(fast(20), '48-48');
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

    test('0.5 GB until set, and a run carries what is set', () {
      expect(container.read(prefsProvider).vramHeadroomGiB, isNull);
      expect(container.read(profilesProvider.notifier).runFor(_file, 4096).vramHeadroomGiB, isNull);
      container.read(prefsProvider.notifier).setVramHeadroom(1);
      expect(container.read(profilesProvider.notifier).runFor(_file, 4096).vramHeadroomGiB, 1);
      expect(container.read(profilesProvider.notifier).runWith(_file, autoProfileId, 4096).vramHeadroomGiB, 1);
    });

    test('never under 0.25 GB', () {
      container.read(prefsProvider.notifier).setVramHeadroom(0.1);
      expect(container.read(prefsProvider).vramHeadroomGiB, minVramHeadroomGiB);
      // (A file edited by hand is raised too.)
      File('${dir.path}/settings.json').writeAsStringSync('{"vramHeadroomGiB": 0.01}');
      final edited = open();
      addTearDown(edited.dispose);
      expect(edited.read(prefsProvider).vramHeadroomGiB, minVramHeadroomGiB);
    });

    test('it survives a restart, and the default is saved as no value', () {
      container.read(prefsProvider.notifier).setVramHeadroom(2);
      final restarted = open();
      addTearDown(restarted.dispose);
      expect(restarted.read(prefsProvider).vramHeadroomGiB, 2);
      restarted.read(prefsProvider.notifier).setVramHeadroom(defaultVramHeadroomGiB);
      expect(restarted.read(prefsProvider).vramHeadroomGiB, isNull);
    });

    test('a change starts the engine again at the next load', () {
      const a = EngineRun(flags: '-c 4096', contextLength: 4096);
      const b = EngineRun(flags: '-c 4096', contextLength: 4096, vramHeadroomGiB: 1);
      expect(EngineBackend.startedWith(a), isNot(EngineBackend.startedWith(b)));
      expect(EngineBackend.startedWith(b), EngineBackend.startedWith(b.withFlags('-c 4096')));
      expect(EngineBackend.startedWith(b.forBenchmark()), EngineBackend.startedWith(b));
    });

    testWidgets('Settings: a value under the minimum is raised and saved; Reset puts the saved one back', (tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: VramHeadroomInput())),
        ),
      );
      final box = find.byKey(const Key('vram-headroom'));
      expect(tester.widget<TextField>(box).controller!.text, '0.5');
      expect(find.byKey(const Key('vram-headroom-save')), findsNothing);
      await tester.enterText(box, '0.1');
      await tester.pump();
      await tester.tap(find.byKey(const Key('vram-headroom-save')));
      await tester.pump();
      expect(container.read(prefsProvider).vramHeadroomGiB, 0.25);
      expect(tester.widget<TextField>(box).controller!.text, '0.25');
      await tester.enterText(box, 'lots');
      await tester.pump();
      await tester.tap(find.byKey(const Key('vram-headroom-save')));
      await tester.pump();
      expect(find.textContaining('Enter a number'), findsOneWidget);
      expect(container.read(prefsProvider).vramHeadroomGiB, 0.25);
      await tester.tap(find.text('Reset'));
      await tester.pump();
      expect(tester.widget<TextField>(box).controller!.text, '0.25');
    });
  });

  test('a benchmark record keeps it, and an old record without it still reads', () {
    final json = <String, Object?>{
      'at': 0, 'modelName': 'm', 'contextLength': 4096, 'profileName': 'Auto', 'flags': '-c 4096',
      'promptLabel': 'p', 'replyLength': 10, 'warmups': <String>[], 'loadMillis': 1, 'firstTokenMillis': 1,
      'promptTokens': 1, 'promptMillis': 1, 'replyTokens': 1, 'replyMillis': 1, 'tokenGaps': <num>[],
      'engineStats': <String, Object?>{}, 'log': <String>[], 'disturbed': <String>[],
    };
    expect(BenchmarkResult.fromJson(json).vramHeadroomGiB, isNull);
    final kept = BenchmarkResult.fromJson({...json, 'vramHeadroomGiB': 0.75});
    expect(BenchmarkResult.fromJson(kept.toJson()).vramHeadroomGiB, 0.75);
  });

  group('the row shows only where the engine uses a graphics card', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('runmyai-vramrow-'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> show(WidgetTester tester, Backend backend) async {
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
    }

    testWidgets('shown with a card, hidden without, and the saved value stays', (tester) async {
      Storage(dir).writePrefs(const PrefsData(vramHeadroomGiB: 2));
      final backend = _GpuBackend();
      await show(tester, backend);
      expect(find.text('VRAM headroom'), findsOneWidget);
      expect(find.byKey(const Key('vram-headroom')), findsOneWidget);
      backend.hasCard = false;
      backend.tuned.value = 'm';
      await tester.pump();
      backend.tuned.value = null;
      await tester.pump();
      expect(find.text('VRAM headroom'), findsNothing);
      expect(find.byKey(const Key('vram-headroom')), findsNothing);
      expect(Storage(dir).readPrefs().vramHeadroomGiB, 2);
    });

    testWidgets('hidden when the backend does not measure the PC (no engine)', (tester) async {
      await show(tester, _Backend());
      expect(find.text('VRAM headroom'), findsNothing);
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

    Map<String, Object?> card(String name, int mib, int gbps) => {'name': name, 'mib': mib, 'gbps': gbps};

    test('a separate card of any size or make counts, and a built-in GPU only with 24 GiB or more', () async {
      expect((await withCards([card('CUDA0', 12 * 1024, 20)])).hasCard, isTrue);
      expect((await withCards([card('Vulkan0', 2 * 1024, 5)])).hasCard, isTrue, reason: 'under 4 GB too, any make');
      expect((await withCards([])).hasCard, isFalse);
      expect((await withCards([], built: [8 * 1024])).hasCard, isFalse, reason: 'a small built-in GPU is not used');
      expect((await withCards([], built: [32 * 1024])).hasCard, isTrue, reason: 'a built-in GPU the app uses as its card');
    });

    test('two cards: the pool card\'s flag carries the headroom, and each faster card keeps it free too', () async {
      final backend = await withCards([card('CUDA0', 12 * 1024, 10), card('CUDA1', 12 * 1024, 20)]);
      final file = (await backend.loadCatalog()).first.files.first;
      String command() => backend.autoCommands(file)[4096]!;
      int layersOfFast(String c) {
        final m = RegExp(r'CUDA1=(\d+)-(\d+)').firstMatch(c)!;
        return int.parse(m[2]!) - int.parse(m[1]!) + 1;
      }

      final byDefault = command();
      expect(byDefault, contains('--moe-stream-vram-free 512MiB'));
      Storage(dir).writePrefs(const PrefsData(vramHeadroomGiB: 3));
      final more = command();
      expect(more, contains('--moe-stream-vram-free 3072MiB'));
      expect(layersOfFast(more), lessThan(layersOfFast(byDefault)));
    });
  });
}
