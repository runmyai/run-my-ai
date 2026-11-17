// Versions of a message in the chats database (lib/data/chat_db.dart): a chat is a tree, an edited message or a reply
// written again is a new version that keeps its own later messages, the version shown at each place is saved, search
// finds every version, and chats saved before versions existed open as one path.
// Run: flutter test test/chat_tree_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/data/chat_db.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/search/chat_search.dart';
import 'package:sqlite3/sqlite3.dart';

ChatInfo _info(String id) => ChatInfo(id: id, title: 'chat $id', createdAt: DateTime(2026), updatedAt: DateTime(2026));

ChatMessage _user(String text, {String? conv}) => ChatMessage(Role.user, text, conv: conv);
ChatMessage _bot(String text, {String? conv}) => ChatMessage(Role.assistant, text, conv: conv);

List<String> _texts(ChatDb db, String id) => [for (final m in db.messages(id)) m.text];

/// A chat 'a' with two exchanges (nodes 0 to 3): question one, answer one, question two, answer two.
ChatDb _twoExchanges() {
  final db = ChatDb.inMemory()..createChat(_info('a'));
  db
    ..addMessage('a', 0, _user('question one'))
    ..addMessage('a', 1, _bot('answer one'))
    ..addMessage('a', 2, _user('question two'))
    ..addMessage('a', 3, _bot('answer two'));
  return db;
}

