// The reply-finished sound (lib/system/chime.dart) and its settings (lib/ui/pages/settings_page.dart), with a stand-in
// for the app's sound player (native/sound.c, checked on its own).
// Run: flutter test test/sound_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/prefs.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/system/chime.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/pages/settings_page.dart';

/// Records what it is asked to play; files named "broken" cannot be played.
class _Player implements SoundPlayer {
  final played = <String>[];
  int stops = 0;
  bool on = false;

  @override
  bool check(String path) => !path.contains('broken');

  @override
  bool play(String path) {
    if (!check(path)) return false;
    played.add(path.split('/').last);
    on = true;
    return true;
  }

  @override
  bool get playing => on;

  @override
  void stop() {
    stops++;
    on = false;
  }
}

void main() {
  late Directory dir;
  late _Player player;
  late ProviderContainer container;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('runmyai-sound-');
    player = _Player();
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        chimeProvider.overrideWith((ref) => Chime(ref, player)),
        shownModelProvider.overrideWithValue(null),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    dir.deleteSync(recursive: true);
  });

  Chime chime() => container.read(chimeProvider);

  test('the app\'s own sound plays at first; the user\'s own once chosen; the app\'s again when that cannot play', () {
    chime().play();
    expect(player.played, ['reply-done.mp3']);
    container.read(prefsProvider.notifier).setSound('ding.mp3', 'sounds/custom.mp3');
    chime().play();
    expect(player.played.last, 'custom.mp3');
    container.read(prefsProvider.notifier).setSound('broken.mp3', 'sounds/broken.mp3');
    chime().play();
    expect(player.played.last, 'reply-done.mp3', reason: 'the user\'s file cannot be played');
  });

  test('a finished reply\'s sound comes 0.35 s after it ends; stopped while it waits, it never comes', () async {
    chime().replyDone();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(player.played, isEmpty, reason: 'not yet');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(player.played, ['reply-done.mp3']);
    chime().replyDone();
    container.read(prefsProvider.notifier).setBell(false);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(player.played, hasLength(1), reason: 'the bell went off while it waited');
    chime().stop();
  });

  test('the bell off: no sound, and a sound still playing stops', () {
    chime().play();
    expect(player.playing, isTrue);
    container.read(prefsProvider.notifier).setBell(false);
    expect(player.playing, isFalse, reason: 'stopped');
    chime().replyDone();
    expect(player.played, hasLength(1), reason: 'off: nothing more');
    chime().play();
    expect(player.played, hasLength(2), reason: 'Play in Settings still plays it');
  });

  test('the sound device closes once the sound has ended', () async {
    await chime().play();
    final stops = player.stops;
    player.on = false;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(player.stops, stops + 1);
  });

  test('Reset: the app\'s own sound again, and the copy is deleted', () {
    final copy = File('${dir.path}/sounds/custom.wav')..createSync(recursive: true);
    container.read(prefsProvider.notifier).setSound('mine.wav', 'sounds/custom.wav');
    chime().reset();
    expect((container.read(prefsProvider).soundName, container.read(prefsProvider).soundFile), (null, null));
    expect(copy.existsSync(), isFalse);
    expect(Storage(dir).readPrefs().soundFile, isNull, reason: 'saved');
  });

  testWidgets('Settings: On / Off is the bell; the sound\'s name; Play; Reset only for the user\'s own', (
    tester,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    expect(find.text('Sound: Default', findRichText: true), findsOneWidget);
    expect(find.byKey(const Key('sound-reset')), findsNothing);
    await tester.tap(find.byKey(const Key('sound-off')));
    await tester.pump();
    expect(container.read(prefsProvider).bell, isFalse, reason: 'the same as the bell');
    await tester.tap(find.byKey(const Key('sound-on')));
    await tester.pump();
    expect(container.read(prefsProvider).bell, isTrue);
    await tester.tap(find.byKey(const Key('sound-play')));
    await tester.pump();
    expect(player.played, ['reply-done.mp3']);
    container.read(prefsProvider.notifier).setSound('ding.mp3', 'sounds/custom.mp3');
    await tester.pump();
    expect(find.text('Sound: ding.mp3', findRichText: true), findsOneWidget);
    await tester.tap(find.byKey(const Key('sound-reset')));
    await tester.pump();
    expect(find.text('Sound: Default', findRichText: true), findsOneWidget);
    // (The sound's watch timer.)
    await tester.pump(const Duration(seconds: 1));
    container.read(chimeProvider).stop();
  });
}
