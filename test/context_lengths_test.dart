// The context lengths a chat can pick (lib/engine/commands.dart, lib/state/profiles.dart): 100k and 200k are real
// lengths, offered in the chat window's picker, and a chat at one of them starts the engine with that -c.
// Run: flutter test test/context_lengths_test.dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/commands.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/profiles.dart';
import 'package:runmyai/state/providers.dart';

const _file = ModelFile(id: 'm/f', quantization: 'q', sizeBytes: 1);

/// A backend with the app's real Auto commands, for a model that runs up to 262k; it records what each reply ran with.
class _Backend implements Backend {
  final runs = <EngineRun>[];

  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) {
    runs.add(run);
    return Stream.value(const ReplyText('ok'));
  }

  @override
  Map<int, String> autoCommands(ModelFile file) => {for (final n in autoContextLengths) n: autoCommand(n)};

  @override
  int maxContext(ModelFile file) => 262144;

  @override
  Future<List<CatalogModel>> loadCatalog() async => [
    const CatalogModel(id: 'm', name: 'm', lab: 'L', description: '', parameters: '1B', activeParameters: '1B', files: [_file]),
  ];
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

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('runmyai-lengths-');
    Storage(dir).writeLibrary(const LibraryData(downloaded: {'m/f'}, picked: 'm/f'));
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
  });

  tearDown(() async {
    container.dispose();
    await store.close();
    dir.deleteSync(recursive: true);
  });

  test('100k and 200k are among the lengths offered, in their place', () {
    expect(contextOptions(262144).map(contextLabel), ['4k', '8k', '16k', '32k', '65k', '100k', '131k', '200k', '262k']);
    expect(container.read(shownContextProvider)!.options, [4096, 8192, 16384, 32768, 65536, 100000, 131072, 200000, 262144]);
  });

  for (final length in [100000, 200000]) {
    test('a chat at ${contextLabel(length)} starts the engine with -c $length', () async {
      final run = container.read(profilesProvider.notifier).runFor(_file, length);
      expect((run.contextLength, contextOf(run.flags)), (length, length));

      container.read(chatsProvider.notifier).pickContext(length);
      expect(container.read(shownContextProvider)!.value, length);
      container.read(chatsProvider.notifier).send('hi', _file);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backend.runs.single.flags, contains('-c $length '));
    });
  }
}
