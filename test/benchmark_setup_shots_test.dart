// Pictures of the Benchmark tab's setup, for looking at the design: light and dark, with a drop-down open, and with a
// problem line. It writes PNG files and compares nothing; it is skipped unless a folder is given.
// Run: flutter test test/benchmark_setup_shots_test.dart --dart-define=SHOTS=<folder for the pictures>
// The text is drawn in Cantarell (the first of the app's fonts that this kind of computer has), loaded from the system's
// font folder; without that font the text shows as boxes.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/benchmark/benchmark.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/benchmark.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/pages/engine_page.dart';

const shots = String.fromEnvironment('SHOTS');

const _file = ModelFile(id: 'm/f', quantization: 'MXFP4', sizeBytes: 1);
const _model = CatalogModel(
  id: 'm',
  name: 'Ling 3.0 Flash',
  lab: 'L',
  description: '',
  parameters: '124B',
  activeParameters: '5B',
  files: [_file],
  thinking: ModelThinking.optional,
);

/// A backend with the presets of every context length the model has.
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
  Map<int, String> autoCommands(ModelFile file) => {for (final n in [4096, 8192, 16384, 32768, 65536, 131072, 262144]) n: '-c $n --a 1'};
  @override
  int maxContext(ModelFile file) => 262144;
  @override
  Future<List<CatalogModel>> loadCatalog() async => const [_model];
  @override
  Stream<double> download(ModelFile file) => const Stream.empty();
  @override
  Future<void> deleteDownload(ModelFile file) async {}
}

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

/// Loads the system's Cantarell as the font the text is drawn in (the theme's first font is named Roboto in a test).
Future<void> _loadFont() async {
  final icons = FontLoader('MaterialIcons');
  final iconBytes = await File('${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf').readAsBytes();
  icons.addFont(Future.value(ByteData.sublistView(iconBytes)));
  await icons.load();
  final loader = FontLoader('Roboto');
  for (final name in ['Regular', 'Bold']) {
    final bytes = await File('/usr/share/fonts/abattis-cantarell-fonts/Cantarell-$name.otf').readAsBytes();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

void main() {
  late Directory dir;
  late ChatStore store;
  final boundary = GlobalKey();

  setUp(() => dir = Directory.systemTemp.createTempSync('runmyai-shots-'));
  tearDown(() async {
    await store.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, BenchmarkState state, Brightness brightness) async {
    tester.view
      ..physicalSize = const Size(1100, 760)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await _loadFont();
      store = await ChatStore.open(dir);
    });
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
        child: RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(brightness),
            home: const Scaffold(body: EnginePage()),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> save(WidgetTester tester, String name) async {
    final box = tester.renderObject<RenderRepaintBoundary>(find.byKey(boundary));
    await tester.runAsync(() async {
      final image = await box.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(shots).createSync(recursive: true);
      File('$shots/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Future<void> open(WidgetTester tester, String box) async {
    await tester.tap(find.byKey(Key(box)));
    // (One frame builds the list, the next ones fade it in.)
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// A picture test (skipped without a folder). A test draws shadows as hard outlines by default; the app's own are soft.
  void shotTest(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
    debugDisableShadows = false;
    try {
      await body(tester);
    } finally {
      debugDisableShadows = true;
    }
  }, skip: shots.isEmpty);

  for (final (name, brightness) in [('light', Brightness.light), ('dark', Brightness.dark)]) {
    shotTest('the setup, $name', (tester) async {
      await pump(tester, const BenchmarkState(), brightness);
      await save(tester, 'setup-$name');
      expect(tester.takeException(), isNull);
    });

    shotTest('the setup with the Test drop-down open, $name', (tester) async {
      await pump(tester, const BenchmarkState(setup: BenchmarkSetup(contextLength: 16384)), brightness);
      await open(tester, 'benchmark-test');
      await save(tester, 'setup-test-open-$name');
      expect(tester.takeException(), isNull);
    });

    shotTest('the setup with the Context length drop-down open, $name', (tester) async {
      await pump(tester, const BenchmarkState(), brightness);
      await open(tester, 'benchmark-context');
      await save(tester, 'setup-context-open-$name');
      expect(tester.takeException(), isNull);
    });

    shotTest('the setup with a problem line, $name', (tester) async {
      await pump(tester, BenchmarkState(setup: BenchmarkSetup(contextLength: 8192, test: BenchmarkTest.prompts[2])), brightness);
      await save(tester, 'setup-problem-$name');
      expect(tester.takeException(), isNull);
    });
  }
}
