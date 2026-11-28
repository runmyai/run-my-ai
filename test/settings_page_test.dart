// The Settings page (lib/ui/pages/settings_page.dart): Storage and Folders as drop-downs that start closed, each
// setting's description shown as a tooltip on its name instead of as text under it, and the KV cache quantization
// picker (lib/ui/context_settings.dart), which sets each length's cache type and never the chat's context length.
// Run: flutter test test/settings_page_test.dart
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/dummy_backend.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/profiles.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/system/folders.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/pages/settings_page.dart';
import 'package:runmyai/ui/settings/folders_section.dart';

/// The app's folders in the test's folder.
const _file = ModelFile(id: 'm/f', quantization: 'q', sizeBytes: 1);
const CatalogEntry _entry = (
  model: CatalogModel(id: 'm', name: 'M', lab: 'L', description: '', parameters: '1B', activeParameters: '1B', files: [_file]),
  file: _file,
);

class _Folders extends FoldersNotifier {
  _Folders(this.main);
  final String main;

  @override
  FolderSet build() => FolderSet(main: main, models: '$main/models', chats: '$main/chats', cache: '$main/cache');
}

void main() {
  late Directory dir;
  late ProviderContainer container;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('runmyai-settings-');
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        shownModelProvider.overrideWithValue(null),
        backendProvider.overrideWithValue(DummyBackend()),
        foldersProvider.overrideWith(() => _Folders('${dir.path}/main')),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
  }

  testWidgets('Storage and Folders start closed and open on a click', (tester) async {
    await show(tester);
    expect(find.byKey(const Key('state-limit')), findsNothing);
    expect(find.byKey(const Key('folder-path-models')), findsNothing);

    await tester.tap(find.byKey(const Key('fold-Storage')));
    await tester.pump();
    expect(find.byKey(const Key('state-limit')), findsOneWidget);
    expect(find.byKey(const Key('folder-path-models')), findsNothing, reason: 'Folders stays closed');

    await tester.tap(find.byKey(const Key('fold-Folders')));
    await tester.pump();
    for (final id in ['models', 'chats', 'cache', 'engine']) {
      expect(find.byKey(Key('folder-path-$id')), findsOneWidget);
    }
    expect(find.byKey(const Key('folder-path-main')), findsNothing, reason: 'the main folder is only in the first start');
  });

  testWidgets('descriptions are tooltips on the names, never text on the page', (tester) async {
    await show(tester);
    await tester.tap(find.byKey(const Key('fold-Storage')));
    await tester.tap(find.byKey(const Key('fold-Folders')));
    await tester.pump();
    for (final description in [
      'A sound when a response finishes.',
      'How much disk space chats may use to continue quickly. When it is full the oldest are removed; your chats '
          'themselves are never touched.',
      foldersAbout,
      'Downloaded models go here.',
      'Your chats, one file each.',
      'What lets a chat continue quickly. The engine stops while it moves.',
      'Models already on this computer are used where they are.',
      'An idea, a bug, or something you like: it goes straight to us.',
    ]) {
      expect(find.text(description), findsNothing, reason: description);
      expect(find.byTooltip(description), findsOneWidget, reason: description);
    }
    expect(find.byIcon(Icons.info_outline), findsNothing, reason: 'no info buttons');
  });

  testWidgets('resting the pointer on a name shows its description', (tester) async {
    await show(tester);
    const description = 'A sound when a response finishes.';
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Notification Sound')));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(description), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
  });

  testWidgets('the KV cache block sets each length\'s cache type and has no buttons that pick a length', (tester) async {
    container.dispose();
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        shownModelProvider.overrideWithValue(_entry),
        backendProvider.overrideWithValue(DummyBackend()),
        foldersProvider.overrideWith(() => _Folders('${dir.path}/main')),
      ],
    );
    await show(tester);
    expect(find.text('KV cache quantization'), findsOneWidget);
    expect(find.text('Context length'), findsNothing);
    final before = container.read(libraryProvider).contextLength;

    // A length's name is plain text: a click on it picks nothing.
    await tester.tap(find.text('8k'));
    await tester.pump();
    expect(container.read(libraryProvider).contextLength, before);

    // Every length has its cache type, with the memory it takes.
    for (final tokens in [4096, 8192, 16384, 32768, 65536, 100000, 131072, 200000, 262144]) {
      expect(find.byKey(Key('kv-$tokens')), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('kv-100000')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Full Quality (F16)'));
    await tester.pumpAndSettle();
    expect(container.read(profilesProvider)[_file.id]!.kv[100000], 'f16');
    expect(container.read(libraryProvider).contextLength, before, reason: 'the chat\'s length is chosen in its picker');
  });
}
