// Which model and context length a chat uses: each chat remembers its own, a new chat starts from the last picked.
// Run: flutter test test/model_choice_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/providers.dart';

const _big = ModelFile(id: 'big/f', quantization: 'q', sizeBytes: 1);
const _small = ModelFile(id: 'small/f', quantization: 'q', sizeBytes: 1);

CatalogModel _model(String id, ModelFile file) =>
    CatalogModel(id: id, name: id, lab: 'L', madeBy: '', country: '', released: '', type: '', input: '', output: '', maxContext: '', parameters: '1B', activeParameters: '1B', files: [file]);

class _Backend implements Backend {
  final asked = <(String, int)>[];

  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) {
    asked.add((model.id, run.contextLength));
    return Stream.value(const ReplyText('ok'));
  }

  @override
  Map<int, String> autoCommands(ModelFile file) => {
    for (final n in file == _big ? const [4096, 65536, 262144] : const [65536, 131072]) n: '-c $n',
  };

  @override
  int maxContext(ModelFile file) => 262144;

  @override
  Future<List<CatalogModel>> loadCatalog() async => [_model('big', _big), _model('small', _small)];
  @override
  Stream<double> download(ModelFile file) => const Stream.empty();
  @override
  Future<void> deleteDownload(ModelFile file) async {}
}

void main() {
  late Directory dir;
  late ChatStore store;
  late _Backend backend;
  late ProviderContainer container;
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  ChatsNotifier chats() => container.read(chatsProvider.notifier);
  String? shownModel() => container.read(shownModelProvider)?.file.id;
  int? shownContext() => container.read(shownContextProvider)?.value;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('runmyai-choice-');
    Storage(dir).writeLibrary(const LibraryData(downloaded: {'big/f', 'small/f'}, picked: 'big/f'));
    store = await ChatStore.open(dir);
    backend = _Backend();
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        chatStoreProvider.overrideWithValue(store),
        backendProvider.overrideWithValue(backend),
      ],
    );
    container.listen(shownContextProvider, (_, _) {});
    await container.read(catalogProvider.future);
    await settle();
  });

  tearDown(() async {
    container.dispose();
    await store.close();
    dir.deleteSync(recursive: true);
  });

  test('a fresh start: the last picked model at 65k', () {
    expect((shownModel(), shownContext()), ('big/f', 65536));
  });

  test('a chat keeps its model; looking at it does not change what a new chat starts with', () async {
    chats().send('hi', _big);
    await settle();
    final old = container.read(chatsProvider).openId!;
    chats().newChat();
    chats().pickModel('small/f');
    expect(shownModel(), 'small/f');

    await chats().open(old);
    await settle();
    expect(shownModel(), 'big/f', reason: 'the old chat shows its own model');
    chats().newChat();
    expect(shownModel(), 'small/f', reason: 'still the last one picked');
    expect(backend.asked, [('big/f', 65536)], reason: 'picking and opening load nothing');
  });

  test('a pick in an old chat is that chat\'s from then on, even with nothing sent', () async {
    chats().send('hi', _big);
    await settle();
    final old = container.read(chatsProvider).openId!;
    chats().pickModel('small/f');
    chats().newChat();
    await chats().open(old);
    await settle();
    expect(shownModel(), 'small/f');
    final reopened = await ChatStore.open(dir);
    addTearDown(reopened.close);
    expect(reopened.chats.firstWhere((c) => c.id == old).modelId, 'small/f', reason: 'saved');
  });

  test('each chat has its own context; the last picked carries over and drops to what the model can do', () async {
    chats().pickContext(262144);
    chats().send('hi', _big);
    await settle();
    expect(backend.asked.last, ('big/f', 262144));
    final old = container.read(chatsProvider).openId!;

    chats().newChat();
    chats().pickModel('small/f');
    expect(shownContext(), 131072, reason: 'small has nothing bigger');
    chats().pickContext(65536);
    chats().send('hi', _small);
    await settle();
    expect(backend.asked.last, ('small/f', 65536));

    await chats().open(old);
    await settle();
    expect(shownContext(), 262144, reason: 'the old chat keeps its own');
    chats().send('again', _big);
    await settle();
    expect(backend.asked.last, ('big/f', 262144));
  });
}
