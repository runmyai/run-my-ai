// The first-start screens: the welcome screen (shown once, with the benchmark sharing choice), the Settings switch for
// the same choice, the chat window without a model (Send off), the bubble at the Store (shown once), the chat's
// texts before the very first message, the top bar's feedback button, the one-time star card and the Community page.
// Run: flutter test test/first_run_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/backend/dummy_backend.dart';
import 'package:runmyai/backend/engine_backend.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/first_run.dart';
import 'package:runmyai/state/prefs.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/state/section.dart';
import 'package:runmyai/state/today.dart';
import 'package:runmyai/system/folders.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/buttons.dart';
import 'package:runmyai/ui/community_links.dart';
import 'package:runmyai/ui/settings/privacy_section.dart';
import 'package:runmyai/ui/shell.dart';
import 'package:runmyai/ui/sidebar.dart';
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
  }) => held?.stream ?? Stream.value(const ReplyText('ok'));
}

/// While set, a reply is written until the test closes it.
StreamController<ReplyEvent>? held;

/// The links opened (no browser in a test).
final opened = <String>[];

/// The app's folders in the test's folder.
class _Folders extends FoldersNotifier {
  _Folders(this.main);
  final String main;

  @override
  FolderSet build() => FolderSet(main: main, models: '$main/models', chats: '$main/chats', cache: '$main/cache');
}

