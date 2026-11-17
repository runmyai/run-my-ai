// The first-start screens: the welcome screen (shown once, with the benchmark sharing choice), the Settings switch for
// the same choice, the chat window without a model (Send off), the bubble at the Store (shown once), and the chat's
// texts before the very first message.
// Run: flutter test test/first_run_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/backend/dummy_backend.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/first_run.dart';
import 'package:runmyai/state/prefs.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/state/today.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/buttons.dart';
import 'package:runmyai/ui/settings/privacy_section.dart';
import 'package:runmyai/ui/shell.dart';
import 'package:runmyai/ui/welcome.dart';

/// Today's date with no clock ticking behind it.
class _Today extends TodayNotifier {
  @override
  DateTime build() => DateTime(2026, 11, 17);
}

/// The stand-in backend with an instant reply (no timers).
class _Backend extends DummyBackend {
  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) => Stream.value(const ReplyText('ok'));
}

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('runmyai-firstrun-');
    // The window plugin is not there in a test: the window is never maximized.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => false,
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// The app's window as it is at the first start (or after it): [seen] are the first-start flags already saved,
  /// [downloaded] the model files the user has.
  Future<ProviderContainer> open(
    WidgetTester tester, {
    Map<String, Object?> seen = const {},
    bool downloaded = true,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = const Size(1600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final storage = Storage(dir);
    storage.writeFirstRun(seen);
    if (downloaded) storage.writeLibrary(const LibraryData(downloaded: {'dummy/test'}, picked: 'dummy/test'));
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
        // A new scope for each start: one kept from the last start would not flush the new container's providers
        // before its frame (it registers with its first container only), as the app's one scope does.
        key: ObjectKey(container),
        container: container,
        child: MaterialApp(
          theme: buildTheme(brightness),
          home: const FirstRunGate(child: Shell()),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    return container;
  }

  const welcome = Key('welcome');
  const sent = {'welcomeShown': true, 'storeHintClosed': true, 'firstMessageSent': true};

  for (final brightness in Brightness.values) {
    testWidgets('the welcome screen shows its text and is gone for good after Get started (${brightness.name})', (
      tester,
    ) async {
      final container = await open(tester, brightness: brightness);
      expect(find.byKey(welcome), findsOneWidget);
      expect(find.text('Welcome to Run My AI'), findsOneWidget);
      expect(find.textContaining('Simple, private, fast and models beyond your memory.'), findsOneWidget);
      expect(find.text('Share benchmark results to help make Run My AI faster'), findsOneWidget);
      expect(find.textContaining('never your chats. You can turn this off anytime in Settings.'), findsOneWidget);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue, reason: 'ticked by default');

      await tester.tap(find.byKey(const Key('welcome-start')));
      await tester.pump();
      expect(find.byKey(welcome), findsNothing);
      expect(container.read(prefsProvider).shareBenchmarks, isTrue);
      expect(Storage(dir).readFirstRun()['welcomeShown'], isTrue);
      expect(Storage(dir).readPrefs().shareBenchmarks, isTrue);

      // The next start: no welcome screen.
      await open(tester, seen: Storage(dir).readFirstRun());
      expect(find.byKey(welcome), findsNothing);
    });
  }

  testWidgets('unticking the box on the welcome screen is saved, and Settings shows and changes the same choice', (
    tester,
  ) async {
    final container = await open(tester);
    await tester.tap(find.byKey(const Key('welcome-share')));
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    expect(container.read(prefsProvider).shareBenchmarks, isFalse);
    expect(Storage(dir).readPrefs().shareBenchmarks, isFalse);

    await tester.tap(find.byKey(const Key('welcome-start')));
    await tester.pump();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: PrivacySection()),
        ),
      ),
    );
    expect(find.text('Share benchmark results'), findsOneWidget);
    expect(tester.widget<OptionPill>(find.byKey(const Key('share-off'))).chosen, isTrue);
    await tester.tap(find.byKey(const Key('share-on')));
    await tester.pump();
    expect(container.read(prefsProvider).shareBenchmarks, isTrue);
    expect(Storage(dir).readPrefs().shareBenchmarks, isTrue);
  });

  testWidgets('with no model the chat says to download one and Send is off', (tester) async {
    await open(tester, seen: sent, downloaded: false);
    expect(find.text('Download a model from the Store to start'), findsNWidgets(2), reason: 'the page and the box');
    expect(find.text('Start a new chat'), findsNothing);
    expect(tester.widget<AppIconButton>(find.byKey(const Key('send'))).onTap, isNull);
  });

  testWidgets('the bubble at the Store shows after the welcome screen and goes for good when closed', (tester) async {
    await open(tester);
    expect(find.text('Download models here'), findsNothing, reason: 'the welcome screen comes first');
    await tester.tap(find.byKey(const Key('welcome-start')));
    await tester.pump();
    expect(find.text('Download models here'), findsOneWidget);

    await tester.tap(find.byKey(const Key('store-hint-close')));
    await tester.pump();
    expect(find.text('Download models here'), findsNothing);
    expect(Storage(dir).readFirstRun()['storeHintClosed'], isTrue);

    await open(tester, seen: {'welcomeShown': true, 'storeHintClosed': true});
    expect(find.text('Download models here'), findsNothing);
  });

  testWidgets('opening the Store also ends the bubble for good', (tester) async {
    await open(tester, seen: {'welcomeShown': true});
    expect(find.text('Download models here'), findsOneWidget);
    await tester.tap(find.byKey(const Key('store')));
    await tester.pump();
    // (The Store's cards are a little too wide in the test font: not what this test is about.)
    tester.takeException();
    expect(find.text('Download models here'), findsNothing);
    expect(Storage(dir).readFirstRun()['storeHintClosed'], isTrue);
  });

  testWidgets(
    'before the first message the box and the page say Send a message to load the model; afterwards the usual',
    (tester) async {
      final container = await open(tester, seen: {'welcomeShown': true, 'storeHintClosed': true});
      // (The box's placeholder is a text too.)
      expect(find.text('Send a message to load Dummy model'), findsNWidgets(2), reason: 'the page and the box');
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
        'Send a message to load Dummy model',
      );
      expect(find.text('Start a new chat'), findsNothing);

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.byKey(const Key('send')));
      await tester.pump();
      expect(container.read(firstRunProvider).firstMessageSent, isTrue);
      expect(Storage(dir).readFirstRun()['firstMessageSent'], isTrue);
      expect(tester.widget<TextField>(find.byType(TextField)).decoration!.hintText, 'Type a message');

      // A new chat, now and at the next start: the usual words.
      container.read(chatsProvider.notifier).newChat();
      await tester.pump();
      expect(find.text('Start a new chat'), findsOneWidget);
      await open(tester, seen: Storage(dir).readFirstRun());
      expect(find.text('Start a new chat'), findsOneWidget);
      expect(find.text('Send a message to load Dummy model'), findsNothing);

      // (The draft's timer ends with the app.)
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
}
