// Tuning for the PC: by itself after a download, skipped when a result is kept, waiting while the engine is in use,
// the model unloaded first, the downloads standing still meanwhile, a message sent meanwhile waiting in the engine, the
// busy note (shown for a short while) and Tune.
// Run: flutter test test/tuning_runs_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/backend/engine_backend.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/state/tuning_runs.dart';
import 'package:runmyai/system/chime.dart';
import 'package:runmyai/system/folders.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/buttons.dart';
import 'package:runmyai/ui/pages/store_page.dart';

/// A backend whose tunes end when the test says, with an engine that only remembers what it was told.
class _Backend implements Backend, EngineControl, TuneControl {
  @override
  List<({String key, String name, String desc, int mib})> get cards => const [(key: 'CUDA0', name: 'CUDA0', desc: '', mib: 12288)];
  @override
  bool get sharesRam => false;
  final calls = <String>[];
  final kept = <String, Map<String, dynamic>>{};
  Completer<void> gate = Completer<void>()..complete();

  /// Whether the next tune finds the PC busy.
  var busy = false;

  /// Files whose pretend download goes on until the test ends it, and how often each download was started.
  final slow = <String, Completer<void>>{};
  final starts = <String, int>{};

  final _tuning = ValueNotifier<String?>(null);

  @override
  ValueListenable<String?> get tuning => _tuning;

  final _engine = ValueNotifier(const EngineState(EnginePhase.stopped));

  @override
  Map<String, dynamic>? savedTune(ModelFile file) => kept[file.id];

  @override
  Future<Map<String, dynamic>?> tune(ModelFile file) async {
    calls.add('tune ${file.id}');
    _tuning.value = file.id;
    await gate.future;
    _tuning.value = null;
    return kept[file.id] = {'threads': 4, 'busy': busy};
  }

  @override
  ValueListenable<EngineState> get engineState => _engine;

  @override
  Future<void> startEngine(ModelFile file, EngineRun run, {bool restart = false}) async =>
      _engine.value = EngineState(EnginePhase.ready, modelId: file.id, run: run);

  @override
  Future<void> stopEngine() async {
    calls.add('stop');
    _engine.value = const EngineState(EnginePhase.stopped);
  }

  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) {
    calls.add('reply');
    return StreamController<ReplyEvent>().stream;
  }

  @override
  Future<List<CatalogModel>> loadCatalog() async => [_model];
  @override
  Stream<double> download(ModelFile file) {
    starts[file.id] = (starts[file.id] ?? 0) + 1;
    final end = slow[file.id];
    return end == null ? Stream.value(1) : Stream.fromFuture(end.future.then((_) => 1.0));
  }
  @override
  Future<void> deleteDownload(ModelFile file) async {}
  @override
  Map<int, String> autoCommands(ModelFile file) => const {defaultContextLength: '-c $defaultContextLength'};
  @override
  int maxContext(ModelFile file) => defaultContextLength;
  @override
  List<String> get logLines => const [];
  @override
  Listenable get logChanged => ValueNotifier(0);
  @override
  Future<void> eraseChatState(String chatId) async {}
  @override
  Future<void> setPinnedChats(List<String> chatIds) async {}
  @override
  Future<String?> reportedVersion() async => null;
}

class _Chime extends Chime {
  _Chime(Ref ref) : super(ref, null, Duration.zero);

  @override
  Future<void> play() async {}
}

const _file = ModelFile(id: 'm/f', quantization: 'q', sizeBytes: 1);
const _model = CatalogModel(
  id: 'm',
  name: 'Model',
  lab: 'L',
  description: '',
  parameters: '1B',
  activeParameters: '1B',
  files: [_file],
);

