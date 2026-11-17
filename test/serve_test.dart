// Serve: hosting a model for other programs, the remembered port and key, the Serve page, and chats and benchmarks
// paused while a model is loading or hosted.
// Run: flutter test test/serve_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/backend/engine_backend.dart';
import 'package:runmyai/benchmark/metrics.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/engine_process.dart';
import 'package:runmyai/state/benchmark.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/buttons.dart';
import 'package:runmyai/ui/serve_panel.dart';
import 'package:runmyai/ui/shell.dart';
import 'package:runmyai/ui/sidebar.dart';
import 'package:runmyai/ui/title_bar.dart';
import 'package:runmyai/ui/welcome.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/state/serve.dart';
import 'package:runmyai/state/today.dart';

/// Answers chats with a reply that never ends, and hosts without an engine.
class _Backend implements Backend, ServeControl, EngineControl {
  final asked = <String>[];
  final started = <({String model, int context, int port, String alias, String key})>[];
  final engineStarts = <String>[];
  var stops = 0;

  /// What the next start does instead of working.
  Object? failWith;

  /// While set, a start waits for it (the model is loading).
  Completer<void>? hold;
  void Function(EngineFailure)? ended;

  @override
  Future<void> startEngine(ModelFile file, EngineRun run, {bool restart = false}) async => engineStarts.add(file.id);
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
  Listenable get logChanged => ValueNotifier(0);

  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) {
    asked.add(messages.last.text);
    return StreamController<ReplyEvent>().stream;
  }

  @override
  Future<void> startServing(
    ModelFile file,
    EngineRun run, {
    required int port,
    required String alias,
    required String apiKey,
    void Function(EngineFailure ended)? onEnded,
  }) async {
    if (hold case final Completer<void> h) await h.future;
    if (failWith case final Object e) throw e;
    started.add((model: file.id, context: run.contextLength, port: port, alias: alias, key: apiKey));
    ended = onEnded;
  }

  @override
  Future<void> stopServing() async => stops++;

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
  const file = ModelFile(id: 'm/f', quantization: 'q', sizeBytes: 1);
  const model = CatalogModel(
    id: 'm',
    name: 'Ling 3.0 Flash',
    lab: 'L',
    description: '',
    parameters: '1B',
    activeParameters: '1B',
    files: [file],
  );
  const entry = (model: model, file: file);
  late Directory dir;
  late ChatStore store;
  late _Backend backend;
  late ProviderContainer container;
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  ProviderContainer open() => ProviderContainer(
    overrides: [
      storageProvider.overrideWithValue(Storage(dir)),
      chatStoreProvider.overrideWithValue(store),
      backendProvider.overrideWithValue(backend),
    ],
  );
  ServeNotifier serve() => container.read(serveProvider.notifier);
  ServeState state() => container.read(serveProvider);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('runmyai-serve-');
    store = await ChatStore.open(dir);
    backend = _Backend();
    container = open();
    container.read(serveProvider.notifier).setApiKey('k');
    await settle();
  });

  tearDown(() async {
    container.dispose();
    await store.close();
    dir.deleteSync(recursive: true);
  });

  test('the model name is a plain word', () {
    expect(serveAlias(model), 'ling-3.0-flash');
  });

  test('Host starts the engine with the chosen port, key and context length, and Stop ends it', () async {
    serve()
      ..setPort(9090)
      ..setApiKey('  secret ');
    final hosting = serve().host(entry, 65536);
    expect(state().phase, ServePhase.starting);
    await hosting;
    expect(state().phase, ServePhase.hosting);
    expect(state().hosted, (
      modelId: 'm/f',
      alias: 'ling-3.0-flash',
      port: 9090,
      apiKey: 'secret',
      contextLength: 65536,
    ));
    expect(backend.started.single, (model: 'm/f', context: 65536, port: 9090, alias: 'ling-3.0-flash', key: 'secret'));

    await serve().stop();
    expect(state().phase, ServePhase.idle);
    expect(state().hosted, isNull);
    expect(backend.stops, 1);
  });

  test('Host needs a key, and a generated key is a valid strong one', () async {
    serve().setApiKey('');
    await serve().host(entry, 65536);
    expect(state().phase, ServePhase.idle);
    expect(state().error, contains('API key'));
    expect(backend.started, isEmpty);

    final key = generateApiKey();
    expect(key, hasLength(32));
    expect(key, matches(RegExp(r'^[A-Za-z0-9_-]{32}$')));
    expect(validApiKey(key), isTrue);
    expect(generateApiKey(), isNot(key));
    for (final bad in ['', 'a b', 'a,b', 'a"b', 'ключ']) {
      expect(validApiKey(bad), isFalse, reason: bad);
    }
    serve().setApiKey(key);
    await serve().host(entry, 65536);
    expect(backend.started.single.key, key);
    expect(backend.started.single.port, defaultServePort);
  });

  test('the key reaches the engine in its environment, not on its command line', () {
    final setup = EngineBackend.serveSetup(alias: 'ling', apiKey: 's3cret', environment: const {'A': '1'});
    expect(setup.environment, {'A': '1', 'LLAMA_API_KEY': 's3cret'});
    expect(setup.arguments, ['--alias', 'ling', '--metrics']);
    expect(setup.arguments.join(' '), isNot(contains('s3cret')));
  });

  test('/slots and /metrics become the status, the speed and the totals', () {
    String slots({required bool processing, int? task, int prompt = 0, int decoded = 0}) =>
        '[{"id":0,"n_ctx":65536,"speculative":false,"is_processing":$processing'
        '${task == null ? '' : ',"id_task":$task,"n_prompt_tokens":${prompt + 10},"n_prompt_tokens_processed":$prompt,'
                  '"n_prompt_tokens_cache":0,"params":{},"next_token":[{"has_next_token":true,"has_new_line":false,'
                  '"n_remain":-1,"n_decoded":$decoded}]'}}]';
    String metrics({int prompt = 0, int predicted = 0}) =>
        '# HELP llamacpp:prompt_tokens_total Number of prompt tokens processed\n'
        '# TYPE llamacpp:prompt_tokens_total counter\n'
        'llamacpp:prompt_tokens_total $prompt\n'
        'llamacpp:tokens_predicted_total $predicted\n'
        'llamacpp:predicted_tokens_seconds 0\n'
        'llamacpp:spec_decode_num_accepted_tokens_per_pos_total{position="0"} 3\n';

    expect(parseMetrics(metrics(prompt: 120, predicted: 7)), {
      'prompt_tokens_total': 120,
      'tokens_predicted_total': 7,
      'predicted_tokens_seconds': 0,
    });
    expect(parseSlots('not json'), isNull);
    expect(parseSlots(slots(processing: false)), [(id: 0, processing: false, task: null, promptRead: 0, written: 0)]);

    final t0 = DateTime(2026);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
    var s = const HostStats().next(parseSlots(slots(processing: false)), parseMetrics(metrics()), t0);
    expect((s.activity, s.speed, s.requests, s.generated, s.promptRead), (HostActivity.idle, null, 0, 0, 0));

    // A request arrives: its prompt is read.
    s = s.next(parseSlots(slots(processing: true, task: 5, prompt: 400)), parseMetrics(metrics(prompt: 400)), at(1000));
    expect((s.activity, s.speed, s.requests, s.promptRead), (HostActivity.reading, 400.0, 1, 400));

    // A long prompt step: the engine does not answer; it is still reading and the speed stays.
    s = s.next(null, null, at(3000));
    expect((s.activity, s.speed, s.requests), (HostActivity.reading, 400.0, 1));

    // Writing: the speed is the tokens written since the last answer, the reply's tokens count before it ends.
    s = s.next(
      parseSlots(slots(processing: true, task: 5, prompt: 800, decoded: 20)),
      parseMetrics(metrics(prompt: 800)),
      at(4000),
    );
    expect((s.activity, s.requests, s.generated, s.promptRead), (HostActivity.writing, 1, 20, 800));
    s = s.next(
      parseSlots(slots(processing: true, task: 5, prompt: 800, decoded: 50)),
      parseMetrics(metrics(prompt: 800)),
      at(5000),
    );
    expect((s.activity, s.speed, s.generated), (HostActivity.writing, 30.0, 50));

    // It ends: the engine's own total has the reply now; nothing is counted twice and the count never goes down.
    s = s.next(
      parseSlots(slots(processing: false, task: 5)),
      parseMetrics(metrics(prompt: 800, predicted: 60)),
      at(6000),
    );
    expect((s.activity, s.speed, s.requests, s.generated), (HostActivity.idle, null, 1, 60));

    // A second request is counted once.
    s = s.next(
      parseSlots(slots(processing: true, task: 9, prompt: 5)),
      parseMetrics(metrics(prompt: 805, predicted: 60)),
      at(7000),
    );
    s = s.next(
      parseSlots(slots(processing: false, task: 9)),
      parseMetrics(metrics(prompt: 805, predicted: 70)),
      at(8000),
    );
    expect((s.requests, s.generated, s.promptRead), (2, 70, 805));
  });

  test('the numbers are read with the key about once a second, only while hosting', () async {
    final asked = <(String, String)>[];
    final reading = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        chatStoreProvider.overrideWithValue(store),
        backendProvider.overrideWithValue(backend),
        hostFetchProvider.overrideWithValue((uri, key) async {
          asked.add((uri.path, key));
          return uri.path == '/slots'
              ? '[{"id":0,"is_processing":true,"id_task":3,"n_prompt_tokens_processed":12,'
                    '"next_token":[{"n_decoded":0}]}]'
              : 'llamacpp:prompt_tokens_total 12\n';
        }),
      ],
    );
    addTearDown(reading.dispose);
    reading.listen(hostStatsProvider, (_, _) {});
    await settle();
    expect(asked, isEmpty, reason: 'nothing is hosted');

    reading.read(serveProvider.notifier).setApiKey('key1');
    await reading.read(serveProvider.notifier).host(entry, 65536);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(asked.length, inInclusiveRange(4, 6));
    expect(asked.toSet(), {('/metrics', 'key1'), ('/slots', 'key1')});
    final stats = reading.read(hostStatsProvider);
    expect((stats.activity, stats.requests, stats.promptRead), (HostActivity.reading, 1, 12));

    await reading.read(serveProvider.notifier).stop();
    await settle();
    final before = asked.length;
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(asked.length, before);
    expect(reading.read(hostStatsProvider).requests, 0);
  });

  test('the port and the key are remembered', () async {
    serve()
      ..setPort(9191)
      ..setApiKey('abc');
    final again = open();
    addTearDown(again.dispose);
    expect(again.read(serveProvider).port, 9191);
    expect(again.read(serveProvider).apiKey, 'abc');
    // A port that is not one is not taken.
    again.read(serveProvider.notifier).setPort(70000);
    expect(again.read(serveProvider).port, 9191);
  });

  test('chatting is paused while hosting and works again after Stop', () async {
    final chats = container.read(chatsProvider.notifier);
    await serve().host(entry, 65536);
    chats.send('hello', file);
    await settle();
    expect(backend.asked, isEmpty);
    expect(container.read(chatsProvider).replyingId, isNull);

    await serve().stop();
    chats.send('hello', file);
    await settle();
    expect(backend.asked, ['hello']);
  });

  test('hosting does not start while a reply is being written', () async {
    container.read(chatsProvider.notifier).send('hello', file);
    await settle();
    await serve().host(entry, 65536);
    expect(state().phase, ServePhase.idle);
    expect(state().error, isNotNull);
    expect(backend.started, isEmpty);
  });

  test('a port that is taken is said plainly and another can be tried', () async {
    backend.failWith = PortInUse(8080);
    await serve().host(entry, 65536);
    expect(state().phase, ServePhase.idle);
    expect(state().error, contains('Port 8080 is already in use'));

    backend.failWith = null;
    serve().setPort(8081);
    await serve().host(entry, 65536);
    expect(state().phase, ServePhase.hosting);
    expect(state().error, isNull);
  });

  test('an engine that fails to start shows its last line', () async {
    backend.failWith = const EngineFailure(
      'The engine stopped while loading the model.',
      log: ['loading', 'error: out of memory', ''],
    );
    await serve().host(entry, 65536);
    expect(state().phase, ServePhase.idle);
    expect(state().error, contains('error: out of memory'));
  });

  test('an engine that ends on its own turns hosting off and says why', () async {
    await serve().host(entry, 65536);
    backend.ended!(const EngineFailure('The engine stopped.', log: ['killed']));
    expect(state().phase, ServePhase.idle);
    expect(state().error, contains('killed'));
    final chats = container.read(chatsProvider.notifier);
    chats.send('hello', file);
    await settle();
    expect(backend.asked, ['hello']);
  });

  test('Stop while the model loads ends it quietly', () async {
    backend.failWith = const EngineStopped();
    final hosting = serve().host(entry, 65536);
    await serve().stop();
    await hosting;
    expect(state().phase, ServePhase.idle);
    expect(state().error, isNull);
  });

  test('a load that something else stops goes back to idle and says so', () async {
    backend.failWith = const EngineStopped();
    await serve().host(entry, 65536);
    expect(state().phase, ServePhase.idle);
    expect(state().hosted, isNull);
    expect(state().error, contains('something else stopped the engine'));
  });

  test('no chat, benchmark or second Host starts while a hosted model is loading', () async {
    final loaded = backend.hold = Completer<void>();
    final hosting = serve().host(entry, 65536);
    await settle();
    expect(state().phase, ServePhase.starting);
    expect(state().busy, isTrue);

    container.read(chatsProvider.notifier).send('hello', file);
    await container.read(benchmarkProvider.notifier).start(file, model.name, 65536);
    await serve().host(entry, 65536);
    await settle();
    expect(backend.asked, isEmpty);
    expect(container.read(benchmarkProvider).running, isFalse);
    expect(backend.engineStarts, isEmpty);

    loaded.complete();
    await hosting;
    expect(state().phase, ServePhase.hosting);
    expect(backend.started, hasLength(1));
  });

  test('Back is refused while a model is loading or hosted', () async {
    serve().openPage();
    expect(state().pageShown, isTrue);
    serve().closePage();
    expect(state().pageShown, isFalse);

    serve().openPage();
    await serve().host(entry, 65536);
    serve().closePage();
    expect(state().pageShown, isTrue);
    await serve().stop();
    expect(state().pageShown, isTrue, reason: 'the setup shows again');
    serve().closePage();
    expect(state().pageShown, isFalse);
  });

  group('the Serve page', () {
    late ProviderContainer scope;

    /// The app's window as main() builds it: the window's shape around the first-start gate around the shell.
    Future<void> openApp(WidgetTester tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (_) async => false,
      );
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Storage(dir)
        ..writeLibrary(const LibraryData(downloaded: {'m/f'}, picked: 'm/f'))
        ..writeFirstRun({'welcomeShown': true});
      scope = ProviderContainer(
        overrides: [
          storageProvider.overrideWithValue(Storage(dir)),
          chatStoreProvider.overrideWithValue(store),
          backendProvider.overrideWithValue(backend),
          catalogFilesProvider.overrideWithValue({'m/f': entry}),
          hostStatsProvider.overrideWith(_Stats.new),
          todayProvider.overrideWith(_Today.new),
        ],
      );
      addTearDown(scope.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: scope,
          child: MaterialApp(
            theme: buildTheme(Brightness.dark),
            builder: (context, child) => WindowShape(child: child!),
            home: const FirstRunGate(child: Shell()),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> tap(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(Key(key)));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('fills the window inside the real wrapper, and Back or Escape returns to the app', (tester) async {
      await openApp(tester);
      expect(find.byType(Sidebar), findsOneWidget);

      await tap(tester, 'serve-button');
      expect(find.byType(ServePage), findsOneWidget);
      expect(find.byType(Sidebar), findsNothing, reason: 'a page of its own, not over the app');
      expect(find.byType(Dialog), findsNothing);
      expect(tester.getSize(find.byType(ServePage)), const Size(1600, 900));
      expect(find.text('Serve a model'), findsOneWidget);

      await tap(tester, 'serve-back');
      expect(find.byType(ServePage), findsNothing);
      expect(find.byType(Sidebar), findsOneWidget);

      await tap(tester, 'serve-button');
      expect(find.byType(ServePage), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(Sidebar), findsOneWidget);
    });

    testWidgets('the setup hosts with a hidden key, the status has no Back, and Stop hosting shows the setup', (
      tester,
    ) async {
      await openApp(tester);
      scope.read(serveProvider.notifier).setApiKey('');
      await tap(tester, 'serve-button');
      // No key yet: Host waits for one, and the field says why.
      expect(tester.widget<MainButton>(find.byKey(const Key('serve-host'))).onTap, isNull);
      expect(find.text('Set an API key: other apps use it to connect.'), findsOneWidget);
      expect(find.byKey(const Key('serve-copy-key')), findsNothing);

      await tester.enterText(find.byKey(const Key('serve-key')), 'a b');
      await tester.pump();
      expect(tester.widget<MainButton>(find.byKey(const Key('serve-host'))).onTap, isNull);

      await tap(tester, 'serve-generate');
      final field = tester.widget<TextField>(find.byKey(const Key('serve-key')));
      final key = field.controller!.text;
      expect(validApiKey(key) && key.length == 32, isTrue);
      expect(field.obscureText, isTrue, reason: 'the key is never shown');
      expect(scope.read(serveProvider).apiKey, key, reason: 'remembered');
      expect(find.byKey(const Key('serve-key-note')), findsNothing);
      expect(find.byKey(const Key('serve-copy-key')), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('serve-host')));
        await settle();
      });
      await tester.pump();
      expect(backend.started.single.key, key);
      expect(find.byType(ServePage), findsOneWidget);
      expect(tester.getSize(find.byType(ServePage)), const Size(1600, 900));
      expect(find.text('Ling 3.0 Flash is hosted'), findsOneWidget);
      expect(find.byKey(const Key('serve-back')), findsNothing);
      expect(find.text('Writing…'), findsOneWidget);
      expect(find.text('31.5 tokens/s'), findsOneWidget);
      expect(find.text('http://127.0.0.1:8080/v1'), findsOneWidget);
      expect(find.text('ling-3.0-flash'), findsOneWidget);
      expect(find.text(key), findsNothing, reason: 'the key shows as dots');
      expect(tester.widget<Text>(find.byKey(const Key('hosting-show-key'))).data, '•' * 32);
      expect(find.byKey(const Key('hosting-copy-key')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('hosting-total-requests'))).data, '3');
      expect(tester.widget<Text>(find.byKey(const Key('hosting-total-generated'))).data, formatNumber(12345, 0));
      expect(tester.widget<Text>(find.byKey(const Key('hosting-total-prompt'))).data, '678');
      // Escape does not leave while hosting.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(ServePage), findsOneWidget);

      await tap(tester, 'hosting-stop');
      expect(backend.stops, 1);
      expect(find.text('Serve a model'), findsOneWidget);
      expect(find.byType(Sidebar), findsNothing);
      await tap(tester, 'serve-back');
      expect(find.byType(Sidebar), findsOneWidget);
    });

    testWidgets('loading shows on the page with Stop hosting, and hosting that ends on its own says why', (tester) async {
      await openApp(tester);
      final loaded = backend.hold = Completer<void>();
      await tap(tester, 'serve-button');
      await tester.tap(find.byKey(const Key('serve-host')));
      await tester.pump();
      expect(find.text('Loading Ling 3.0 Flash…'), findsOneWidget);
      expect(find.byKey(const Key('serve-back')), findsNothing);
      expect(find.byKey(const Key('hosting-stop')), findsOneWidget);

      await tester.runAsync(() async {
        loaded.complete();
        await settle();
      });
      await tester.pump();
      expect(find.text('Ling 3.0 Flash is hosted'), findsOneWidget);

      backend.ended!(const EngineFailure('The engine stopped.', log: ['killed']));
      await tester.pump();
      expect(find.byType(ServePage), findsOneWidget, reason: 'the page stays and says why');
      expect(find.text('Serve a model'), findsOneWidget);
      expect(find.textContaining('killed'), findsOneWidget);
    });
  });
}

class _Today extends TodayNotifier {
  @override
  DateTime build() => DateTime(2026, 11, 17);
}

/// Fixed numbers for the hosting screen.
class _Stats extends HostStatsNotifier {
  @override
  HostStats build() =>
      const HostStats(activity: HostActivity.writing, speed: 31.5, requests: 3, generated: 12345, promptRead: 678);
}