void main() {
  group('a chat with no versions', () {
    test('reads as before: every message one version, in order, and the next number after the last', () {
      final db = _twoExchanges();
      final path = db.path('a');
      expect([for (final m in path.messages) m.text], ['question one', 'answer one', 'question two', 'answer two']);
      expect([for (final m in path.messages) m.node], [0, 1, 2, 3]);
      expect(path.messages.every((m) => m.versions == 1 && m.version == 0 && m.conv == null), isTrue);
      expect(path.nextNode, 4);
      expect(db.path('nobody').messages, isEmpty);
    });
  });

  group('versions', () {
    test('an edited message is a new version, shown; the old one keeps its later messages', () {
      final db = _twoExchanges();
      // Question two edited: a new message after answer one, with its own reply, in a branch of its own.
      db
        ..addMessage('a', 4, _user('question two, edited', conv: 'a-b1'), parent: 1)
        ..addMessage('a', 5, _bot('answer to the edit', conv: 'a-b1'), parent: 4);
      var path = db.path('a');
      expect([for (final m in path.messages) m.text],
          ['question one', 'answer one', 'question two, edited', 'answer to the edit']);
      expect([for (final m in path.messages) (m.version, m.versions)], [(0, 1), (0, 1), (1, 2), (0, 1)]);
      expect(path.messages.last.conv, 'a-b1');
      expect(path.nextNode, 6);

      path = db.flip('a', 4, -1);
      expect([for (final m in path.messages) m.text], ['question one', 'answer one', 'question two', 'answer two']);
      expect(path.messages[2].version, 0);
      expect(db.flip('a', 2, -1).messages[2].text, 'question two', reason: 'no version before the first');
      expect(db.flip('a', 2, 1).messages[2].text, 'question two, edited');
      expect(db.flip('a', 4, 1).messages[2].text, 'question two, edited', reason: 'none after the last');
      expect(_texts(db, 'a'), hasLength(4));
    });

    test('a reply written again is a version of the reply, from the same messages before it', () {
      final db = _twoExchanges();
      db.addMessage('a', 4, _bot('answer two, again', conv: 'a-b1'), parent: 2);
      final shown = db.path('a').messages;
      expect(shown.last.text, 'answer two, again');
      expect((shown.last.version, shown.last.versions), (1, 2));
      expect(db.flip('a', 4, -1).messages.last.text, 'answer two');
    });

    test('a first message can have versions too, each with its own chat after it', () {
      final db = _twoExchanges();
      db
        ..addMessage('a', 4, _user('another start', conv: 'a-b1'), parent: ChatDb.noParent)
        ..addMessage('a', 5, _bot('another answer', conv: 'a-b1'), parent: 4);
      expect(_texts(db, 'a'), ['another start', 'another answer']);
      expect(db.flip('a', 4, -1).messages, hasLength(4));
      expect(db.flip('a', 0, 1).messages.first.text, 'another start');
    });

    test('the version shown at each place is saved: a deeper choice comes back after flipping above it', () {
      final db = _twoExchanges();
      // Question two has two versions; under the first, answer two has two versions.
      db
        ..addMessage('a', 4, _user('edited', conv: 'a-b1'), parent: 1)
        ..addMessage('a', 5, _bot('answer to the edit', conv: 'a-b1'), parent: 4)
        ..addMessage('a', 6, _bot('answer two, again', conv: 'a-b2'), parent: 2);
      expect(_texts(db, 'a').last, 'answer to the edit', reason: 'the newest message made at the place above');
      // Show the original question, which shows the reply written again (the last chosen under it).
      expect(db.flip('a', 4, -1).messages.map((m) => m.text).toList(),
          ['question one', 'answer one', 'question two', 'answer two, again']);
      db.flip('a', 6, -1);
      expect(_texts(db, 'a').last, 'answer two');
      db.flip('a', 2, 1);
      expect(_texts(db, 'a').last, 'answer to the edit');
      expect(db.flip('a', 4, -1).messages.last.text, 'answer two', reason: 'the choice under it was kept');
    });

    test('what was chosen is there when the database is opened again', () {
      final dir = Directory.systemTemp.createTempSync('runmyai-tree-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final folder = Directory('${dir.path}/chats');
      var db = ChatDb.open(dir, folder)..createChat(_info('a'));
      db
        ..addMessage('a', 0, _user('q'))
        ..addMessage('a', 1, _bot('first answer'))
        ..addMessage('a', 2, _bot('second answer', conv: 'a-b1'), parent: 0);
      db.flip('a', 2, -1);
      db.close();
      db = ChatDb.open(dir, folder);
      expect(_texts(db, 'a'), ['q', 'first answer']);
      expect(db.path('a').nextNode, 3);
      expect(db.branches(), {
        'a': ['a-b1']
      });
      db.close();
    });

    test('a message saved again keeps its place and its version, and its words in the index follow its text', () async {
      final db = _twoExchanges();
      db.addMessage('a', 4, _bot('regenerated zebra', conv: 'a-b1'), parent: 2);
      db.addMessage('a', 4, _bot('regenerated giraffe', conv: 'a-b1'));
      expect(db.path('a').messages.last.text, 'regenerated giraffe');
      expect(db.path('a').messages.last.versions, 2);
      expect(await db.search(SearchQuery.parse('zebra')), isEmpty);
      expect(await db.search(SearchQuery.parse('giraffe')), hasLength(1));
    });

    test('removing a message removes what follows it, and the version before comes back', () async {
      final db = _twoExchanges();
      db
        ..addMessage('a', 4, _user('edited zebra', conv: 'a-b1'), parent: 1)
        ..addMessage('a', 5, _bot('reply to it', conv: 'a-b1'), parent: 4);
      db.removeMessage('a', 4);
      expect(_texts(db, 'a'), ['question one', 'answer one', 'question two', 'answer two']);
      expect(db.path('a').messages[2].versions, 1);
      expect(await db.search(SearchQuery.parse('zebra')), isEmpty);
      expect(await db.search(SearchQuery.parse('reply')), isEmpty);
    });

    test('the branches of each chat are listed, and not the chat\'s own id', () {
      final db = _twoExchanges()..createChat(_info('b'));
      db
        ..addMessage('a', 4, _bot('again', conv: 'a-b1'), parent: 2)
        ..addMessage('a', 5, _bot('and again', conv: 'a-b2'), parent: 2)
        ..addMessage('b', 0, _user('hi'));
      expect(db.branches(), {
        'a': ['a-b1', 'a-b2']
      });
    });
  });

  group('search', () {
    test('finds the text of every version, and opening a hit shows that version', () async {
      final db = _twoExchanges();
      db
        ..addMessage('a', 4, _user('question about zebras', conv: 'a-b1'), parent: 1)
        ..addMessage('a', 5, _bot('a reply', conv: 'a-b1'), parent: 4);
      // The edited version is shown now; flip back to the first, then ask for a hit in the second.
      db.flip('a', 4, -1);
      expect(_texts(db, 'a')[2], 'question two');
      final hits = (await db.search(SearchQuery.parse('zebras')))!;
      expect(hits.map((h) => h.chatId), ['a']);
      expect(hits.single.messageIndex, 4, reason: 'the message\'s number in the chat');
      final path = db.pathTo('a', hits.single.messageIndex!);
      expect(path.messages.map((m) => m.text), ['question one', 'answer one', 'question about zebras', 'a reply']);
      expect(path.messages.indexWhere((m) => m.node == 4), 2);
      expect(_texts(db, 'a')[2], 'question about zebras', reason: 'the chat now opens on that version');
    });
  });

  group('chats saved before versions', () {
    test('open as one path each, with nothing lost, in the order they were saved', () async {
      final dir = Directory.systemTemp.createTempSync('runmyai-tree-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = '${dir.path}/chats.db';
      // A database as the version before this one wrote it.
      final old = sqlite3.open(file);
      old.execute('''
        CREATE TABLE chats (id TEXT PRIMARY KEY, num INTEGER NOT NULL UNIQUE, title TEXT NOT NULL,
          created INTEGER NOT NULL, updated INTEGER NOT NULL, pin INTEGER, kind INTEGER NOT NULL DEFAULT 0,
          sort REAL, archived INTEGER, model TEXT, context INTEGER);
        CREATE TABLE messages (id INTEGER PRIMARY KEY, role INTEGER NOT NULL, text TEXT NOT NULL, bookmark INTEGER,
          thinking TEXT, thinking_ms INTEGER, stopped INTEGER);
        CREATE VIRTUAL TABLE messages_fts USING fts5(words, content = '', contentless_delete = 1, detail = none,
          tokenize = 'unicode61 remove_diacritics 0', prefix = '1 2 3');
        CREATE TABLE benchmarks (id INTEGER PRIMARY KEY AUTOINCREMENT, data TEXT NOT NULL);
      ''');
      void chat(String id, int num) =>
          old.execute('INSERT INTO chats (id, num, title, created, updated) VALUES (?, ?, ?, 0, 0)', [id, num, 'chat $id']);
      void message(int num, int place, int role, String text, {int? bookmark, String? thinking, int? stopped}) {
        final id = (num << 20) | place;
        old.execute('INSERT INTO messages (id, role, text, bookmark, thinking, thinking_ms, stopped) VALUES (?, ?, ?, ?, ?, ?, ?)',
            [id, role, text, bookmark, thinking, thinking == null ? null : 900, stopped]);
        old.execute('INSERT INTO messages_fts (rowid, words) VALUES (?, ?)', [id, searchWords(text)]);
      }

      chat('a', 1);
      message(1, 0, 0, 'hello zebra', bookmark: 1);
      message(1, 1, 1, 'hi there', thinking: 'let me see');
      message(1, 2, 0, 'second question');
      message(1, 3, 1, 'second answer', stopped: 1);
      chat('b', 2);
      // (A gap: place 2 is missing.)
      message(2, 0, 0, 'b one');
      message(2, 1, 1, 'b two');
      message(2, 3, 0, 'b four');
      chat('c', 3);
      old.userVersion = 11;
      old.close();

      final db = ChatDb.open(dir, Directory('${dir.path}/chats'));
      final a = db.path('a');
      expect(a.messages.map((m) => m.text), ['hello zebra', 'hi there', 'second question', 'second answer']);
      expect(a.messages.map((m) => m.node), [0, 1, 2, 3]);
      expect(a.messages.every((m) => m.versions == 1 && m.version == 0 && m.conv == null), isTrue);
      expect(a.messages.map((m) => m.bookmark), [true, false, false, false]);
      expect(a.messages[1].thinking, 'let me see');
      expect(a.messages[1].thinkingMillis, 900);
      expect(a.messages[3].stopped, isTrue);
      expect(a.nextNode, 4);
      expect(db.messages('b').map((m) => m.text), ['b one', 'b two', 'b four']);
      expect(db.path('b').nextNode, 4);
      expect(db.messages('c'), isEmpty);
      expect(db.branches(), isEmpty);

      // Search still finds them, and a message added after the upgrade follows the last one.
      expect((await db.search(SearchQuery.parse('zebra')))!.map((h) => h.chatId), ['a']);
      db.addMessage('a', 4, _user('third zebra question'), parent: 3);
      expect(_texts(db, 'a').last, 'third zebra question');
      expect(db.path('a').messages.every((m) => m.versions == 1), isTrue);
      expect((await db.search(SearchQuery.parse('zebra')))!.single.messageIndex, 0);
      db.close();

      // Opening it again does not run the upgrade a second time.
      final again = ChatDb.open(dir, Directory('${dir.path}/chats'));
      expect(_texts(again, 'a'), hasLength(5));
      again.close();
    });
  });
}
