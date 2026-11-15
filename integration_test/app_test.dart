// Clicks through the real app (Store, downloads, picker, chat, chat list, Stop, theme, sidebar, window buttons, saving,
// search, the chat menu: rename / pin / delete) on this computer.
// Run: flutter test integration_test/app_test.dart -d linux [--dart-define=SHOTS=<folder for screenshots>]
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:runmyai/backend/dummy_backend.dart';
import 'package:runmyai/data/chat_db.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/dev/screenshot.dart';
import 'package:runmyai/main.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/drafts.dart';
import 'package:runmyai/state/folds.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/motion.dart';
import 'package:runmyai/state/prefs.dart';
import 'package:runmyai/state/search.dart';
import 'package:runmyai/state/section.dart';
import 'package:runmyai/state/today.dart';
import 'package:runmyai/system/chime.dart';
import 'package:runmyai/ui/chat_list.dart';
import 'package:runmyai/ui/folded_text.dart';
import 'package:runmyai/ui/live_reply.dart';
import 'package:runmyai/ui/pages/chat_page.dart';
import 'package:runmyai/ui/shell.dart';
import 'package:runmyai/window/app_window.dart';
import 'package:window_manager/window_manager.dart';

const shots = String.fromEnvironment('SHOTS');

Future<void> shot(String name) async {
  if (shots.isNotEmpty) await saveScreenshot('$shots/$name.png');
}

/// Lets real time pass (the dummy downloads and replies run on real timers).
Future<void> wait(WidgetTester tester, int ms) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  await tester.pump();
}

/// Waits until the search for the text in the box has answered.
Future<void> searchDone(WidgetTester tester) async {
  await wait(tester, 50);
  await waitUntil(tester, () => !container(tester).read(searchResultsProvider).pending, timeoutMs: 5000);
  await wait(tester, 100);
}

Future<void> waitUntil(WidgetTester tester, bool Function() done, {int timeoutMs = 30000}) async {
  final end = DateTime.now().add(Duration(milliseconds: timeoutMs));
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw TestFailure('timed out');
    await wait(tester, 100);
  }
}

ProviderContainer container(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(Shell)));

ChatStore? _store;

/// The folders of finished tests that are still to be deleted. Windows cannot delete a folder while the chats database
/// in it is open (the store stays open until the next test's app closes it), so there a folder is deleted once the
/// store has been closed: by the next app(), or at the end of the run. Elsewhere it is deleted at once.
final _finishedDirs = <Directory>[];

void deleteTestDir(Directory dir) {
  if (Platform.isWindows) {
    _finishedDirs.add(dir);
  } else {
    dir.deleteSync(recursive: true);
  }
}

void _deleteFinishedDirs() {
  for (final dir in _finishedDirs) {
    dir.deleteSync(recursive: true);
  }
  _finishedDirs.clear();
}

/// The app on [dir], with its own chats database worker (the one before is closed first, as when the app quits).
/// The reply-finished sound is counted, not played.
Future<Widget> app(Directory dir, DummyBackend backend) async {
  await _store?.close();
  _deleteFinishedDirs();
  _store = await ChatStore.open(dir);
  return appWith(storage: Storage(dir), chatStore: _store!, backend: backend, chime: CountingChime.new);
}

/// Counts the reply-finished sounds instead of playing them.
class CountingChime extends Chime {
  CountingChime(super.ref);

  int rings = 0;

  @override
  Future<void> play() async => rings++;
}

/// Waits for the app's saves, then reads the chats database the way the app will next time it starts.
Future<T> saved<T>(Directory dir, T Function(ChatDb db) read) async {
  await _store!.flush();
  final db = ChatDb.open('${dir.path}/chats.db');
  try {
    return read(db);
  } finally {
    db.close();
  }
}

