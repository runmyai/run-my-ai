// The Store's model cards (lib/ui/pages/store_page.dart): no description line under a model's name, and a closed
// "Details" drop-down with the model's labelled lines in order, Thinking written from the model's setting.
// Run: flutter test test/store_details_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/dummy_backend.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/system/folders.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/pages/store_page.dart';

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
    dir = Directory.systemTemp.createTempSync('runmyai-store-');
    store = await ChatStore.open(dir);
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        chatStoreProvider.overrideWithValue(store),
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
    // The test font is wider than the app's, so a download button's row overflows its card by a few pixels here.
    final onError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (!details.exceptionAsString().contains('overflowed')) onError?.call(details);
    };
    addTearDown(() => FlutterError.onError = onError);
    await container.read(catalogProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: StorePage()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a card has no description line and its Details drop-down starts closed', (tester) async {
    await show(tester);
    expect(find.textContaining('Placeholder'), findsNothing);
    expect(find.byKey(const Key('fold-Details')), findsNWidgets(3));
    expect(find.textContaining('Made by:'), findsNothing, reason: 'closed');
    await tester.tap(find.byKey(const Key('fold-Details')).first);
    await tester.pump();
    expect(find.textContaining('Made by:'), findsOneWidget);
  });

  testWidgets('Details list the lines in order, with Thinking from the model setting', (tester) async {
    await show(tester);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const Key('fold-Details')).at(i));
      await tester.pump();
    }
    const labels = ['Made by:', 'Country:', 'Released:', 'Type:', 'Thinking:', 'Input:', 'Output:', 'Max context:'];
    final tops = [for (final l in labels) tester.getTopLeft(find.textContaining(l).first).dy];
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], greaterThan(tops[i - 1]), reason: '${labels[i]} comes after ${labels[i - 1]}');
    }
    expect(find.textContaining('Can be toggled on or off'), findsOneWidget, reason: 'Qwen');
    expect(find.textContaining('Thinking: Always on'), findsOneWidget, reason: 'Flint');
    expect(find.textContaining('Thinking: None'), findsOneWidget, reason: 'the stand-in');
    expect(find.textContaining('Max context: 262k tokens'), findsNWidgets(2));
  });
}
