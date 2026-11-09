// What the keyboard shortcuts walk and change: the sidebar's order for Alt+↑ / Alt+↓ (lib/ui/chat_list.dart), and
// the text size for Ctrl+= / Ctrl+- / Ctrl+0 (lib/state/prefs.dart).
// Run: flutter test test/shortcuts_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/prefs.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/ui/chat_list.dart';

void main() {
  final today = DateTime(2026, 10, 31);
  ChatInfo chat(String id, DateTime at, {DateTime? archivedAt}) =>
      ChatInfo(id: id, title: id, createdAt: at, updatedAt: at, archivedAt: archivedAt);
  final chats = sortChats([
    chat('a', DateTime(2026, 10, 31, 12)),
    chat('b', DateTime(2026, 10, 31, 11)),
    chat('c', DateTime(2026, 10, 30, 12)),
    chat('d', DateTime(2026, 10, 30, 11)),
    chat('e', DateTime(2026, 10, 28, 9)),
    chat('x', DateTime(2026, 10, 29), archivedAt: DateTime(2026, 10, 29, 1)),
  ]);

  test('the order is the sidebar\'s: Pinned, then each day; a pinned chat once; archived chats left out', () {
    final state = ChatsState(chats: chats, pinned: const ['c']);
    expect(listOrder(state, today, const {}, archive: false), ['c', 'a', 'b', 'd', 'e']);
  });

  test('a folded group\'s chats are left out, but for the open chat (it stays in sight)', () {
    final state = ChatsState(chats: chats, pinned: const ['c'], openId: 'd');
    expect(listOrder(state, today, const {'pinned', '2026-10-30'}, archive: false), ['a', 'b', 'd', 'e']);
  });

  test('a folded Pinned keeps the open pinned chat in sight (it is only there)', () {
    final state = ChatsState(chats: chats, pinned: const ['c'], openId: 'c');
    expect(listOrder(state, today, const {'pinned'}, archive: false), ['c', 'a', 'b', 'd', 'e']);
  });

  test('in Archived: the archived chats only', () {
    final state = ChatsState(chats: chats);
    expect(listOrder(state, today, const {}, archive: true), ['x']);
  });

  group('text size', () {
    late Directory dir;
    late ProviderContainer container;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('runmyai-shortcuts-');
      container = ProviderContainer(overrides: [storageProvider.overrideWithValue(Storage(dir))]);
    });
    tearDown(() {
      container.dispose();
      dir.deleteSync(recursive: true);
    });
    double scale() => container.read(prefsProvider).textScale;

    test('steps up and down through the sizes, stops at the ends, and Ctrl+0 is normal; each change is saved', () {
      final prefs = container.read(prefsProvider.notifier);
      expect(scale(), 1);
      prefs.stepTextScale(1);
      expect(scale(), 1.1);
      for (var i = 0; i < 10; i++) {
        prefs.stepTextScale(1);
      }
      expect(scale(), Prefs.textScales.last);
      expect(Storage(dir).readPrefs().textScale, Prefs.textScales.last);
      prefs.stepTextScale(0);
      expect(scale(), 1);
      for (var i = 0; i < 10; i++) {
        prefs.stepTextScale(-1);
      }
      expect(scale(), Prefs.textScales.first);
      expect(Storage(dir).readPrefs().textScale, Prefs.textScales.first);
    });

    test('Dark 2 and 3 are saved as the theme ("dark2", "dark3") and read back; Dark is plain dark', () {
      final prefs = container.read(prefsProvider.notifier);
      for (final style in ['dark2', 'dark3']) {
        prefs.setTheme(ThemeMode.dark, darkStyle: style);
        expect(Storage(dir).readPrefs().theme, style);
        final again = ProviderContainer(overrides: [storageProvider.overrideWithValue(Storage(dir))]);
        expect((again.read(prefsProvider).theme, again.read(prefsProvider).darkStyle), (ThemeMode.dark, style));
        again.dispose();
      }
      prefs.setTheme(ThemeMode.dark);
      expect((Storage(dir).readPrefs().theme, container.read(prefsProvider).darkStyle), ('dark', 'dark'));
    });

    test('nothing picked: following the computer, with Run My AI Dark as the dark; the old Dark 4 and dark Pick trials are it too', () {
      expect(
        (container.read(prefsProvider).theme, container.read(prefsProvider).darkStyle),
        (ThemeMode.system, 'dark3'),
      );
      for (final trial in ['dark4', 'dpick4']) {
        Storage(dir).writePrefs(PrefsData(theme: trial));
        final again = ProviderContainer(overrides: [storageProvider.overrideWithValue(Storage(dir))]);
        expect((again.read(prefsProvider).theme, again.read(prefsProvider).darkStyle), (ThemeMode.dark, 'dark3'));
        again.dispose();
      }
    });

    test('the light themes are saved as the theme and read back; the old "light" is Run My AI Light', () {
      final prefs = container.read(prefsProvider.notifier);
      for (final style in ['light', 'silklight', 'dusk']) {
        prefs.setTheme(ThemeMode.light, lightStyle: style);
        expect(Storage(dir).readPrefs().theme, style);
        final again = ProviderContainer(overrides: [storageProvider.overrideWithValue(Storage(dir))]);
        expect((again.read(prefsProvider).theme, again.read(prefsProvider).lightStyle), (ThemeMode.light, style));
        again.dispose();
      }
    });

    test('a saved size is used at start; one between the steps goes to the nearest', () {
      Storage(dir).writePrefs(const PrefsData(textScale: 1.18));
      expect(scale(), 1.2);
    });
  });
}