void main() {
  late Directory dir;
  setUp(() {
    held = null;
    opened.clear();
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
    bool starForced = false,
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
        starCardForcedProvider.overrideWithValue(starForced),
        linkOpenerProvider.overrideWithValue((url) async {
          opened.add(url);
          return true;
        }),
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
      expect(find.text(shareBenchmarksLabel), findsOneWidget);
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

  testWidgets('the sharing choice is a small, quiet line under Get started', (tester) async {
    await open(tester);
    final context = tester.element(find.byKey(welcome));
    final label = tester.widget<Text>(find.text(shareBenchmarksLabel));
    expect((label.style!.fontSize, label.style!.color), (12, context.colors.textMuted));
    expect(find.text(shareBenchmarksNote), findsOneWidget, reason: 'its note still readable under it');
    expect(tester.getSize(find.byType(Checkbox)).width, lessThanOrEqualTo(16), reason: 'a small box');
    expect(
      tester.getTopLeft(find.byKey(const Key('welcome-share'))).dy,
      greaterThan(tester.getBottomLeft(find.byKey(const Key('welcome-start'))).dy),
      reason: 'low on the screen, under the main button',
    );
  });

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
    expect(find.text(shareBenchmarksLabel), findsOneWidget);
    expect(find.byTooltip(shareBenchmarksNote), findsOneWidget, reason: 'its line is a tooltip in Settings');
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    await tester.tap(find.byKey(const Key('share-check')));
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

  testWidgets('the feedback button in the top bar, next to the bell, opens the feedback form', (tester) async {
    await open(tester, seen: sent);
    final button = find.byKey(const Key('feedback-open'));
    expect(button, findsOneWidget);
    expect(find.byTooltip('Send feedback'), findsOneWidget);
    expect(tester.getCenter(button).dy, tester.getCenter(find.byKey(const Key('bell'))).dy, reason: 'in the same row');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('feedback-title')), findsOneWidget);
    expect(find.byKey(const Key('feedback-message')), findsOneWidget);
    await tester.tap(find.byKey(const Key('feedback-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('feedback-title')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the Community row above Store opens the page: three cards and the six accounts; no icon row', (
    tester,
  ) async {
    final container = await open(tester, seen: sent);
    for (final name in ['star', 'discord', 'youtube', 'x', 'linkedin', 'huggingface', 'sponsor']) {
      expect(find.byKey(Key('community-icon-$name')), findsNothing, reason: name);
    }
    final row = find.byKey(const Key('community'));
    expect(tester.getTopLeft(row).dy, lessThan(tester.getTopLeft(find.byKey(const Key('store'))).dy));
    await tester.tap(row);
    await tester.pump();
    expect(container.read(sectionProvider), Section.community);
    expect(find.text("Run My AI is free and open source. Here's how to follow along and help."), findsOneWidget);
    final boxes = [
      for (final id in ['star', 'discord', 'sponsor']) find.byKey(Key('community-card-$id-box')),
    ];
    for (final box in boxes) {
      expect(box, findsOneWidget);
    }
    expect(tester.getSize(boxes[0]), tester.getSize(boxes[1]), reason: 'equal size');
    expect(tester.getSize(boxes[1]), tester.getSize(boxes[2]));
    expect(tester.getTopLeft(boxes[0]).dy, tester.getTopLeft(boxes[2]).dy, reason: 'side by side');
    for (final (title, button, url) in [
      ('Star us on GitHub', 'star', starUsUrl),
      ('Join the Discord', 'discord', discordUrl),
      ('Sponsor', 'sponsor', sponsorUrl),
    ]) {
      expect(find.text(title), findsWidgets);
      await tester.tap(find.byKey(Key('community-card-$button')));
      expect(opened.last, url);
    }
    expect(find.text('Follow us'), findsOneWidget);
    for (final (name, url) in communityLinks) {
      await tester.tap(find.byKey(Key('follow-$name')));
      expect(opened.last, url, reason: name);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the Community page stacks its cards on a narrow window', (tester) async {
    final container = await open(tester, seen: sent);
    tester.view.physicalSize = const Size(900, 900);
    container.read(sectionProvider.notifier).select(Section.community);
    await tester.pump();
    final star = find.byKey(const Key('community-card-star-box')),
        sponsor = find.byKey(const Key('community-card-sponsor-box'));
    expect(tester.getTopLeft(sponsor).dy, greaterThan(tester.getBottomLeft(star).dy));
    expect(tester.getSize(star).width, tester.getSize(sponsor).width);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a settings file from an older version with the line under the message box still reads', (tester) async {
    File('${dir.path}/settings.json').writeAsStringSync('{"bell": false, "communityStep": 1}');
    expect(Storage(dir).readPrefs().bell, isFalse);
    final container = await open(tester, seen: sent);
    expect(container.read(prefsProvider).bell, isFalse);
    expect(find.byKey(const Key('line-star')), findsNothing);
    expect(find.byKey(const Key('line-discord')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  group('the star card', () {
    const seen = {'welcomeShown': true, 'storeHintClosed': true, 'firstMessageSent': true};
    final card = find.byKey(const Key('star-card'));

    Future<void> send(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.tap(find.byKey(const Key('send')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    // (The app ends here: the pending timers go with the widgets.)
    Future<void> end(WidgetTester tester) => tester.pumpWidget(const SizedBox());

    testWidgets('it shows after the third finished reply, not before and not while a reply is written', (tester) async {
      await open(tester, seen: seen);
      await send(tester, 'one');
      await send(tester, 'two');
      expect(Storage(dir).readPrefs().starReplies, 2);
      expect(card, findsNothing);

      held = StreamController<ReplyEvent>();
      await send(tester, 'three');
      expect(card, findsNothing, reason: 'the third reply is still being written');
      held!.add(const ReplyText('ok'));
      await held!.close();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(Storage(dir).readPrefs().starReplies, 3);
      expect(card, findsOneWidget);
      expect(find.text(starCardText), findsOneWidget);
      expect(
        tester.getBottomLeft(card).dy,
        lessThan(tester.getTopLeft(find.byType(TextField)).dy),
        reason: 'it never covers the message box',
      );

      held = StreamController<ReplyEvent>();
      await send(tester, 'four');
      expect(card, findsNothing, reason: 'hidden while the next reply is written');
      await held!.close();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(card, findsOneWidget, reason: 'back once it finished');
      expect(Storage(dir).readPrefs().starReplies, 3, reason: 'the count stops at three');
      await end(tester);

      await open(tester, seen: seen);
      expect(card, findsOneWidget, reason: 'not handled yet: it is still there after a restart');
      await end(tester);
    });

    for (final button in ['star-card-star', 'star-card-later']) {
      testWidgets('$button closes it for good, also after a restart', (tester) async {
        Storage(dir).writePrefs(const PrefsData(starReplies: 3));
        await open(tester, seen: seen);
        expect(card, findsOneWidget);
        await tester.tap(find.byKey(Key(button)));
        await tester.pump();
        expect(card, findsNothing);
        expect(opened, button == 'star-card-star' ? [starUsUrl] : isEmpty);
        expect(Storage(dir).readPrefs().starCardClosed, isTrue);
        await send(tester, 'more');
        expect(card, findsNothing);
        await end(tester);

        await open(tester, seen: seen);
        expect(card, findsNothing);
        await end(tester);
      });
    }

    testWidgets('the design switch shows it at once whatever was saved; a button closes it for this session only', (
      tester,
    ) async {
      Storage(dir).writePrefs(const PrefsData(starCardClosed: true));
      await open(tester, seen: seen, starForced: true);
      expect(card, findsOneWidget);
      await tester.tap(find.byKey(const Key('star-card-later')));
      await tester.pump();
      expect(card, findsNothing);
      expect(Storage(dir).readPrefs().starReplies, 0, reason: 'nothing counted or saved by it');
      await end(tester);

      Storage(dir).writePrefs(const PrefsData());
      await open(tester, seen: seen, starForced: true);
      expect(card, findsOneWidget);
      await tester.tap(find.byKey(const Key('star-card-later')));
      await tester.pump();
      expect(Storage(dir).readPrefs().starCardClosed, isFalse);
      await end(tester);
      await open(tester, seen: seen, starForced: true);
      expect(card, findsOneWidget, reason: 'again at the next start');
      await end(tester);
    });
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

  /// The first start with the real engine's backend and no engine anywhere: the gate over a page with the Store's
  /// bubble only (the engine step looks for its release and never finds it in a test, which is all it needs here).
  Future<ProviderContainer> engineStart(WidgetTester tester, {Map<String, Object?> seen = const {}}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final storage = Storage(dir)..writeFirstRun(seen);
    final container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(storage),
        backendProvider.overrideWithValue(EngineBackend(storage)),
        foldersProvider.overrideWith(() => _Folders('${dir.path}/main')),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        key: ObjectKey(container),
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: const FirstRunGate(
            child: Scaffold(body: Column(children: [StoreHint()])),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return container;
  }

  const setup = Key('engine-setup'), hint = Key('store-hint');

  testWidgets('first start: welcome, then the engine step that cannot be closed, then the main window and the bubble', (
    tester,
  ) async {
    final container = await engineStart(tester);
    expect(find.byKey(welcome), findsOneWidget);
    expect(find.byKey(hint), findsNothing);
    expect(container.read(firstRunProvider).setupOpen, isTrue);
    container.read(sectionProvider.notifier).select(Section.settings);

    await tester.tap(find.byKey(const Key('welcome-start')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(welcome), findsNothing);
    expect(find.byKey(setup), findsOneWidget);
    expect(find.byKey(hint), findsNothing, reason: 'not while the engine step is open');
    expect(find.byKey(const Key('engine-later')), findsNothing);

    // Escape does not close it.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(setup), findsOneWidget);

    // Folders: closed at first; open, the main folder and the engine, with no engine download inside the step.
    expect(find.byKey(const Key('folder-path-main')), findsNothing);
    await tester.tap(find.byKey(const Key('engine-folders')));
    await tester.pump();
    expect(find.text('${dir.path}/main'), findsOneWidget);
    expect(find.byKey(const Key('folder-path-models')), findsOneWidget);
    expect(find.byKey(const Key('folder-path-chats')), findsOneWidget);
    expect(find.byKey(const Key('folder-path-cache')), findsOneWidget);
    expect(find.byKey(const Key('folder-path-engine')), findsOneWidget);
    expect(find.byKey(const Key('engine-download-open')), findsNothing);
    expect(find.byKey(const Key('folder-add-read')), findsNothing);

    // The user's own engine folder chosen: the step ends, the chat section shows, then the bubble.
    final own = Directory('${dir.path}/own')..createSync();
    File('${own.path}/${Platform.isWindows ? 'llama-server.exe' : 'llama-server'}').writeAsStringSync('');
    container.read(prefsProvider.notifier).setEngineFolder(own.path);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(setup), findsNothing);
    expect(container.read(sectionProvider), Section.chat);
    expect(container.read(firstRunProvider).setupOpen, isFalse);
    expect(find.byKey(hint), findsOneWidget);
  });

  testWidgets('a start after the welcome screen with no engine yet opens the engine step again', (tester) async {
    await engineStart(tester, seen: {'welcomeShown': true});
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(welcome), findsNothing);
    expect(find.byKey(setup), findsOneWidget);
    expect(find.byKey(hint), findsNothing);
  });

  testWidgets('a start with the engine in place goes straight to the main window', (tester) async {
    File('${dir.path}/main/engine/${Platform.isWindows ? 'llama-server.exe' : 'llama-server'}')
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    final container = await engineStart(tester, seen: {'welcomeShown': true});
    expect(container.read(firstRunProvider).setupOpen, isFalse);
    expect(find.byKey(setup), findsNothing);
    expect(find.byKey(hint), findsOneWidget);
  });
}
