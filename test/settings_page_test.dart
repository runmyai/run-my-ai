// The Settings page (lib/ui/pages/settings_page.dart): Folders as a drop-down that starts closed (its rows in order, the
// saved chat states' disk limit inside their row, its Change buttons held while the model is in use), each setting's
// description shown as a tooltip on its name instead of as text under it, and the KV cache quantization
// picker (lib/ui/context_settings.dart), which sets each length's cache type and never the chat's context length, and
// the sharing choice as one small line at the end of the page.
// Run: flutter test test/settings_page_test.dart
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/dummy_backend.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/prefs.dart';
import 'package:runmyai/state/profiles.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/system/folders.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/buttons.dart';
import 'package:runmyai/ui/pages/settings_page.dart';
import 'package:runmyai/ui/settings/folders_section.dart';
import 'package:runmyai/ui/welcome.dart' show shareBenchmarksLabel, shareBenchmarksNote;

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
  late ChatStore store;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('runmyai-settings-');
    store = await ChatStore.open(dir);
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        chatStoreProvider.overrideWithValue(store),
        shownModelProvider.overrideWithValue(null),
        backendProvider.overrideWithValue(DummyBackend()),
        foldersProvider.overrideWith(() => _Folders('${dir.path}/main')),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await store.close();
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

  testWidgets('Folders starts closed and opens on a click; there is no Storage drop-down', (tester) async {
    await show(tester);
    expect(find.byKey(const Key('fold-Storage')), findsNothing);
    expect(find.text('Storage'), findsNothing);
    expect(find.byKey(const Key('state-limit')), findsNothing);
    expect(find.byKey(const Key('folder-path-models')), findsNothing);

    await tester.tap(find.byKey(const Key('fold-Folders')));
    await tester.pump();
    for (final id in ['models', 'chats', 'cache', 'engine']) {
      expect(find.byKey(Key('folder-path-$id')), findsOneWidget);
    }
    expect(find.byKey(const Key('folder-path-main')), findsNothing, reason: 'the main folder is only in the first start');
  });

  testWidgets('the folders are in order: engine, chats, saved chat states, models, then the folders read under models', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byKey(const Key('fold-Folders')));
    await tester.pump();
    final tops = [
      for (final id in ['engine', 'chats', 'cache', 'models']) tester.getTopLeft(find.byKey(Key('folder-path-$id'))).dy,
      tester.getTopLeft(find.text('Also read models from')).dy,
    ];
    expect(tops, [...tops]..sort());
    expect(
      tester.getTopLeft(find.text('Also read models from')).dx,
      greaterThan(tester.getTopLeft(find.text('Models')).dx),
      reason: 'indented under Models',
    );
  });

  testWidgets('the disk-space limit is a field in the saved chat states row and saves the setting', (tester) async {
    await show(tester);
    await tester.tap(find.byKey(const Key('fold-Folders')));
    await tester.pump();
    final field = find.byKey(const Key('state-limit'));
    expect(field, findsOneWidget);
    expect(find.text('Up to'), findsOneWidget);
    // In the same row as the folder's path: level with it, below the chats row and above the models row.
    final y = tester.getCenter(field).dy;
    expect(y, greaterThan(tester.getBottomLeft(find.byKey(const Key('folder-path-chats'))).dy));
    expect(y, lessThan(tester.getTopLeft(find.byKey(const Key('folder-path-models'))).dy));
    expect(find.text('Saved chats'), findsNothing, reason: 'no separate setting with its own name');

    await tester.enterText(field, '25');
    await tester.pump();
    expect(container.read(prefsProvider).stateLimitGiB, 25);
    await tester.enterText(field, '0');
    await tester.pump();
    expect(container.read(prefsProvider).stateLimitGiB, 25, reason: 'a limit of 0 or less is not taken');
    await tester.enterText(field, 'x');
    await tester.pump();
    expect(container.read(prefsProvider).stateLimitGiB, 25, reason: 'nor text that is not a number');
  });

  testWidgets('the folder buttons: Reinstall engine and Change, held while a reply is being written', (tester) async {
    await show(tester);
    await tester.tap(find.byKey(const Key('fold-Folders')));
    await tester.pump();
    expect(find.text('Reinstall engine...'), findsOneWidget);
    expect(find.text('Download engine...'), findsNothing);
    expect(find.text('Move...'), findsNothing);
    expect(find.text('Choose...'), findsNothing);
    const ids = ['engine', 'chats', 'cache', 'models'];
    bool enabled(String id) => tester.widget<AppButton>(find.byKey(Key('folder-move-$id'))).onTap != null;
    for (final id in ids) {
      expect(tester.widget<AppButton>(find.byKey(Key('folder-move-$id'))).label, 'Change...');
      expect(enabled(id), isTrue, reason: '$id: nothing is running');
    }

    final chats = container.read(chatsProvider.notifier);
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    chats.state = chats.state.copyWith(replyingId: () => 'c1');
    await tester.pump();
    for (final id in ids) {
      expect(enabled(id), isFalse, reason: '$id: a reply is being written');
    }

    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    chats.state = chats.state.copyWith(replyingId: () => null);
    await tester.pump();
    for (final id in ids) {
      expect(enabled(id), isTrue, reason: '$id: the reply ended');
    }
  });

  testWidgets('descriptions are tooltips on the names, never text on the page', (tester) async {
    await show(tester);
    await tester.tap(find.byKey(const Key('fold-Folders')));
    await tester.pump();
    for (final description in [
      'A sound when a response finishes.',
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
        chatStoreProvider.overrideWithValue(store),
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

  testWidgets('the sharing choice is one small muted line at the end, its note a tooltip, and it still switches', (
    tester,
  ) async {
    await show(tester);
    final label = tester.widget<Text>(find.text(shareBenchmarksLabel));
    expect((label.style!.fontSize, label.style!.color), (12, tester.element(find.text(shareBenchmarksLabel)).colors.textMuted));
    expect(find.text(shareBenchmarksNote), findsNothing);
    expect(find.byTooltip(shareBenchmarksNote), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('share-check'))).dy,
      greaterThan(tester.getBottomLeft(find.byKey(const Key('about-link'))).dy),
      reason: 'low on the page',
    );
    expect(container.read(prefsProvider).shareBenchmarks, isTrue);
    await tester.tap(find.byKey(const Key('share-check')));
    await tester.pump();
    expect(container.read(prefsProvider).shareBenchmarks, isFalse);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(container.read(prefsProvider).shareBenchmarks, isTrue, reason: 'the small box itself works too');
  });
}