/// A chat saved the way older versions of the app saved them (one file each); the app moves them into its database.
void writeOldChat(Directory dir, Chat chat) {
  Directory('${dir.path}/chats').createSync(recursive: true);
  File('${dir.path}/chats/${chat.id}.json').writeAsStringSync(jsonEncode(chat.toJson()));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tearDownAll(() async {
    await _store?.close();
    _store = null;
    _deleteFinishedDirs();
  });

  testWidgets('store, downloads, picker, chat, chat list, stop, saving', (tester) async {
    final dir = Directory.systemTemp.createTempSync('runmyai-test-');
    // Replies at 22 tokens a second: slow enough for the test to see them while they are still being written.
    final backend = DummyBackend(
        downloadTime: const Duration(seconds: 3),
        tokensPerSecond: 22,
        fixedReply: DummyBackend.replyText);
    Storage(dir).writePrefs(const PrefsData(theme: 'light'));
    await setUpWindow(Storage(dir));
    await tester.pumpWidget(await app(dir, backend));
    await wait(tester, 1500);

    // Nothing downloaded: the picker points to the Store, and sending does nothing.
    expect(find.text('Get a model from the Store'), findsOneWidget);
    expect(find.text('Download a model from the Store to start chatting.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.byKey(const Key('send')));
    await wait(tester, 300);
    expect(container(tester).read(chatsProvider).chats, isEmpty);
    await shot('01-chat-no-model-light');

    // The Store: two labs, three files.
    await tester.tap(find.byKey(const Key('store')));
    await wait(tester, 300);
    expect(find.text('Qwen'), findsOneWidget);
    expect(find.text('Recursive'), findsOneWidget);
    expect(find.text('Download'), findsNWidgets(4));
    await shot('02-store-light');

    // Download Flint, then Qwen ISTA IQ3_S; start Qwen UD-Q4_K_XL and cancel it.
    await tester.tap(find.text('Download').at(2));
    await tester.tap(find.text('Download').first);
    await wait(tester, 800);
    expect(find.text('Cancel'), findsNWidgets(2));
    await shot('03-store-downloading-light');
    await tester.tap(find.text('Download').first);
    await wait(tester, 300);
    await tester.tap(find.text('Cancel').at(1)); // rows: Qwen IQ3_S, Qwen UD-Q4_K_XL, Flint
    await wait(tester, 300);
    await waitUntil(tester, () => find.text('Downloaded').evaluate().length == 2);
    expect(find.text('Download'), findsNWidgets(2));
    final lib = container(tester).read(libraryProvider);
    expect(lib.downloaded, {'flint-40b/UD-Q4_K_XL', 'qwen3.8-flash-next/ISTA-IQ3_S'});
    expect(lib.picked, 'flint-40b/UD-Q4_K_XL', reason: 'the first finished download is picked');
    await shot('04-store-downloaded-light');

    // A chat: the reply types out, Stop shows meanwhile, then the full reply.
    await tester.tap(find.byKey(const Key('new-chat')));
    await wait(tester, 300);
    expect(find.textContaining('Flint 40B', findRichText: true), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'What is the capital of France?');
    await tester.tap(find.byKey(const Key('send')));
    await wait(tester, 700); // well before the reply ends (about 2.5 s)
    expect(find.byKey(const Key('stop')), findsOneWidget);
    await shot('05-chat-replying-light');
    await waitUntil(tester, () => find.byKey(const Key('send')).evaluate().isNotEmpty);
    // The last words come out and fade in a moment after the reply ends; then it is the normal message.
    await waitUntil(tester, () => find.text(DummyBackend.replyText).evaluate().isNotEmpty, timeoutMs: 3000);
    await shot('06-chat-done-light');

    // A second chat sent with Enter; switching away does not stop its reply.
    await tester.tap(find.byKey(const Key('new-chat')));
    await wait(tester, 300);
    await tester.tap(find.byType(TextField));
    await wait(tester, 100);
    await tester.enterText(find.byType(TextField), 'Second chat');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await wait(tester, 400);
    expect(find.byKey(const Key('stop')), findsOneWidget);
    await tester.tap(find.text('What is the capital of France?'));
    await wait(tester, 300);
    expect(find.text('Wait for the reply in "Second chat" to finish.'), findsOneWidget);
    await shot('07-other-chat-waits-light');
    await waitUntil(tester, () => find.byKey(const Key('box-hint')).evaluate().isEmpty);
    // The reply was written while another chat was open, and saved.
    final second = container(tester).read(chatsProvider).chats.firstWhere((c) => c.title == 'Second chat');
    expect((await saved(dir, (db) => db.messages(second.id))).last.text, DummyBackend.replyText);

    // Stop keeps the words so far and nothing more arrives.
    await tester.tap(find.text('Second chat'));
    await wait(tester, 300);
    await tester.enterText(find.byType(TextField), 'Stop test');
    await tester.tap(find.byKey(const Key('send')));
    await wait(tester, 600);
    await tester.tap(find.byKey(const Key('stop')));
    await wait(tester, 100);
    String lastReply() => container(tester).read(chatsProvider).open!.messages.last.text;
    final partial = lastReply();
    expect(partial, isNotEmpty);
    expect(partial.length, lessThan(DummyBackend.replyText.length));
    await wait(tester, 1000);
    expect(lastReply(), partial);
    expect(container(tester).read(chatsProvider).replyingId, isNull);

    // "story" in a message: the stand-in writes its long story. The test speed control (bottom right) sets how
    // fast, also while it is being written; at full speed the whole story comes out and is saved.
    expect(find.byKey(const Key('dev-speed')), findsOneWidget);
    // (After Stop was clicked, the message box needs a click before typing.)
    await tester.tap(find.byType(TextField));
    await wait(tester, 200);
    await tester.enterText(find.byType(TextField), 'Tell me a story');
    await tester.tap(find.byKey(const Key('send')));
    await wait(tester, 1500);
    expect(lastReply(), startsWith('The Clockmaker of Low Harbour'));
    await shot('07b-story-writing-light');
    backend.speed.value = 5000;
    await waitUntil(tester, () => container(tester).read(chatsProvider).replyingId == null, timeoutMs: 15000);
    final story = (await DummyBackend.story()).trim();
    expect(lastReply(), story);
    expect((await saved(dir, (db) => db.messages(container(tester).read(chatsProvider).openId!))).last.text, story);
    backend.speed.value = 22;

    // The picker lists only downloaded models; pick Qwen.
    await tester.tap(find.byKey(const Key('picker')));
    await wait(tester, 400);
    await shot('08-picker-open-light');
    expect(find.textContaining('UD-Q4_K_XL', findRichText: true), findsNWidgets(2)); // the button + Flint's line
    await tester.tap(find.textContaining('Qwen3.8 Flash Next', findRichText: true));
    await wait(tester, 300);
    expect(container(tester).read(libraryProvider).picked, 'qwen3.8-flash-next/ISTA-IQ3_S');

    // Deleting the picked model picks the other one.
    await tester.tap(find.byKey(const Key('store')));
    await wait(tester, 300);
    await tester.tap(find.text('Delete').first); // rows: Qwen IQ3_S (picked), Flint
    await wait(tester, 300);
    expect(container(tester).read(libraryProvider).downloaded, {'flint-40b/UD-Q4_K_XL'});
    expect(container(tester).read(libraryProvider).picked, 'flint-40b/UD-Q4_K_XL');

    // Settings → Theme switches light <-> dark; the sidebar hides to a narrow bar of icons and comes back.
    Brightness brightness() => Theme.of(tester.element(find.byType(Shell))).brightness;
    expect(brightness(), Brightness.light);
    await tester.tap(find.text('Settings').first);
    await wait(tester, 300);
    await tester.tap(find.byKey(const Key('theme-dark')));
    await wait(tester, 400);
    expect(brightness(), Brightness.dark);
    await tester.tap(find.byKey(const Key('sidebar-toggle')));
    await wait(tester, 300);
    expect(find.text('Second chat'), findsNothing, reason: 'the chat list is hidden');
    await tester.tap(find.byKey(const Key('new-chat')));
    await wait(tester, 400);
    expect(find.text('Start a new chat'), findsOneWidget);
    await shot('11-sidebar-hidden-dark');
    container(tester).read(prefsProvider.notifier).setTheme(ThemeMode.light);
    // (The switch animates: a frame to start it, then its end.)
    await wait(tester, 50);
    await wait(tester, 400);
    expect(brightness(), Brightness.light);
    await shot('12-sidebar-hidden-light');
    container(tester).read(prefsProvider.notifier).setTheme(ThemeMode.dark);
    await tester.tap(find.byKey(const Key('sidebar-toggle')));
    await wait(tester, 400);
    expect(find.text('Second chat'), findsOneWidget);
    final prefs = Storage(dir).readPrefs();
    expect((prefs.theme, prefs.sidebarHidden), ('dark', false));

    // Our own window buttons: maximize, then restore; the window's size and maximized state are saved.
    expect(find.byKey(const Key('window-minimize')), findsOneWidget);
    expect(find.byKey(const Key('window-close')), findsOneWidget);
    bool maximized() => container(tester).read(windowMaximizedProvider);
    await windowManager.setSize(const Size(1000, 700));
    await wait(tester, 1200);
    var window = Storage(dir).readWindow()!;
    expect((window.width, window.height, window.maximized), (1000.0, 700.0, false));
    await tester.tap(find.byKey(const Key('window-maximize')));
    await waitUntil(tester, maximized, timeoutMs: 5000);
    await wait(tester, 1200);
    expect(find.byTooltip('Restore'), findsOneWidget);
    window = Storage(dir).readWindow()!;
    expect((window.width, window.height, window.maximized), (1000.0, 700.0, true), reason: 'the normal size is kept while maximized');
    await shot('13-maximized-dark');
    await tester.tap(find.byKey(const Key('window-maximize')));
    await waitUntil(tester, () => !maximized(), timeoutMs: 5000);
    await wait(tester, 1200);
    expect(find.byTooltip('Maximize'), findsOneWidget);
    expect(Storage(dir).readWindow()!.maximized, false);

    // Saved: the app opened again on the same folder has the chats, downloads, pick and the dark theme.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(await app(dir, backend));
    await wait(tester, 1500);
    expect(brightness(), Brightness.dark);
    final again = container(tester);
    expect([for (final c in again.read(chatsProvider).chats) c.title], ['Second chat', 'What is the capital of France?']);
    expect((await _store!.messages(again.read(chatsProvider).chats.first.id)).map((m) => m.role),
        [Role.user, Role.assistant, Role.user, Role.assistant, Role.user, Role.assistant]);
    expect(again.read(libraryProvider).downloaded, {'flint-40b/UD-Q4_K_XL'});
    expect(again.read(libraryProvider).picked, 'flint-40b/UD-Q4_K_XL');
    await tester.tap(find.text('What is the capital of France?'));
    await wait(tester, 400);
    await shot('09-chat-dark');
    await tester.tap(find.byKey(const Key('store')));
    await wait(tester, 400);
    await shot('10-store-dark');

    deleteTestDir(dir);
  });

  testWidgets('search: results, the line under each title, jumping to matches, closing', (tester) async {
    final dir = Directory.systemTemp.createTempSync('runmyai-test-');
    final storage = Storage(dir)..writePrefs(const PrefsData(theme: 'light'));
    var time = DateTime(2026, 10, 20);
    void save(String id, String title, List<String> texts) {
      time = time.add(const Duration(hours: 1));
      writeOldChat(dir, Chat(id: id, title: title, createdAt: time, updatedAt: time, messages: [
        for (var i = 0; i < texts.length; i++) ChatMessage(i.isEven ? Role.user : Role.assistant, texts[i]),
      ]));
    }

    // A long chat with "zebra" near its start (far above what the window shows) and near its end.
    const filler = 'Some long text about many things, written to make this chat long enough to scroll a lot. '
        'It goes on for a few lines, so each message takes up real room on the screen and the list is tall.';
    save('long', 'Holiday notes', [
      for (var i = 0; i < 60; i++)
        i == 4 ? 'We saw the blue zebra crossing near the lake. $filler' : i == 50 ? 'Another zebra today. $filler' : filler,
    ]);
    save('python', 'Python error help', ['The file Harin sent is broken', 'Send it again.']);
    save('trip', 'Trip planning', ['Who is coming?', 'As Harin is arriving on Friday, book the room.']);
    save('recipes', 'Weekend recipes', ['Harin is vegetarian, so no meat please.', 'Noted.']);
    save('other', 'Nothing here', ['Just a chat.', 'Yes.']);

    await setUpWindow(storage);
    await tester.pumpWidget(await app(dir, DummyBackend()));
    await wait(tester, 1500);

    // The search button turns New chat into the search box.
    await tester.tap(find.byKey(const Key('search')));
    await wait(tester, 300);
    expect(find.byKey(const Key('new-chat')), findsNothing);
    expect(find.byKey(const Key('search-box')), findsOneWidget);

    // "Harin is": the two exact matches (newest first), then the one with the words apart; the others not at all.
    await tester.enterText(find.byKey(const Key('search-box')), 'Harin is');
    await searchDone(tester);
    double top(String id) => tester.getTopLeft(find.byKey(Key('hit-$id'))).dy;
    expect(top('recipes'), lessThan(top('trip')));
    expect(top('trip'), lessThan(top('python')));
    expect(find.byKey(const Key('hit-long')), findsNothing);
    expect(find.byKey(const Key('hit-other')), findsNothing);
    expect(find.textContaining('AI: As Harin is arriving', findRichText: true), findsOneWidget);
    expect(find.textContaining('You: Harin is vegetarian', findRichText: true), findsOneWidget);
    await shot('14-search-results-light');

    // Opening a result highlights the match and counts it.
    await tester.tap(find.byKey(const Key('hit-trip')));
    await wait(tester, 400);
    expect(find.byKey(const Key('find-count')), findsOneWidget);
    expect(find.text('1 of 1'), findsOneWidget);
    await shot('15-search-opened-light');

    // A match far up a long chat: the chat scrolls to it; the arrows step to the next one and round again.
    final chatArea = tester.getRect(find.byType(ChatPage));
    bool onScreen(String text) {
      final r = tester.getRect(find.textContaining(text).first);
      return r.top >= chatArea.top + 48 && r.top <= chatArea.bottom - 120;
    }

    // Opening a chat puts the cursor in its message box; click back into the search box first.
    await tester.tap(find.byKey(const Key('search-box')));
    await wait(tester, 200);
    // A word still being typed matches the words that start with it; followed by a space, only the whole word.
    await tester.enterText(find.byKey(const Key('search-box')), 'zeb');
    await searchDone(tester);
    expect(find.byKey(const Key('hit-long')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('search-box')), 'zeb ');
    await searchDone(tester);
    expect(find.byKey(const Key('no-results')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('search-box')), 'zebra');
    await searchDone(tester);
    expect(find.textContaining('You: We saw the blue zebra crossing', findRichText: true), findsOneWidget);
    await tester.tap(find.byKey(const Key('hit-long')));
    await wait(tester, 800);
    expect(find.text('1 of 2'), findsOneWidget);
    expect(onScreen('blue zebra crossing'), isTrue, reason: 'the first match is on screen');
    await shot('16-search-jump-light');
    // The arrows skid to the next match rather than jump: a moment after the click the list is still moving.
    ScrollPosition chatScroll() =>
        tester.state<ScrollableState>(find.descendant(of: find.byType(ChatPage), matching: find.byType(Scrollable)).first).position;
    // (The test window draws a frame only when asked: give the skid its frames.)
    Future<void> skid() async {
      for (var i = 0; i < 60; i++) {
        await wait(tester, 16);
      }
    }

    await tester.tap(find.byKey(const Key('find-next')));
    await wait(tester, 60);
    final midway = chatScroll().pixels;
    await skid();
    expect(chatScroll().pixels, isNot(midway), reason: 'still sliding 60 ms after the click');
    expect(find.text('2 of 2'), findsOneWidget);
    expect(onScreen('Another zebra today'), isTrue, reason: 'the second match is on screen');
    await tester.tap(find.byKey(const Key('find-next')));
    await skid();
    expect(find.text('1 of 2'), findsOneWidget);
    expect(onScreen('blue zebra crossing'), isTrue, reason: 'back round to the first match');
    await tester.tap(find.byKey(const Key('find-previous')));
    await skid();
    expect(find.text('2 of 2'), findsOneWidget);
    await tester.tap(find.byKey(const Key('find-close')));
    await wait(tester, 300);
    expect(find.byKey(const Key('find-count')), findsNothing);

    // Nothing found; then Esc closes the search and New chat comes back.
    await tester.tap(find.byKey(const Key('search-box')));
    await wait(tester, 200);
    await tester.enterText(find.byKey(const Key('search-box')), 'qwertyuiop');
    await searchDone(tester);
    expect(find.byKey(const Key('no-results')), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-box')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await wait(tester, 300);
    expect(find.byKey(const Key('search-box')), findsNothing);
    expect(find.byKey(const Key('new-chat')), findsOneWidget);
    expect(container(tester).read(searchProvider).text, isEmpty);

    // Dark theme, for the look.
    await tester.tap(find.byKey(const Key('search')));
    await wait(tester, 300);
    await tester.enterText(find.byKey(const Key('search-box')), 'Harin is');
    await searchDone(tester);
    container(tester).read(prefsProvider.notifier).setTheme(ThemeMode.dark);
    await wait(tester, 400);
    await tester.tap(find.byKey(const Key('hit-recipes')));
    await wait(tester, 400);
    await shot('17-search-dark');

    deleteTestDir(dir);
  });

  testWidgets('chat menu: rename, pin, drag the pinned, unpin, delete with and without the box', (tester) async {
    final dir = Directory.systemTemp.createTempSync('runmyai-test-');
    final storage = Storage(dir)..writePrefs(const PrefsData(theme: 'light'));
    final names = {'a': 'Alpha', 'b': 'Bravo', 'c': 'Charlie', 'd': 'Delta', 'e': 'Echo', 'f': 'Foxtrot'};
    // Alpha and Bravo today, Charlie yesterday, Delta and Echo three days ago, Foxtrot last year.
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day, 12);
    final times = {
      'a': now.subtract(const Duration(seconds: 2)),
      'b': now.subtract(const Duration(seconds: 3)),
      'c': DateTime(day.year, day.month, day.day - 1, 12),
      'd': DateTime(day.year, day.month, day.day - 3, 12),
      'e': DateTime(day.year, day.month, day.day - 3, 11),
      'f': DateTime(day.year - 1, day.month, day.day - 3, 12),
    };
    for (final MapEntry(key: id, value: title) in names.entries) {
      final time = times[id]!;
      writeOldChat(dir, Chat(id: id, title: title, createdAt: time, updatedAt: time, messages: const [
        ChatMessage(Role.user, 'Hello'),
        ChatMessage(Role.assistant, 'Hi there.'),
      ]));
    }
    File('${dir.path}/pins.json').writeAsStringSync('{"pinned": []}');
    await setUpWindow(storage);
    await tester.pumpWidget(await app(dir, DummyBackend()));
    await wait(tester, 1500);
    expect(Directory('${dir.path}/chats').existsSync(), isFalse, reason: 'the old chat files were moved into the database');
    expect(File('${dir.path}/pins.json').existsSync(), isFalse);

    Future<void> rightClick(String text) async {
      await tester.tap(find.text(text).first, kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await wait(tester, 300);
    }

    Future<void> menu(String item) async {
      await tester.tap(find.byKey(Key('menu-$item')));
      await wait(tester, 400);
    }

    // A pinned chat shows twice (under Pinned and under its day): the first is the one higher up.
    double top(String text) => tester.getTopLeft(find.text(text).first).dy;

    // Headings by the day each chat was last used: Today, Yesterday, then the date (the year only before this year).
    final today = DateTime(now.year, now.month, now.day);
    final threeDays = dayLabel(times['d']!, today);
    final lastYear = dayLabel(times['f']!, today);
    expect(threeDays, matches(RegExp(r'^\d{1,2} [A-Z][a-z]{2}$')));
    expect(lastYear, matches(RegExp(r'^\d{1,2} [A-Z][a-z]{2} \d{4}$')));
    final order = ['Today', 'Alpha', 'Bravo', 'Yesterday', 'Charlie', threeDays, 'Delta', 'Echo', lastYear, 'Foxtrot'];
    for (var i = 1; i < order.length; i++) {
      expect(top(order[i - 1]), lessThan(top(order[i])), reason: '${order[i - 1]} above ${order[i]}');
    }
    await shot('17b-date-headings-light');

    // Hovering a chat shows its "⋯" button, which opens the menu.
    expect(find.byKey(const Key('chat-menu-b')), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Bravo')));
    await wait(tester, 200);
    expect(find.byKey(const Key('chat-menu-b')), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-menu-b')));
    await wait(tester, 400);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Pin'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await shot('18-chat-menu-light');

    // Rename: Enter saves (and it is saved to the chat's file); Esc cancels.
    await menu('rename');
    expect(find.byKey(const Key('rename-box')), findsOneWidget);
    await shot('19-rename-light');
    await tester.enterText(find.byKey(const Key('rename-box')), 'Bravo renamed');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await wait(tester, 300);
    expect(find.text('Bravo renamed'), findsOneWidget);
    expect(await saved(dir, (db) => db.chats().firstWhere((c) => c.id == 'b').title), 'Bravo renamed');
    await rightClick('Bravo renamed');
    await menu('rename');
    await tester.enterText(find.byKey(const Key('rename-box')), 'not this');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await wait(tester, 300);
    expect(find.text('Bravo renamed'), findsOneWidget);
    expect(find.text('not this'), findsNothing);

    // Pin Delta, then Bravo: a Pinned group on top, in the order pinned. Pinned is a shortcut: each also stays
    // under its day, with a small pin after its title there.
    await rightClick('Delta');
    await menu('pin');
    await rightClick('Bravo renamed');
    await menu('pin');
    expect(find.text('Pinned'), findsOneWidget);
    expect(find.text('Delta'), findsNWidgets(2));
    expect(find.text('Bravo renamed'), findsNWidgets(2));
    expect(find.byKey(const Key('pin-mark-d')), findsOneWidget);
    expect(find.byKey(const Key('pin-mark-b')), findsOneWidget);
    expect(find.byKey(const Key('pin-mark-a')), findsNothing);
    expect(top(threeDays), lessThan(tester.getTopLeft(find.text('Delta').last).dy));
    expect(top('Pinned'), lessThan(top('Delta')));
    expect(top('Delta'), lessThan(top('Bravo renamed')));
    expect(top('Bravo renamed'), lessThan(top('Today')));
    expect(top('Today'), lessThan(top('Alpha')));
    expect(await saved(dir, (db) => db.pins()), ['d', 'b']);
    await shot('20-pinned-light');

    // Drag Bravo above Delta.
    final drag = await tester.startGesture(tester.getCenter(find.text('Bravo renamed').first), kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 12; i++) {
      await drag.moveBy(const Offset(0, -6));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await wait(tester, 600);
    expect(top('Bravo renamed'), lessThan(top('Delta')));
    expect(await saved(dir, (db) => db.pins()), ['b', 'd']);

    // Unpin Delta from its row under its day (the menu shows the crossed-out pin): only the shortcut goes.
    await tester.tap(find.text('Delta').last, kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await wait(tester, 300);
    expect(find.text('Unpin'), findsOneWidget);
    expect(find.byKey(const Key('unpin-icon')), findsOneWidget);
    await shot('20b-unpin-menu-light');
    await menu('pin');
    expect(await saved(dir, (db) => db.pins()), ['b']);
    expect(find.text('Delta'), findsOneWidget);
    expect(find.byKey(const Key('pin-mark-d')), findsNothing);
    expect(top('Today'), lessThan(top('Delta')));
    expect(top('Charlie'), lessThan(top('Delta')));
    expect(top('Delta'), lessThan(top('Echo')));

    // Under a day with two chats, drag Echo above Delta; the order is saved.
    Future<void> dragUp(String text) async {
      final g = await tester.startGesture(tester.getCenter(find.text(text).last), kind: PointerDeviceKind.mouse);
      for (var i = 0; i < 12; i++) {
        await g.moveBy(const Offset(0, -6));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await wait(tester, 600);
    }

    await dragUp('Echo');
    expect(top('Echo'), lessThan(top('Delta')));
    expect(top(threeDays), lessThan(top('Echo')), reason: 'it stays under its day');
    expect(await saved(dir, (db) {
      final order = {for (final c in db.chats()) c.id: c.order};
      return order['e']! > order['d']!;
    }), isTrue);
    // A chat alone under its day cannot be picked up.
    bool canDrag(String text) =>
        tester.widget<ChatDragHandle>(find.ancestor(of: find.text(text).last, matching: find.byType(ChatDragHandle))).enabled;
    expect(canDrag('Charlie'), isFalse);
    expect(canDrag('Foxtrot'), isFalse);
    expect(canDrag('Echo'), isTrue);
    final charlie = top('Charlie');
    await dragUp('Charlie');
    expect(top('Charlie'), charlie);

    // Delete the open chat: the box asks; Cancel keeps it; Delete removes it and a new chat opens.
    await tester.tap(find.text('Echo'));
    await wait(tester, 300);
    await rightClick('Echo');
    await menu('delete');
    expect(find.text('Delete this chat?'), findsOneWidget);
    await shot('21-delete-confirm-light');
    await tester.tap(find.byKey(const Key('delete-cancel')));
    await wait(tester, 400);
    expect(find.text('Echo'), findsWidgets);
    await rightClick('Echo');
    await menu('delete');
    expect(find.text('Delete this chat?'), findsOneWidget, reason: 'Cancel did not count as a delete');
    await tester.tap(find.byKey(const Key('delete-confirm')));
    await wait(tester, 400);
    expect(find.text('Echo'), findsNothing);
    expect(find.text('Start a new chat'), findsOneWidget);
    expect(await saved(dir, (db) => db.chats().any((c) => c.id == 'e')), isFalse);
    expect(await saved(dir, (db) => db.messages('e')), isEmpty);

    // The second delete within 2 minutes still asks; after it, no more boxes.
    await rightClick('Foxtrot');
    await menu('delete');
    expect(find.text('Delete this chat?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-confirm')));
    await wait(tester, 400);
    expect(find.text('Foxtrot'), findsNothing);
    await rightClick('Charlie');
    await menu('delete');
    expect(find.text('Delete this chat?'), findsNothing);
    expect(find.text('Charlie'), findsNothing);
    await rightClick('Alpha');
    await menu('delete');
    expect(find.text('Delete this chat?'), findsNothing);
    expect(find.text('Alpha'), findsNothing);

    // Dark theme, for the look.
    container(tester).read(prefsProvider.notifier).setTheme(ThemeMode.dark);
    await wait(tester, 400);
    await rightClick('Delta');
    await shot('22-chat-menu-dark');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await wait(tester, 300);
    await mouse.removePointer();

    // Saved: opened again, the new name, the pin and the deletes are kept.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(await app(dir, DummyBackend()));
    await wait(tester, 1500);
    final again = container(tester).read(chatsProvider);
    expect([for (final c in again.chats) c.title], ['Bravo renamed', 'Delta']);
    expect(again.pinned, ['b']);

    deleteTestDir(dir);
  });

  testWidgets('chat menu keys: R renames, P pins and unpins, D deletes (with its box), as a click would', (tester) async {
    final dir = Directory.systemTemp.createTempSync('runmyai-test-');
    final storage = Storage(dir)..writePrefs(const PrefsData(theme: 'light'));
    final now = DateTime.now();
    for (final (i, (id, title)) in [('a', 'Alpha'), ('b', 'Bravo'), ('c', 'Charlie')].indexed) {
      final time = now.subtract(Duration(seconds: 2 + i));
      writeOldChat(dir, Chat(id: id, title: title, createdAt: time, updatedAt: time, messages: const [
        ChatMessage(Role.user, 'Hello'),
        ChatMessage(Role.assistant, 'Hi there.'),
      ]));
    }
    await setUpWindow(storage);
    await tester.pumpWidget(await app(dir, DummyBackend()));
    await wait(tester, 1500);
    Future<void> menuOf(String text) async {
      await tester.tap(find.text(text).first, kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await wait(tester, 300);
    }

    Future<void> press(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      for (var i = 0; i < 20; i++) {
        await wait(tester, 16);
      }
    }

    // The letters show at the right of the items.
    await menuOf('Bravo');
    for (final letter in ['R', 'P', 'D']) {
      expect(find.text(letter), findsOneWidget);
    }
    await shot('22-chat-menu-keys-light');

    // R: renaming, as with a click.
    await press(LogicalKeyboardKey.keyR);
    expect(find.text('Rename'), findsNothing, reason: 'the menu closed');
    expect(find.byKey(const Key('rename-box')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('rename-box')), 'Bravo two');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await wait(tester, 300);
    expect(find.text('Bravo two'), findsOneWidget);

    // P pins; P again unpins.
    await menuOf('Bravo two');
    await press(LogicalKeyboardKey.keyP);
    expect(find.text('Pinned'), findsOneWidget);
    expect(container(tester).read(chatsProvider).pinned, contains('b'));
    await menuOf('Bravo two');
    expect(find.text('Unpin'), findsOneWidget);
    await press(LogicalKeyboardKey.keyP);
    expect(find.text('Pinned'), findsNothing);

    // D: the delete box, as with a click; confirmed, the chat is gone.
    await menuOf('Charlie');
    await press(LogicalKeyboardKey.keyD);
    expect(find.byKey(const Key('delete-confirm')), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-confirm')));
    await wait(tester, 400);
    expect(find.text('Charlie'), findsNothing);

    // Other letters do nothing; Esc closes the menu.
    await menuOf('Alpha');
    await press(LogicalKeyboardKey.keyX);
    expect(find.text('Rename'), findsOneWidget, reason: 'still open');
    await press(LogicalKeyboardKey.escape);
    expect(find.text('Rename'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);

    deleteTestDir(dir);
  });

  testWidgets('chat list headings fold and open; the open chat stays visible; folds are kept by day; a search '
      'match opens its group', (tester) async {
    final dir = Directory.systemTemp.createTempSync('runmyai-test-');
    final storage = Storage(dir)..writePrefs(const PrefsData(theme: 'light'));
    final now = DateTime.now();
    final yesterday = DateTime(now.year, now.month, now.day - 1, 12);
    final chats = [
      ('a', 'Alpha', now.subtract(const Duration(seconds: 2)), 'Hello'),
      ('b', 'Bravo', now.subtract(const Duration(seconds: 3)), 'Hello'),
      ('c', 'Charlie', yesterday, 'We talked about the kumquat harvest.'),
      ('d', 'Delta', yesterday.subtract(const Duration(hours: 1)), 'Hello'),
    ];
    for (final (id, title, time, text) in chats) {
      writeOldChat(dir, Chat(id: id, title: title, createdAt: time, updatedAt: time, messages: [
        ChatMessage(Role.user, text),
        const ChatMessage(Role.assistant, 'Hi there.'),
      ]));
    }
    await setUpWindow(storage);
    await tester.pumpWidget(await app(dir, DummyBackend()));
    await wait(tester, 1500);
    Future<void> heading(String text) async {
      await tester.tap(find.byKey(Key('heading-$text')));
      for (var i = 0; i < 20; i++) {
        await wait(tester, 16);
      }
    }

    bool shows(String title) => find.text(title).evaluate().isNotEmpty;

    // Today folds and opens again.
    await heading('Today');
    expect((shows('Alpha'), shows('Bravo')), (false, false));
    expect(shows('Charlie'), isTrue, reason: 'other days stay open');
    await shot('23-folded-today-light');
    await heading('Today');
    expect((shows('Alpha'), shows('Bravo')), (true, true));

    // The open chat stays visible in its folded group.
    await tester.tap(find.text('Delta'));
    await wait(tester, 400);
    await heading('Yesterday');
    expect(shows('Delta'), isTrue, reason: 'the open chat stays');
    expect(shows('Charlie'), isFalse);
    expect(Storage(dir).readFolds()['chat'], [dayKey(yesterday)], reason: 'saved by its day');

    // Folds are kept after a restart.
    await tester.pumpWidget(await app(dir, DummyBackend()));
    await wait(tester, 1500);
    expect(shows('Charlie'), isFalse, reason: 'still folded');
    expect(shows('Alpha'), isTrue);

    // A search match in the folded group: the group opens.
    await tester.tap(find.byKey(const Key('search')));
    await wait(tester, 300);
    await tester.enterText(find.byKey(const Key('search-box')), 'kumquat');
    await searchDone(tester);
    await tester.tap(find.byKey(const Key('hit-c')));
    await wait(tester, 400);
    expect(container(tester).read(foldsProvider)[ChatKind.chat], isEmpty, reason: 'opened for the match');

    deleteTestDir(dir);
  });

  testWidgets('archive: A in the menu; the Archived row and list (last active first); search puts archived last; '
      'sending keeps it archived; unarchive brings it to the top of Today', (tester) async {
    final dir = Directory.systemTemp.createTempSync('runmyai-test-');
    final storage = Storage(dir)..writePrefs(const PrefsData(theme: 'light'));
    storage.writeLibrary(const LibraryData(downloaded: {'flint-40b/UD-Q4_K_XL'}, picked: 'flint-40b/UD-Q4_K_XL'));
    final now = DateTime.now();
    final older = DateTime(now.year, now.month, now.day - 3, 12);
    for (final (id, title, time, text) in [
      ('a', 'Alpha', now.subtract(const Duration(seconds: 2)), 'Planting kumquat trees.'),
      ('b', 'Bravo', now.subtract(const Duration(seconds: 3)), 'A kumquat recipe.'),
      ('c', 'Charlie', older, 'Hello'),
    ]) {
      writeOldChat(dir, Chat(id: id, title: title, createdAt: time, updatedAt: time, messages: [
        ChatMessage(Role.user, text),
        const ChatMessage(Role.assistant, 'Hi there.'),
      ]));
    }
    await setUpWindow(storage);
    await tester.pumpWidget(await app(dir, DummyBackend(tokensPerSecond: 5000, fixedReply: 'Fine.')));
    await wait(tester, 1500);
    Future<void> archiveKey(String title) async {
      await tester.tap(find.text(title).first, kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await wait(tester, 300);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      for (var i = 0; i < 20; i++) {
        await wait(tester, 16);
      }
    }

    bool shows(String title) => find.text(title).evaluate().isNotEmpty;

    // A archives: out of the list; the Archived row shows.
    await archiveKey('Charlie');
    await archiveKey('Alpha');
    expect((shows('Alpha'), shows('Charlie')), (false, false));
    expect(find.byKey(const Key('archived')), findsOneWidget);
    await shot('24-archived-row-light');

    // The archived list: plain, the last archived first.
    await tester.tap(find.byKey(const Key('archived')));
    await wait(tester, 300);
    expect(tester.getTopLeft(find.text('Alpha')).dy, lessThan(tester.getTopLeft(find.text('Charlie')).dy));
    await shot('25-archived-list-light');

    // Sending in an archived chat: it stays archived, and comes to the top of the archived list.
    await tester.tap(find.text('Charlie'));
    await wait(tester, 400);
    await tester.tap(find.byType(TextField));
    await wait(tester, 100);
    await tester.enterText(find.byType(TextField), 'Still here?');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await waitUntil(tester, () => container(tester).read(chatsProvider).replyingId == null);
    await wait(tester, 400);
    expect(container(tester).read(chatsProvider).byId('c')!.archived, isTrue);
    expect(tester.getTopLeft(find.text('Charlie')).dy, lessThan(tester.getTopLeft(find.text('Alpha')).dy));

    // Search: the archived match comes after the others, under "Archived".
    await tester.tap(find.byKey(const Key('search')));
    await wait(tester, 300);
    await tester.enterText(find.byKey(const Key('search-box')), 'kumquat');
    await searchDone(tester);
    expect(find.byKey(const Key('archived-results')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const Key('hit-b'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('archived-results'))).dy));
    expect(tester.getTopLeft(find.byKey(const Key('archived-results'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('hit-a'))).dy));
    await tester.tap(find.byKey(const Key('search-close')));
    await wait(tester, 300);

    // Unarchive (A again, in the archived list, still open after the search): back at the top of Today.
    expect(find.byKey(const Key('archive-back')), findsOneWidget);
    await archiveKey('Alpha');
    expect(find.byKey(const Key('archived')), findsOneWidget);
    await tester.tap(find.byKey(const Key('archive-back')));
    await wait(tester, 300);
    expect(find.byKey(const Key('archived')), findsOneWidget);
    expect(tester.getTopLeft(find.text('Alpha')).dy, lessThan(tester.getTopLeft(find.text('Bravo')).dy));
    expect(await saved(dir, (db) => db.chats().firstWhere((c) => c.id == 'a').archived), isFalse);

    deleteTestDir(dir);
  });

  testWidgets('Chat and Code: each has its own chats, pins, search and open chat', (tester) async {
    final dir = Directory.systemTemp.createTempSync('runmyai-test-');
    final storage = Storage(dir)..writePrefs(const PrefsData(theme: 'light'));
    // Two chats in each section; every one mentions a zebra.
    final db = ChatDb.open('${dir.path}/chats.db');
    var time = DateTime.now().subtract(const Duration(minutes: 6));
    for (final (id, title, kind) in [
      ('chat1', 'Paris trip', ChatKind.chat),
      ('code1', 'Fix the parser', ChatKind.code),
      ('chat2', 'Budget', ChatKind.chat),
      ('code2', 'Sort function', ChatKind.code),
      ('code3', 'Unit tests', ChatKind.code),
    ]) {
      time = time.add(const Duration(minutes: 1));
      db.createChat(ChatInfo(id: id, title: title, createdAt: time, updatedAt: time, kind: kind));
      db.addMessage(id, 0, ChatMessage(Role.user, 'A zebra in $title'));
      db.addMessage(id, 1, const ChatMessage(Role.assistant, 'Noted.'));
    }
    db
      ..setPins(['chat1', 'code1', 'code3'])
      ..close();
    await setUpWindow(storage);
    await tester.pumpWidget(await app(dir, DummyBackend()));
    await wait(tester, 1500);
    ChatsState chats() => container(tester).read(chatsProvider);
    Section section() => container(tester).read(sectionProvider);
    double top(String text) => tester.getTopLeft(find.text(text).first).dy;

    // Chat shows only its own chats (Paris trip twice: pinned, and under its day).
    expect(find.text('Paris trip'), findsNWidgets(2));
    expect(find.text('Budget'), findsOneWidget);
    expect(find.text('Fix the parser'), findsNothing);
    expect(find.text('Sort function'), findsNothing);
    await tester.tap(find.text('Budget'));
    await wait(tester, 400);
    expect(chats().openId, 'chat2');

    // Code: its own chats and its own pins. The switch's pill slides over to Code.
    expect(tester.widget<AnimatedAlign>(find.byKey(const Key('section-pill'))).alignment, Alignment.centerLeft);
    await tester.tap(find.byKey(const Key('section-code')));
    await wait(tester, 400);
    expect(section(), Section.code);
    expect(tester.widget<AnimatedAlign>(find.byKey(const Key('section-pill'))).alignment, Alignment.centerRight);
    expect(find.text('Paris trip'), findsNothing);
    expect(find.text('Budget'), findsNothing);
    expect(top('Pinned'), lessThan(top('Fix the parser')));
    expect(top('Fix the parser'), lessThan(top('Unit tests')));
    expect(top('Unit tests'), lessThan(top('Today')));
    expect(top('Today'), lessThan(top('Sort function')));
    expect(chats().openId, isNull, reason: 'Code has no chat open yet');
    await shot('23-code-chats-light');

    // Moving a Code pin leaves Chat's pin where it is.
    container(tester).read(chatsProvider.notifier).movePin(1, 0);
    await wait(tester, 300);
    expect(top('Unit tests'), lessThan(top('Fix the parser')));
    expect(await saved(dir, (db) => db.pins()), ['chat1', 'code3', 'code1']);

    // Search looks only through Code's chats.
    await tester.tap(find.byKey(const Key('search')));
    await wait(tester, 300);
    await tester.enterText(find.byKey(const Key('search-box')), 'zebra');
    await searchDone(tester);
    expect(find.byKey(const Key('hit-code1')), findsOneWidget);
    expect(find.byKey(const Key('hit-code2')), findsOneWidget);
    expect(find.byKey(const Key('hit-chat1')), findsNothing);
    expect(find.byKey(const Key('hit-chat2')), findsNothing);
    await shot('24-code-search-light');
    // ... and Chat's search only through Chat's, with the box left open.
    await tester.tap(find.byKey(const Key('section-chat')));
    await wait(tester, 300);
    await searchDone(tester);
    expect(find.byKey(const Key('hit-chat1')), findsOneWidget);
    expect(find.byKey(const Key('hit-code1')), findsNothing);
    await tester.tap(find.byKey(const Key('section-code')));
    await wait(tester, 300);
    await searchDone(tester);
    await tester.tap(find.byKey(const Key('hit-code2')));
    await wait(tester, 400);
    expect(section(), Section.code, reason: 'a Code chat opens in Code');
    expect(chats().openId, 'code2');
    await tester.tap(find.byKey(const Key('search-box')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await wait(tester, 300);

    // Each section keeps its open chat.
    await tester.tap(find.byKey(const Key('section-chat')));
    await wait(tester, 400);
    expect(chats().openId, 'chat2');
    expect(find.text('A zebra in Budget'), findsOneWidget);
    await tester.tap(find.byKey(const Key('section-code')));
    await wait(tester, 400);
    expect(chats().openId, 'code2');

    // New chat in Code stays in Code; Chat's open chat is not touched.
    await tester.tap(find.byKey(const Key('new-chat')));
    await wait(tester, 300);
    expect(section(), Section.code);
    expect(chats().openId, isNull);
    await tester.tap(find.byKey(const Key('section-chat')));
    await wait(tester, 400);
    expect(chats().openId, 'chat2');

    // Each chat's section is saved.
    expect(
      await saved(dir, (db) => {for (final c in db.chats()) c.id: c.kind}),
      {
        'chat1': ChatKind.chat,
        'chat2': ChatKind.chat,
        'code1': ChatKind.code,
        'code2': ChatKind.code,
        'code3': ChatKind.code,
      },
    );

    // Rows open and close instead of snapping: a newly pinned row starts with no height and grows; a deleted
    // chat's rows stay a moment while they close.
    double height(String text) =>
        tester.getSize(find.ancestor(of: find.text(text).first, matching: find.byType(SizeTransition)).first).height;
    container(tester).read(chatsProvider.notifier).pin('chat2');
    await tester.pump();
    expect(height('Budget'), lessThan(10), reason: 'the new Pinned row starts closed');
    await wait(tester, 400);
    final full = tester.getSize(find.ancestor(of: find.text('Budget').last, matching: find.byType(ChatRow))).height;
    expect(height('Budget'), closeTo(full, 0.5));
    container(tester).read(chatsProvider.notifier).delete('chat2');
    await tester.pump();
    expect(find.text('Budget'), findsNWidgets(2), reason: 'still there while closing');
    await wait(tester, 400);
    expect(find.text('Budget'), findsNothing);

    deleteTestDir(dir);
  });

  testWidgets('dragging a chat: it stays under its heading and inside the list, and scrolls a long day', (tester) async {
    final dir = Directory.systemTemp.createTempSync('runmyai-test-');
    final storage = Storage(dir)..writePrefs(const PrefsData(theme: 'light'));
    // 40 chats today (Today 01 the newest), one yesterday.
    final db = ChatDb.open('${dir.path}/chats.db');
    final now = DateTime.now();
    for (var i = 1; i <= 40; i++) {
      final t = now.subtract(Duration(seconds: i));
      db.createChat(ChatInfo(id: 't$i', title: 'Today ${'$i'.padLeft(2, '0')}', createdAt: t, updatedAt: t));
    }
    final y = DateTime(now.year, now.month, now.day - 1, 12);
    db
      ..createChat(ChatInfo(id: 'y', title: 'Old one', createdAt: y, updatedAt: y))
      ..close();
    await setUpWindow(storage);
    await tester.pumpWidget(await app(dir, DummyBackend()));
    await wait(tester, 1500);

    ScrollableState list() =>
        tester.state<ScrollableState>(find.descendant(of: find.byType(ChatList), matching: find.byType(Scrollable)).first);
    Rect listRect() {
      final box = list().context.findRenderObject()! as RenderBox;
      return box.localToGlobal(Offset.zero) & box.size;
    }

    double top(String text) => tester.getTopLeft(find.text(text).first).dy;
    final storeTop = tester.getTopLeft(find.byKey(const Key('store'))).dy;
    expect(listRect().bottom, lessThanOrEqualTo(storeTop));
    // Every copy of the dragged row on screen (the lifted one and its place in the list).
    List<Rect> rows(String text) => [for (var i = 0; i < find.text(text).evaluate().length; i++) tester.getRect(find.text(text).at(i))];

    // Dragged far up: it stops under the Today heading.
    final todayBottom = tester.getBottomLeft(find.text('Today')).dy;
    var g = await tester.startGesture(tester.getCenter(find.text('Today 03')), kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 25; i++) {
      await g.moveBy(const Offset(0, -12));
      await tester.pump(const Duration(milliseconds: 16));
      for (final r in rows('Today 03')) {
        expect(r.top, greaterThanOrEqualTo(todayBottom), reason: 'not past the Today heading');
      }
    }
    await g.up();
    await wait(tester, 600);
    expect(top('Today 03'), lessThan(top('Today 01')));
    expect(list().position.pixels, 0);

    // Dragged far down, past Store and Settings: it stays inside the list, which scrolls down through the long day
    // while the pointer is held there, and stops at the day's end (never past the Yesterday heading).
    g = await tester.startGesture(tester.getCenter(find.text('Today 05')), kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Held until the list stops scrolling (the end of the day is in view), at most about 10 s.
    var still = 0;
    for (var i = 0; i < 600 && still < 20; i++) {
      final before = list().position.pixels;
      await wait(tester, 16);
      still = list().position.pixels == before ? still + 1 : 0;
      final view = listRect();
      for (final r in rows('Today 05')) {
        expect(r.bottom, lessThanOrEqualTo(view.bottom + 0.5), reason: 'inside the list, not over Store');
        expect(r.top, greaterThanOrEqualTo(view.top - 0.5));
      }
      if (find.text('Yesterday').evaluate().isNotEmpty) {
        final yesterdayTop = top('Yesterday');
        for (final r in rows('Today 05')) {
          expect(r.bottom, lessThanOrEqualTo(yesterdayTop + 0.5), reason: 'not past the Yesterday heading');
        }
      }
    }
    expect(list().position.pixels, greaterThan(500), reason: 'the list scrolled down with the drag');
    await shot('25-drag-long-day-light');
    await g.up();
    await wait(tester, 600);
    expect(top('Today 40'), lessThan(top('Today 05')), reason: 'dropped at the end of the day');
    expect(top('Today 05'), lessThan(top('Yesterday')));
    expect(await saved(dir, (db) {
      final order = {for (final c in db.chats()) c.id: c.order};
      return order['t40']! > order['t5']!;
    }), isTrue);

    deleteTestDir(dir);
  });

  testWidgets('reply motion: no settings; messages from the top; the page follows only from the bottom; '
      'the jump button', (tester) async {
    final dir = Directory.systemTemp.createTempSync('runmyai-test-');
    final storage = Storage(dir)..writePrefs(const PrefsData(theme: 'light'));
    storage.writeLibrary(const LibraryData(downloaded: {'flint-40b/UD-Q4_K_XL'}, picked: 'flint-40b/UD-Q4_K_XL'));
    final backend = DummyBackend(tokensPerSecond: 60);
    await setUpWindow(storage);
    await tester.pumpWidget(await app(dir, backend));
    await wait(tester, 1500);
    // Settings: Reply motion, Smooth or Raw (for demos); Smooth to start with.
    await tester.tap(find.text('Settings').first);
    await wait(tester, 400);
    expect(find.byKey(const Key('motion-smooth')), findsOneWidget);
    expect(find.byKey(const Key('motion-raw')), findsOneWidget);
    expect(container(tester).read(motionProvider), smoothMotion);
    await shot('26-settings-light');

    // A new chat: the first message at the top, the second right under the first reply.
    await tester.tap(find.byKey(const Key('section-chat')));
    await wait(tester, 300);
    Future<void> ask(String text) async {
      await tester.tap(find.byType(TextField));
      await wait(tester, 100);
      await tester.enterText(find.byType(TextField), text);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    }

    Finder inChat(Finder f) => find.descendant(of: find.byType(ChatPage), matching: f);
    final chatView = inChat(find.byType(Scrollable)).first;
    ScrollPosition chatScroll() => tester.state<ScrollableState>(chatView).position;
    double viewTop() => tester.getTopLeft(chatView).dy;
    final jumpButton = find.byKey(const Key('jump-newest'));
    double jumpShown() =>
        tester.widget<AnimatedOpacity>(find.ancestor(of: jumpButton, matching: find.byType(AnimatedOpacity))).opacity;
    final middle = tester.getCenter(find.byType(ChatPage));
    Future<void> wheel(double dy) async {
      await tester.sendEventToBinding(PointerScrollEvent(position: middle, scrollDelta: Offset(0, dy)));
      await wait(tester, 100);
    }

    Future<void> frames(int n) async {
      for (var i = 0; i < n; i++) {
        await wait(tester, 16);
      }
    }

    backend.speed.value = 5000;
    await ask('First question');
    await frames(10);
    final first = inChat(find.text('First question'));
    expect(tester.getTopLeft(first).dy - viewTop(), lessThan(40), reason: 'the first message is at the top');
    await waitUntil(tester, () => container(tester).read(chatsProvider).replyingId == null);
    await wait(tester, 600);
    final firstReplyBottom = tester.getBottomLeft(inChat(find.byType(LiveReply))).dy;
    await ask('Second question');
    await frames(10);
    final secondTop = tester.getTopLeft(inChat(find.text('Second question'))).dy;
    expect(secondTop - firstReplyBottom, inInclusiveRange(0, 40), reason: 'the second message is right under the reply');
    expect(tester.getTopLeft(first).dy - viewTop(), lessThan(40), reason: 'nothing was pushed up');
    await waitUntil(tester, () => container(tester).read(chatsProvider).replyingId == null);
    await wait(tester, 600);
    await shot('27-short-chat-light');

    // A short chat: no scrolling past the messages, either way.
    await wheel(-100000);
    expect(chatScroll().pixels, chatScroll().minScrollExtent);
    await wheel(100000);
    expect(chatScroll().pixels, chatScroll().maxScrollExtent);
    expect(chatScroll().maxScrollExtent, 0, reason: 'a short chat does not scroll');
    expect(tester.getTopLeft(first).dy - viewTop(), lessThan(40), reason: 'still at the top');
    expect(jumpShown(), 0);

    // A story, from the bottom: the page follows its end, the jump button hidden.
    backend.speed.value = 60;
    await ask('Tell me a story');
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (chatScroll().pixels < 300 && DateTime.now().isBefore(end)) {
      await wait(tester, 16);
    }
    expect(chatScroll().pixels, greaterThanOrEqualTo(300), reason: 'the page followed the story down');
    expect(chatScroll().maxScrollExtent - chatScroll().pixels, lessThan(40), reason: 'following, at the end');
    expect(jumpShown(), 0, reason: 'following: no jump button');
    await shot('28-story-following-light');
    // Line by line: in every frame the page is within two lines of the end (a new line moves it up almost at once).
    for (var i = 0; i < 120; i++) {
      await wait(tester, 16);
      expect(chatScroll().maxScrollExtent - chatScroll().pixels, lessThan(50), reason: 'frame $i');
    }

    // A small scroll up: the page stays put, and the jump button shows.
    await wheel(-60);
    final story = inChat(find.byType(LiveReply));
    final storyAt = tester.getTopLeft(story).dy;
    final pixels = chatScroll().pixels;
    for (var i = 0; i < 60; i++) {
      await wait(tester, 16);
      expect(tester.getTopLeft(story).dy, closeTo(storyAt, 0.5), reason: 'the text on screen did not move');
    }
    expect(chatScroll().pixels, pixels);
    expect(container(tester).read(chatsProvider).replyingId, isNotNull, reason: 'the reply was still being written');
    expect(jumpShown(), 1, reason: 'text below: the jump button shows');
    await shot('29-story-scrolled-up-light');

    // Back down to the bottom: it follows again.
    await wheel(100000);
    await frames(60);
    expect(chatScroll().pixels, greaterThan(pixels + 60), reason: 'following again');
    // (Checked right after a frame: a new paragraph can add up to three lines before the page moves up to them.)
    expect(chatScroll().maxScrollExtent - chatScroll().pixels, lessThan(80));
    expect(jumpShown(), 0);
    await tester.tap(find.byKey(const Key('stop')));
    await wait(tester, 400);

    // Sent while scrolled up: the page stays where it is; the jump button goes to the end and follows from there.
    await wheel(-400);
    final upAt = chatScroll().pixels;
    await ask('One more story');
    for (var i = 0; i < 90; i++) {
      await wait(tester, 16);
      expect(chatScroll().pixels, upAt, reason: 'sent while scrolled up: the page stayed');
    }
    expect(jumpShown(), 1);
    await tester.tap(jumpButton);
    await frames(60);
    expect(chatScroll().maxScrollExtent - chatScroll().pixels, lessThan(40), reason: 'at the end, following');
    final following = chatScroll().pixels;
    await frames(90);
    expect(chatScroll().pixels, greaterThan(following), reason: 'it kept following');
    expect(jumpShown(), 0);
    await tester.tap(find.byKey(const Key('stop')));
    await wait(tester, 400);

    // Opened again from the list: at its end.
    await tester.tap(find.byKey(const Key('new-chat')));
    await wait(tester, 300);
    await tester.tap(find.text('First question').first);
    await frames(30);
    expect(chatScroll().pixels, chatScroll().maxScrollExtent, reason: 'a chat opens at its end');
    expect(chatScroll().pixels, greaterThan(0));

    // A followed story that ends by itself (its room closing): the next message is followed too.
    backend.speed.value = 5000;
    await ask('A quick story');
    await waitUntil(tester, () => container(tester).read(chatsProvider).replyingId == null, timeoutMs: 20000);
    await frames(50);
    expect(chatScroll().maxScrollExtent - chatScroll().pixels, lessThan(2), reason: 'still at the bottom');
    backend.speed.value = 60;

    // The next message is followed (frames all along, as a real window draws them).
    await tester.tap(find.byType(TextField));
    await wait(tester, 100);
    await tester.enterText(find.byType(TextField), 'Another story');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    Future<void> framesFor(int ms) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (DateTime.now().isBefore(end)) {
        await wait(tester, 16);
      }
    }

    await framesFor(1000);
    final followedFrom = chatScroll().pixels;
    await framesFor(2600);
    expect(chatScroll().pixels, greaterThan(followedFrom + 30), reason: 'the message after it was followed');
    expect(chatScroll().maxScrollExtent - chatScroll().pixels, lessThan(50), reason: 'at the end');
    await tester.tap(find.byKey(const Key('stop')));
    await wait(tester, 400);

    deleteTestDir(dir);
  });

  testWidgets('long sent messages: folded to 8 lines with an arrow; opened; folding keeps the arrow in place; a '
      'search match in the folded part opens it; folded again when the chat is opened again', (tester) async {
    final dir = Directory.systemTemp.createTempSync('runmyai-test-');
    final storage = Storage(dir)..writePrefs(const PrefsData(theme: 'light'));
    const filler = 'Some text to give the chat some length, a couple of lines in each message here.';
    final long = [for (var i = 1; i <= 70; i++) i == 66 ? 'Line $i has the word kumquat.' : 'Line $i of a long pasted text.']
        .join('\n');
    final when = DateTime(2026, 10, 20);
    writeOldChat(dir, Chat(id: 'fold', title: 'Folding test', createdAt: when, updatedAt: when, messages: [
      for (var i = 0; i < 6; i++) ChatMessage(i.isEven ? Role.user : Role.assistant, filler),
      ChatMessage(Role.user, long),
      for (var i = 0; i < 6; i++) ChatMessage(i.isEven ? Role.assistant : Role.user, filler),
    ]));
    writeOldChat(dir, Chat(id: 'other', title: 'Another chat', createdAt: when, updatedAt: when, messages: const [
      ChatMessage(Role.user, 'Hello.'),
      ChatMessage(Role.assistant, 'Hi.'),
    ]));
    await setUpWindow(storage);
    await tester.pumpWidget(await app(dir, DummyBackend()));
    await wait(tester, 1500);
    await tester.tap(find.text('Folding test'));
    await wait(tester, 500);

    // The long message (the only one with an arrow).
    final longOne = find.ancestor(of: find.byType(Tooltip), matching: find.byType(FoldedText));
    final folded = find.descendant(of: longOne, matching: find.byType(AnimatedSize));
    double shown() => tester.getSize(folded).height;
    final chatView = find.descendant(of: find.byType(ChatPage), matching: find.byType(Scrollable)).first;
    ScrollPosition chatScroll() => tester.state<ScrollableState>(chatView).position;

    // Folded: 8 lines and the arrow.
    chatScroll().jumpTo(0);
    await wait(tester, 200);
    await tester.ensureVisible(longOne);
    await wait(tester, 300);
    expect(shown(), closeTo(8 * 24, 1));
    expect(find.byTooltip('Show more'), findsOneWidget);
    await shot('30-folded-light');

    // Opened: all of it.
    await tester.tap(find.byTooltip('Show more'));
    for (var i = 0; i < 30; i++) {
      await wait(tester, 16);
    }
    expect(shown(), greaterThan(60 * 24));
    expect(find.byTooltip('Show less'), findsOneWidget);

    // Folded again with its top far above the view: the arrow stays where it was clicked.
    final arrow = find.byTooltip('Show less');
    final view = tester.getRect(chatView);
    _jumpBy(chatScroll(), tester.getCenter(arrow).dy - view.center.dy);
    await wait(tester, 100);
    expect(tester.getTopLeft(longOne).dy, lessThan(view.top), reason: 'its top is above the view');
    final at = tester.getCenter(arrow).dy;
    await tester.tap(arrow);
    for (var i = 0; i < 40; i++) {
      await wait(tester, 16);
    }
    expect(shown(), closeTo(8 * 24, 1));
    expect(tester.getCenter(find.byTooltip('Show more')).dy, closeTo(at, 2), reason: 'the arrow stayed in place');
    await shot('31-folded-in-place-light');

    // Opened again, another chat, and back: folded again.
    await tester.tap(find.byTooltip('Show more'));
    await wait(tester, 400);
    await tester.tap(find.text('Another chat'));
    await wait(tester, 400);
    await tester.tap(find.text('Folding test'));
    await wait(tester, 500);
    expect(find.byTooltip('Show more'), findsOneWidget, reason: 'folded again');

    // A search match in the folded part: it opens, and the match is on screen.
    await tester.tap(find.byKey(const Key('search')));
    await wait(tester, 300);
    await tester.enterText(find.byKey(const Key('search-box')), 'kumquat');
    await searchDone(tester);
    await tester.tap(find.byKey(const Key('hit-fold')));
    for (var i = 0; i < 40; i++) {
      await wait(tester, 16);
    }
    expect(find.byTooltip('Show less'), findsOneWidget, reason: 'opened for the match');
    // Where the word itself is (its line inside the long text).
    RenderEditable? editable;
    void visit(RenderObject o) => o is RenderEditable ? editable ??= o : o.visitChildren(visit);
    visit(tester.renderObject(longOne));
    final wordAt = editable!
        .localToGlobal(editable!.getLocalRectForCaret(TextPosition(offset: long.indexOf('kumquat'))).topLeft)
        .dy;
    final area = tester.getRect(chatView);
    expect(wordAt, inInclusiveRange(area.top, area.bottom - 24), reason: 'the match is on screen');
    await shot('32-folded-search-light');

    deleteTestDir(dir);
  });

  testWidgets('keyboard shortcuts: Ctrl+N, Alt+↑/↓ (pinned twice, folded skipped, the ends), typing anywhere, Ctrl+K, '
      'Esc (search first, then the reply), Ctrl+. and F2, the delete box\'s keys, Ctrl+B, Ctrl+, , text size, Ctrl+/',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('runmyai-test-');
    final storage = Storage(dir)..writePrefs(const PrefsData(theme: 'light'));
    storage.writeLibrary(const LibraryData(downloaded: {'flint-40b/UD-Q4_K_XL'}, picked: 'flint-40b/UD-Q4_K_XL'));
    final now = DateTime.now();
    for (final (i, (id, title)) in [('a', 'Alpha'), ('b', 'Bravo'), ('c', 'Charlie')].indexed) {
      final time = now.subtract(Duration(seconds: 2 + i));
      writeOldChat(dir, Chat(id: id, title: title, createdAt: time, updatedAt: time, messages: const [
        ChatMessage(Role.user, 'Hello'),
        ChatMessage(Role.assistant, 'Hi there.'),
      ]));
    }
    await setUpWindow(storage);
    await tester.pumpWidget(await app(dir, DummyBackend(tokensPerSecond: 22, fixedReply: DummyBackend.replyText)));
    await wait(tester, 1500);
    final chats = container(tester).read(chatsProvider.notifier);
    String? open() => container(tester).read(chatsProvider).openId;
    chats.pin('c');
    await wait(tester, 300);

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await wait(tester, 16);
      }
    }

    Future<void> press(LogicalKeyboardKey key, {bool ctrl = false, bool alt = false, bool shift = false}) async {
      if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle();
    }

    Future<void> type(LogicalKeyboardKey key, String character) async {
      await tester.sendKeyDownEvent(key, character: character);
      await tester.sendKeyUpEvent(key);
    }

    Future<void> down() => press(LogicalKeyboardKey.arrowDown, alt: true);
    Future<void> up() => press(LogicalKeyboardKey.arrowUp, alt: true);
    final box = find.byType(TextField).last;
    String boxText() => tester.widget<TextField>(box).controller!.text;

    // Alt+↓ from a new chat: the first chat, under Pinned; then down the list (the pinned one again under Today),
    // and nothing past the end; Alt+↑ back up, and nothing past the top.
    expect(open(), isNull);
    await up();
    expect(open(), isNull, reason: 'Alt+↑ with no chat open: nothing');
    final walk = <String?>[];
    for (var i = 0; i < 5; i++) {
      await down();
      walk.add(open());
    }
    expect(walk, ['c', 'a', 'b', 'c', 'c'], reason: 'Pinned, then Today: Alpha, Bravo, Charlie; then the end');
    walk.clear();
    for (var i = 0; i < 4; i++) {
      await up();
      walk.add(open());
    }
    expect(walk, ['b', 'a', 'c', 'c'], reason: 'back up to the top, and no further');

    // A folded group is stepped over (its open chat stays in sight, and is still stepped from).
    await tester.tap(find.byKey(const Key('heading-Today')));
    await settle();
    await down();
    expect(open(), 'c', reason: 'Today is folded: nothing below Pinned but the open chat itself');
    await tester.tap(find.byKey(const Key('heading-Today')));
    await settle();

    // Typing with no text box chosen goes into the message box.
    FocusManager.instance.primaryFocus?.unfocus();
    await settle();
    // (Only the first letter: in a test, keys do not type into a text box once it has the cursor.)
    await type(LogicalKeyboardKey.keyH, 'h');
    await settle();
    expect(boxText(), 'h');
    expect(tester.widget<TextField>(box).focusNode!.hasFocus, isTrue, reason: 'and the cursor with it');
    await tester.enterText(box, '');

    // Ctrl+K: the search box, with the cursor in it; Esc from the message box closes it first.
    await press(LogicalKeyboardKey.keyK, ctrl: true);
    expect(find.byKey(const Key('search-box')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('search-box'))).focusNode!.hasFocus, isTrue);
    await type(LogicalKeyboardKey.keyB, 'b');
    await settle();
    expect(boxText(), '', reason: 'typing in the search box stays there');
    await tester.tap(box);
    await settle();
    await press(LogicalKeyboardKey.escape);
    expect(find.byKey(const Key('search-box')), findsNothing);
    // Ctrl+K again closes it (as its ✕ does), and the cursor goes back to the message box.
    await press(LogicalKeyboardKey.keyK, ctrl: true);
    expect(find.byKey(const Key('search-box')), findsOneWidget);
    await press(LogicalKeyboardKey.keyK, ctrl: true);
    expect(find.byKey(const Key('search-box')), findsNothing);
    expect(tester.widget<TextField>(box).focusNode!.hasFocus, isTrue);

    // Esc while a reply is written (in a new chat, Ctrl+N): the search first, then the reply.
    await press(LogicalKeyboardKey.keyN, ctrl: true);
    expect(open(), isNull);
    await tester.enterText(box, 'Tell me a story');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await wait(tester, 600);
    expect(container(tester).read(chatsProvider).replyingId, open());
    await press(LogicalKeyboardKey.keyK, ctrl: true);
    await tester.tap(box);
    await settle();
    await press(LogicalKeyboardKey.escape);
    expect(find.byKey(const Key('search-box')), findsNothing);
    expect(container(tester).read(chatsProvider).replyingId, isNotNull, reason: 'the first Esc closed the search');
    await press(LogicalKeyboardKey.escape);
    expect(container(tester).read(chatsProvider).replyingId, isNull, reason: 'the second stopped the reply');

    // Ctrl+.: the open chat's menu, whose letters work.
    final id = open()!;
    await press(LogicalKeyboardKey.period, ctrl: true);
    expect(find.text('Rename'), findsOneWidget);
    await press(LogicalKeyboardKey.keyP);
    expect(container(tester).read(chatsProvider).pinned, contains(id));

    // F2: renaming it.
    await press(LogicalKeyboardKey.f2);
    expect(find.byKey(const Key('rename-box')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('rename-box')), 'Story time');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle();
    expect(container(tester).read(chatsProvider).byId(id)?.title, 'Story time');

    // The delete box: Delete is chosen, so Enter deletes; ← then Enter cancels.
    await press(LogicalKeyboardKey.period, ctrl: true);
    await press(LogicalKeyboardKey.keyD);
    expect(find.byKey(const Key('delete-confirm')), findsOneWidget);
    await shot('33-delete-box-keys-light');
    await press(LogicalKeyboardKey.arrowLeft);
    await press(LogicalKeyboardKey.enter);
    expect(find.byKey(const Key('delete-confirm')), findsNothing);
    expect(container(tester).read(chatsProvider).byId(id), isNotNull, reason: 'cancelled');
    await press(LogicalKeyboardKey.period, ctrl: true);
    await press(LogicalKeyboardKey.keyD);
    await press(LogicalKeyboardKey.enter);
    expect(container(tester).read(chatsProvider).byId(id), isNull, reason: 'deleted');

    // Ctrl+, : Settings; again: back to the chat it was on.
    await down();
    final was = open();
    expect(was, isNotNull);
    await press(LogicalKeyboardKey.comma, ctrl: true);
    expect(container(tester).read(sectionProvider), Section.settings);
    await press(LogicalKeyboardKey.comma, ctrl: true);
    expect(container(tester).read(sectionProvider), Section.chat);
    expect(open(), was);
    // From the Store, Settings, then back to the Store.
    await tester.tap(find.byKey(const Key('store')));
    await settle();
    await press(LogicalKeyboardKey.comma, ctrl: true);
    await press(LogicalKeyboardKey.comma, ctrl: true);
    expect(container(tester).read(sectionProvider), Section.store);
    await tester.tap(find.byKey(const Key('section-chat')));
    await settle();

    // Ctrl+N: a new chat, from a chat and from Settings.
    await press(LogicalKeyboardKey.keyN, ctrl: true);
    expect(open(), isNull);
    await press(LogicalKeyboardKey.comma, ctrl: true);
    expect(container(tester).read(sectionProvider), Section.settings);
    await press(LogicalKeyboardKey.keyN, ctrl: true);
    expect(container(tester).read(sectionProvider), Section.chat);

    // Ctrl+B hides and shows the sidebar.
    await press(LogicalKeyboardKey.keyB, ctrl: true);
    expect(container(tester).read(prefsProvider).sidebarHidden, isTrue);
    await press(LogicalKeyboardKey.keyB, ctrl: true);
    expect(container(tester).read(prefsProvider).sidebarHidden, isFalse);

    // Text size: bigger, smaller, normal.
    await press(LogicalKeyboardKey.equal, ctrl: true);
    expect(container(tester).read(prefsProvider).textScale, 1.1);
    expect(MediaQuery.textScalerOf(tester.element(find.byType(Shell))).scale(10), closeTo(11, 0.01));
    await press(LogicalKeyboardKey.minus, ctrl: true);
    await press(LogicalKeyboardKey.minus, ctrl: true);
    expect(container(tester).read(prefsProvider).textScale, 0.9);
    await press(LogicalKeyboardKey.digit0, ctrl: true);
    expect(container(tester).read(prefsProvider).textScale, 1);

    // Ctrl+/: the list of shortcuts; Esc closes it.
    await press(LogicalKeyboardKey.slash, ctrl: true);
    expect(find.byKey(const Key('shortcuts-sheet')), findsOneWidget);
    await shot('34-shortcuts-sheet-light');
    await press(LogicalKeyboardKey.escape);
    expect(find.byKey(const Key('shortcuts-sheet')), findsNothing);

    deleteTestDir(dir);
  });

  testWidgets('message buttons (copy, bookmark), bookmarks (marks, the dashes and their card, Alt+Shift+↑/↓), drafts '
      'per chat (and after a restart), the bell', (tester) async {
    final dir = Directory.systemTemp.createTempSync('runmyai-test-');
    final storage = Storage(dir)..writePrefs(const PrefsData(theme: 'light'));
    storage.writeLibrary(const LibraryData(downloaded: {'flint-40b/UD-Q4_K_XL'}, picked: 'flint-40b/UD-Q4_K_XL'));
    final now = DateTime.now();
    writeOldChat(dir, Chat(id: 'a', title: 'Long chat', createdAt: now, updatedAt: now, messages: [
      for (var i = 0; i < 30; i++) ChatMessage(i.isEven ? Role.user : Role.assistant, i.isEven ? 'Question $i' : 'Answer $i.'),
    ]));
    final earlier = now.subtract(const Duration(seconds: 5));
    writeOldChat(dir, Chat(id: 'b', title: 'Other chat', createdAt: earlier, updatedAt: earlier, messages: const [
      ChatMessage(Role.user, 'Hello'),
      ChatMessage(Role.assistant, 'Hi there.'),
    ]));
    final backend = DummyBackend(tokensPerSecond: 40, fixedReply: 'A short reply.');
    await setUpWindow(storage);
    await tester.pumpWidget(await app(dir, backend));
    await wait(tester, 1500);
    Future<void> settle([int frames = 20]) async {
      for (var i = 0; i < frames; i++) {
        await wait(tester, 16);
      }
    }

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    Future<void> hover(Finder f) async {
      await mouse.moveTo(tester.getCenter(f));
      await settle(5);
    }

    Future<void> press(LogicalKeyboardKey key, {bool ctrl = false, bool alt = false, bool shift = false}) async {
      if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(30);
    }

    final box = find.byType(TextField).last;
    String boxText() => tester.widget<TextField>(box).controller!.text;
    Future<void> openChat(String title) async {
      await tester.tap(find.text(title).first);
      await settle(40);
    }

    // On screen: inside the conversation's view.
    final view = find.byType(ListView).last;
    bool onScreen(String text) {
      final f = find.text(text);
      if (f.evaluate().isEmpty) return false;
      final r = tester.getRect(f.first), v = tester.getRect(view);
      return r.top >= v.top && r.bottom <= v.bottom;
    }

    await openChat('Long chat');

    // Copy: the buttons show only with the pointer on a message; Copy copies its text and turns into a tick.
    expect(find.byKey(const Key('copy-29')), findsNothing);
    await hover(find.text('Answer 29.'));
    expect(find.byKey(const Key('copy-29')), findsOneWidget);
    expect(find.byKey(const Key('bookmark-29')), findsOneWidget, reason: 'a reply has a bookmark button');
    await tester.tap(find.byKey(const Key('copy-29')));
    await settle(5);
    expect((await Clipboard.getData('text/plain'))?.text, 'Answer 29.');
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await hover(find.text('Question 28'));
    expect(find.byKey(const Key('bookmark-28')), findsNothing, reason: 'a sent message has none');
    await tester.tap(find.byKey(const Key('copy-28')));
    await settle(5);
    expect((await Clipboard.getData('text/plain'))?.text, 'Question 28');

    // Bookmarks: a reply's button bookmarks the message it answers (saved); a mark at that message's right; the
    // dashes show.
    expect(find.byKey(const Key('bookmark-rail')), findsNothing);
    await hover(find.text('Answer 29.'));
    await tester.tap(find.byKey(const Key('bookmark-29')));
    await settle();
    await hover(find.text('Answer 23.'));
    await tester.tap(find.byKey(const Key('bookmark-23')));
    await settle();
    container(tester).read(chatsProvider.notifier).toggleBookmark(2);
    await settle();
    expect(find.byKey(const Key('bookmark-rail')), findsOneWidget);
    expect(find.byKey(const Key('bookmark-mark')), findsNWidgets(2), reason: 'the two on screen');
    expect(tester.getCenter(find.byKey(const Key('bookmark-mark')).last).dx,
        greaterThan(tester.getRect(find.text('Question 28')).right), reason: 'at the right of the message');
    expect(await saved(dir, (db) => [for (final (i, m) in db.messages('a').indexed) if (m.bookmark) i]), [2, 22, 28]);
    await shot('35-bookmarks-light');

    // Alt+Shift+↑ goes back bookmark by bookmark, up to the first; Alt+Shift+↓ comes back down.
    expect(onScreen('Question 2'), isFalse);
    for (var i = 0; i < 3 && !onScreen('Question 2'); i++) {
      await press(LogicalKeyboardKey.arrowUp, alt: true, shift: true);
    }
    expect(onScreen('Question 2'), isTrue, reason: 'at the first bookmark');
    await press(LogicalKeyboardKey.arrowDown, alt: true, shift: true);
    expect(onScreen('Question 2'), isFalse, reason: 'on to the next bookmark');
    expect(onScreen('Question 22'), isTrue);

    // The dashes: the pointer on them opens the card with the bookmarks' names; a click slides there.
    await hover(find.byKey(const Key('bookmark-rail')));
    expect(find.byKey(const Key('bookmark-card')), findsOneWidget);
    await shot('36-bookmark-card-light');
    await tester.tap(find.byKey(const Key('bookmark-row-2')));
    await settle(40);
    expect(onScreen('Question 2'), isTrue);
    await mouse.moveTo(const Offset(1, 1));
    await settle(20);
    expect(find.byKey(const Key('bookmark-card')), findsNothing, reason: 'closes when the pointer leaves');
    // Taken off again from its reply's button.
    await hover(find.text('Answer 3.'));
    await tester.tap(find.byKey(const Key('bookmark-3')));
    await settle();
    expect(await saved(dir, (db) => [for (final (i, m) in db.messages('a').indexed) if (m.bookmark) i]), [22, 28]);

    // Drafts: each chat keeps its own, and so does the new chat.
    await tester.enterText(box, 'draft for a');
    await openChat('Other chat');
    expect(boxText(), '');
    await tester.enterText(box, 'draft for b');
    await openChat('Long chat');
    expect(boxText(), 'draft for a');
    await press(LogicalKeyboardKey.keyN, ctrl: true);
    expect(boxText(), '', reason: 'the new chat has its own');
    await tester.enterText(box, 'a new one');
    await openChat('Other chat');
    expect(boxText(), 'draft for b');
    await press(LogicalKeyboardKey.keyN, ctrl: true);
    expect(boxText(), 'a new one');

    // ... and they are there after a restart.
    await wait(tester, 800);
    await tester.pumpWidget(await app(dir, backend));
    await wait(tester, 1500);
    expect(boxText(), 'a new one');
    await openChat('Long chat');
    expect(boxText(), 'draft for a');

    // The bell: rings when a reply finishes; not for a reply stopped; not while off. Sending empties the draft.
    CountingChime chime() => container(tester).read(chimeProvider) as CountingChime;
    await openChat('Other chat');
    await tester.enterText(box, 'Tell me something');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await waitUntil(tester, () => container(tester).read(chatsProvider).replyingId == null, timeoutMs: 10000);
    await settle();
    expect(chime().rings, 1);
    expect(container(tester).read(draftsProvider).containsKey('b'), isFalse, reason: 'sent: no draft');
    // (Slow, so it is still being written when stopped.)
    backend.speed.value = 2;
    await tester.enterText(box, 'Another');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await wait(tester, 300);
    await tester.tap(find.byKey(const Key('stop')));
    await settle();
    backend.speed.value = 40;
    expect(chime().rings, 1, reason: 'stopped: no sound');
    await tester.tap(find.byKey(const Key('bell')));
    await settle();
    expect(container(tester).read(prefsProvider).bell, isFalse);
    await tester.enterText(box, 'Once more');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await waitUntil(tester, () => container(tester).read(chatsProvider).replyingId == null, timeoutMs: 10000);
    await settle();
    expect(chime().rings, 1, reason: 'the bell is off');
    await tester.tap(find.byKey(const Key('bell')));
    await settle();

    await mouse.removePointer();
    deleteTestDir(dir);
  });
}

/// Moves a list by [dy] (down when positive), within its ends.
void _jumpBy(ScrollPosition p, double dy) => p.jumpTo((p.pixels + dy).clamp(p.minScrollExtent, p.maxScrollExtent));