void main() {
  late Directory dir;
  late ChatStore store;
  late _Backend backend;
  late ProviderContainer container;
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('runmyai-tune-');
    store = await ChatStore.open(dir);
    backend = _Backend();
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        chatStoreProvider.overrideWithValue(store),
        backendProvider.overrideWithValue(backend),
        chimeProvider.overrideWith(_Chime.new),
      ],
    );
    await container.read(catalogProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await store.close();
    dir.deleteSync(recursive: true);
  });

  TuningState tuning() => container.read(tuningRunsProvider);

  test('a checked download is tuned right away; the row says so until it ends', () async {
    backend.gate = Completer<void>();
    container.read(libraryProvider.notifier).download(_file);
    await settle();
    expect(container.read(libraryProvider).downloaded, contains('m/f'));
    expect(backend.calls, ['tune m/f']);
    expect(tuning().tuning, 'm/f');
    backend.gate.complete();
    await settle();
    expect(tuning().tuning, isNull);
    expect(tuning().busy, isEmpty);
  });

  test('a model with a kept result is not tuned after its download', () async {
    backend.kept['m/f'] = {'threads': 8};
    container.read(libraryProvider.notifier).download(_file);
    await settle();
    expect(container.read(libraryProvider).downloaded, contains('m/f'));
    expect(backend.calls, isEmpty);
  });

  test('a tune waits while a reply is being written and goes when it ends', () async {
    final chats = container.read(chatsProvider.notifier);
    chats.send('hello', _file);
    await settle();
    container.read(tuningRunsProvider.notifier).tuneAgain(_file);
    await settle();
    expect(backend.calls, ['reply']);
    expect(tuning().waiting, ['m/f']);
    chats.stop();
    await settle();
    expect(backend.calls, ['reply', 'tune m/f']);
    expect(tuning().waiting, isEmpty);
  });

  test('the engine unloads the model before it is tuned', () async {
    await backend.startEngine(_file, const EngineRun(flags: '', contextLength: 4096));
    container.read(tuningRunsProvider.notifier).tuneAgain(_file);
    await settle();
    expect(backend.calls, ['stop', 'tune m/f']);
  });

  test('another loaded model is unloaded too, so the PC is quiet while it measures', () async {
    const other = ModelFile(id: 'o/f', quantization: 'q', sizeBytes: 1);
    await backend.startEngine(other, const EngineRun(flags: '', contextLength: 4096));
    container.read(tuningRunsProvider.notifier).tuneAgain(_file);
    await settle();
    expect(backend.calls, ['stop', 'tune m/f']);
    // nothing loaded: nothing to stop
    backend.calls.clear();
    container.read(tuningRunsProvider.notifier).tuneAgain(_file);
    await settle();
    expect(backend.calls, ['tune m/f']);
  });

  test('the downloads stand still while a model is tuned and continue after', () async {
    const second = ModelFile(id: 'm/g', quantization: 'q2', sizeBytes: 1);
    final library = container.read(libraryProvider.notifier);
    DownloadPhase? phase() => container.read(libraryProvider).downloads['m/g']?.phase;
    backend
      ..slow['m/g'] = Completer<void>()
      ..gate = Completer<void>();
    // The first is downloaded at once and tuned; the next in line does not start before the tune ends.
    library
      ..download(_file)
      ..download(second);
    await settle();
    expect(tuning().tuning, 'm/f');
    expect(backend.starts['m/g'], isNull);
    expect(phase(), DownloadPhase.queued);
    backend.gate.complete();
    await settle();
    expect(backend.starts['m/g'], 1);
    expect(phase(), DownloadPhase.downloading);

    // Tune pressed while it downloads: it stops without showing as paused, and continues by itself.
    backend.gate = Completer<void>();
    container.read(tuningRunsProvider.notifier).tuneAgain(_file);
    await settle();
    expect(tuning().tuning, 'm/f');
    expect(phase(), DownloadPhase.queued);
    backend.gate.complete();
    await settle();
    expect(backend.starts['m/g'], 2);
    expect(phase(), DownloadPhase.downloading);

    // Paused by the user during a tune, it stays paused.
    backend.gate = Completer<void>();
    container.read(tuningRunsProvider.notifier).tuneAgain(_file);
    await settle();
    library.pause('m/g');
    backend.gate.complete();
    await settle();
    expect(phase(), DownloadPhase.paused);
    expect(backend.starts['m/g'], 2);
  });

  test('a tune that finds the PC busy is marked so; Tune again on a quiet PC clears it', () async {
    backend.busy = true;
    container.read(tuningRunsProvider.notifier).tuneAgain(_file);
    await settle();
    expect(tuning().busy, {'m/f'});
    // Not kept: a new start of the app does not show it.
    final again = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        chatStoreProvider.overrideWithValue(store),
        backendProvider.overrideWithValue(backend),
      ],
    );
    addTearDown(again.dispose);
    await again.read(catalogProvider.future);
    expect(again.read(tuningRunsProvider).busy, isEmpty);

    backend.busy = false;
    container.read(tuningRunsProvider.notifier).tuneAgain(_file);
    await settle();
    expect(tuning().busy, isEmpty);
    expect(backend.calls, ['tune m/f', 'tune m/f']);
  });

  testWidgets('the Store row: Tuning for your PC, then Downloaded with the busy note and Tune', (tester) async {
    Storage(dir).writeLibrary(const LibraryData(downloaded: {'m/f'}, picked: 'm/f'));
    final scope = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        chatStoreProvider.overrideWithValue(store),
        backendProvider.overrideWithValue(backend),
        catalogProvider.overrideWith((ref) => [_model]),
      ],
    );
    addTearDown(scope.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: StorePage())),
      ),
    );
    await tester.pump();
    expect(find.text('Downloaded'), findsOneWidget);
    expect(find.byKey(const Key('tune-status-m/f')), findsNothing);

    backend
      ..busy = true
      ..gate = Completer<void>();
    await tester.tap(find.byKey(const Key('tune-again-m/f')));
    await tester.pump();
    expect(find.text('Tuning for your PC...'), findsOneWidget);
    expect(find.text('Downloaded'), findsNothing);

    backend.gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Downloaded'), findsOneWidget);
    expect(find.text('Tuned while the PC was busy. Tune again when it\'s free for the best speed.'), findsOneWidget);
    expect(find.byKey(const Key('tune-again-m/f')), findsOneWidget);
    expect(find.text('Tune'), findsOneWidget);

    // The note goes by itself.
    await tester.pump(busyNoteTime - const Duration(seconds: 1));
    expect(find.byKey(const Key('tune-status-m/f')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('tune-status-m/f')), findsNothing);
    expect(find.text('Downloaded'), findsOneWidget);
  });

  testWidgets('Tune is off while a reply is being written', (tester) async {
    Storage(dir).writeLibrary(const LibraryData(downloaded: {'m/f'}, picked: 'm/f'));
    final scope = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        chatStoreProvider.overrideWithValue(store),
        backendProvider.overrideWithValue(backend),
        catalogProvider.overrideWith((ref) => [_model]),
      ],
    );
    addTearDown(scope.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: StorePage())),
      ),
    );
    await tester.pump();
    final tune = find.descendant(of: find.byKey(const Key('tune-again-m/f')), matching: find.byType(AppButton));
    bool on() => tester.widget<AppButton>(tune).onTap != null;
    expect(on(), isTrue);
    scope.read(chatsProvider.notifier).send('hello', _file);
    await tester.pump();
    expect(on(), isFalse);
    scope.read(chatsProvider.notifier).stop();
    await tester.pump();
    expect(on(), isTrue);
  });

  group('the engine', () {
    // A model file, an autotuner that takes a moment and an engine program that never becomes ready, each writing
    // to a log when it runs.
    late Directory root;
    late EngineBackend engine;
    late ModelFile file;
    late File log;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('runmyai-tune-engine-');
      final folder = Directory('${root.path}/engine')..createSync();
      log = File('${root.path}/log');
      File('${folder.path}/autotuner').writeAsStringSync(
        '#!/bin/sh\necho tuner >> ${log.path}\nsleep 1\necho \'{"threads": 3}\'\necho tuned >> ${log.path}\n',
      );
      File('${folder.path}/llama-server').writeAsStringSync('#!/bin/sh\necho engine >> ${log.path}\nexec sleep 300\n');
      await Process.run('chmod', ['+x', '${folder.path}/autotuner', '${folder.path}/llama-server']);
      final data = Directory('${root.path}/data')..createSync();
      FolderSet(
        main: root.path,
        models: '${root.path}/models',
        chats: '${root.path}/chats',
        cache: '${root.path}/cache',
      ).save(data);
      engine = EngineBackend(Storage(data)..writePrefs(PrefsData(engineFolder: folder.path)));
      file = (await engine.loadCatalog()).first.files.first;
      File('${root.path}/models/${file.parts.first}')
        ..createSync(recursive: true)
        ..writeAsStringSync('weights');
    });

    tearDown(() async {
      await engine.stopEngine();
      root.deleteSync(recursive: true);
    });

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 500 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(done(), isTrue);
    }

    List<String> lines() => log.existsSync() ? log.readAsLinesSync() : const [];

    test('a message sent while the model is tuned waits; the kept result is used, not measured again', () async {
      expect(engine.savedTune(file), isNull);
      final tuned = engine.tune(file);
      // The engine is asked to load (as a message does) while the autotuner runs.
      unawaited(engine.startEngine(file, const EngineRun(flags: '-c 4096', contextLength: 4096)));
      await until(() => lines().contains('engine'));
      expect(lines(), ['tuner', 'tuned', 'engine']);
      expect((await tuned)?['threads'], 3);
      expect(engine.savedTune(file)?['threads'], 3);
      expect(engine.savedTune(file)?['busy'], isA<bool>());
    }, skip: Platform.isWindows ? 'the stand-in programs are shell scripts' : null);

    test('a model never tuned is tuned at its first load, and shows as being tuned meanwhile', () async {
      final seen = <String?>[];
      engine.tuning.addListener(() => seen.add(engine.tuning.value));
      unawaited(engine.startEngine(file, const EngineRun(flags: '-c 4096', contextLength: 4096)));
      await until(() => lines().contains('engine'));
      expect(lines(), ['tuner', 'tuned', 'engine']);
      expect(seen, [file.id, null]);
      expect(engine.savedTune(file)?['threads'], 3);
    }, skip: Platform.isWindows ? 'the stand-in programs are shell scripts' : null);
  });
}
