// The drafts (lib/state/drafts.dart): kept per chat and saved; and the bell (lib/system/chime.dart): it rings only
// while on.
// Run: flutter test test/drafts_bell_test.dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/drafts.dart';
import 'package:runmyai/state/prefs.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/system/chime.dart';

/// The chat list, without the database behind it.
class _Chats extends ChatsNotifier {
  @override
  ChatsState build() => ChatsState(chats: [
        for (final id in ['a', 'b']) ChatInfo(id: id, title: id, createdAt: DateTime(2026), updatedAt: DateTime(2026)),
      ]);

  void remove(String id) => state = state.copyWith(chats: [for (final c in state.chats) if (c.id != id) c]);
}

/// Counts the sounds instead of playing them.
class _Chime extends Chime {
  _Chime(Ref ref) : super(ref, null, Duration.zero);

  int rings = 0;

  @override
  Future<void> play() async => rings++;
}

void main() {
  late Directory dir;
  late ProviderContainer container;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('runmyai-drafts-');
    container = ProviderContainer(overrides: [
      storageProvider.overrideWithValue(Storage(dir)),
      chatsProvider.overrideWith(_Chats.new),
      chimeProvider.overrideWith(_Chime.new),
    ]);
  });
  tearDown(() {
    container.dispose();
    dir.deleteSync(recursive: true);
  });

  test('each chat, and each section\'s new chat, has its own draft', () {
    expect(draftKey('a', ChatKind.chat), 'a');
    expect(draftKey(null, ChatKind.chat), 'new:chat');
    expect(draftKey(null, ChatKind.code), 'new:code');
    final drafts = container.read(draftsProvider.notifier);
    drafts.set('a', 'half a thought');
    drafts.set('new:chat', 'a new one');
    drafts.set('new:code', 'some code');
    expect(container.read(draftsProvider), {'a': 'half a thought', 'new:chat': 'a new one', 'new:code': 'some code'});
    drafts.set('a', '');
    expect(container.read(draftsProvider).containsKey('a'), isFalse, reason: 'emptied (sent): no draft');
  });

  test('saved half a second after the typing stops; read back at start', () async {
    Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));
    final drafts = container.read(draftsProvider.notifier);
    drafts.set('a', 'h');
    await wait(300);
    drafts.set('a', 'hello');
    await wait(300);
    expect(Storage(dir).readDrafts(), isEmpty, reason: 'still typing');
    await wait(400);
    expect(Storage(dir).readDrafts(), {'a': 'hello'});
    final again = ProviderContainer(overrides: [
      storageProvider.overrideWithValue(Storage(dir)),
      chatsProvider.overrideWith(_Chats.new),
    ]);
    expect(again.read(draftsProvider), {'a': 'hello'});
    again.dispose();
  });

  test('a deleted chat\'s draft goes with it; the new chats\' drafts stay', () {
    final drafts = container.read(draftsProvider.notifier);
    drafts.set('a', 'one');
    drafts.set('b', 'two');
    drafts.set('new:chat', 'three');
    (container.read(chatsProvider.notifier) as _Chats).remove('a');
    expect(container.read(draftsProvider), {'b': 'two', 'new:chat': 'three'});
  });

  test('the bell rings for a finished reply while on, not while off; the choice is saved', () {
    final chime = container.read(chimeProvider) as _Chime;
    expect(container.read(prefsProvider).bell, isTrue, reason: 'on at first');
    chime.replyDone();
    expect(chime.rings, 1);
    container.read(prefsProvider.notifier).toggleBell();
    chime.replyDone();
    expect(chime.rings, 1, reason: 'off');
    expect(Storage(dir).readPrefs().bell, isFalse);
  });
}
