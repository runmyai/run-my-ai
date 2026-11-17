// The look for models on the disk when the app starts: a model the library remembers as downloaded whose files are
// gone (or a model found in a folder) changes the library without any widget being marked during a build.
// Run: flutter test test/library_scan_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/dummy_backend.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/state/today.dart';
import 'package:runmyai/system/folders.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/shell.dart';
import 'package:runmyai/ui/welcome.dart';

class _Today extends TodayNotifier {
  @override
  DateTime build() => DateTime(2026, 11, 17);
}

const _gone = ModelFile(id: 'gone/q', quantization: 'q', sizeBytes: 1, repo: 'o/gone', parts: ['gone.gguf']);
const _here = ModelFile(id: 'here/q', quantization: 'q', sizeBytes: 1, repo: 'o/here', parts: ['here.gguf']);

/// The stand-in backend with two Hugging Face models: one remembered as downloaded but gone, one in the folder.
class _Backend extends DummyBackend {
  @override
  Future<List<CatalogModel>> loadCatalog() async => [
    for (final f in [_gone, _here])
      CatalogModel(id: f.id, name: f.id, lab: 'L', description: '', parameters: '1B', activeParameters: '1B', files: [f]),
  ];
}

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('runmyai-scan-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => false,
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('a remembered model whose files are gone, and one found in the folder, update the window cleanly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final storage = Storage(dir);
    storage.writeFirstRun(const {});
    storage.writeLibrary(const LibraryData(downloaded: {'gone/q'}, picked: 'gone/q'));
    FolderSet(main: dir.path, models: '${dir.path}/models', chats: '${dir.path}/chats', cache: '${dir.path}/cache')
        .save(dir);
    File('${dir.path}/models/here.gguf')
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    final store = (await tester.runAsync(() => ChatStore.open(dir)))!;
    addTearDown(() => tester.runAsync(store.close));
    final container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(storage),
        chatStoreProvider.overrideWithValue(store),
        backendProvider.overrideWithValue(_Backend()),
        todayProvider.overrideWith(_Today.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: buildTheme(Brightness.light), home: const FirstRunGate(child: Shell())),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(tester.takeException(), isNull);
    expect(container.read(libraryProvider).downloaded, {'here/q'});
    expect(container.read(pickedModelProvider)?.file.id, 'here/q');
  });
}
