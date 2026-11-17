// Serve: hosting a model for other programs, the remembered port and key, and chats paused while it is hosted.
// Run: flutter test test/serve_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/engine_process.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/serve_panel.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/state/serve.dart';

/// Answers chats with a reply that never ends, and hosts without an engine.
class _Backend implements Backend, ServeControl {
  final asked = <String>[];
  final started = <({String model, int context, int port, String alias, String? key})>[];
  var stops = 0;

  /// What the next start does instead of working.
  Object? failWith;
  void Function(EngineFailure)? ended;

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
    String? apiKey,
    void Function(EngineFailure ended)? onEnded,
  }) async {
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

  test('with no key typed the engine gets none', () async {
    await serve().host(entry, 65536);
    expect(backend.started.single.key, isNull);
    expect(backend.started.single.port, defaultServePort);
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

  testWidgets('the panel shows what other programs need, hosts and stops', (tester) async {
    Storage(dir).writeLibrary(const LibraryData(downloaded: {'m/f'}, picked: 'm/f'));
    final scope = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        chatStoreProvider.overrideWithValue(store),
        backendProvider.overrideWithValue(backend),
        catalogFilesProvider.overrideWithValue({'m/f': entry}),
      ],
    );
    addTearDown(scope.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: Center(child: ServeButton())),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('serve-button')));
    await tester.pumpAndSettle();
    expect(find.text('http://127.0.0.1:8080/v1'), findsOneWidget);
    expect(find.text('ling-3.0-flash'), findsOneWidget);
    expect(find.text('any text'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('serve-key')), 'k1');
    await tester.tap(find.byKey(const Key('serve-host')));
    await tester.pumpAndSettle();
    expect(find.text('Hosting Ling 3.0 Flash'), findsOneWidget);
    expect(find.text('k1'), findsWidgets);
    expect(backend.started.single.key, 'k1');

    await tester.tap(find.byKey(const Key('serve-stop')));
    await tester.pumpAndSettle();
    expect(find.text('Serve a model'), findsOneWidget);
    expect(backend.stops, 1);
  });
}
