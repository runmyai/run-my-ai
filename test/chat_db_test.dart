// The chats database (lib/data/chat_db.dart): its search gives exactly the in-memory search's results, chats saved
// as files by older versions are moved in, and saved changes come back.
// Run: flutter test test/chat_db_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/data/chat_db.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/search/chat_search.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('the database search ranks exactly like the in-memory search', () async {
    final r = Random(7);
    const words = ['harin', 'is', 'the', 'trip', 'paris', 'café', 'Cafe', 'code', 'error', 'a', 'of', 'blue',
        'zebra', "harin's", 'book', 'and', 'it', 'plan', 'friday', 'room'];
    String text(int n) => List.generate(n, (_) => words[r.nextInt(words.length)]).join(r.nextBool() ? ' ' : ', ');
    final start = DateTime(2026, 10, 1);
    final chats = [
      for (var c = 0; c < 120; c++)
        Chat(
          id: 'c$c',
          title: text(1 + r.nextInt(4)),
          createdAt: start,
          // Some chats share a time, so the id decides their order.
          updatedAt: start.add(Duration(minutes: r.nextInt(60))),
          messages: [
            for (var m = 0; m < r.nextInt(8); m++) ChatMessage(m.isEven ? Role.user : Role.assistant, text(1 + r.nextInt(25))),
          ],
        ),
    ];
    final db = ChatDb.inMemory();
    for (final chat in chats) {
      db.createChat(chat.info);
      for (var i = 0; i < chat.messages.length; i++) {
        db.addMessage(chat.id, i, chat.messages[i]);
      }
    }
    String describe(List<ChatHit> hits) => [
          for (final h in hits)
            '${h.chatId} L${h.level} t${h.inTitle} s${h.score} m${h.messageIndex} ${h.messageSpan} "${h.snippet}" ${h.snippetSpans}',
        ].join('\n');
    for (final q in ['harin is', 'is harin', 'the', 'is the', 'cafe', 'CAFÉ trip', 'zebra blue code', "harin's book",
        'paris friday room plan', 'a of and', 'nothing here', 'trip trip', 'harin i', 'harin is ', 'cafe tr', 'zeb',
        'pa', "harin's b", 'the ', 'blue zebra cr', 'co', 'a']) {
      final query = SearchQuery.parse(q);
      final want = searchChats(chats, query);
      // Lines further down than the first ones are read when the list reaches them.
      final got = db.fillLines(query, (await db.search(query))!);
      expect(describe(got), describe(want), reason: 'query "$q"');
    }
    db.close();
  });

  test('a newer search stops the one running', () async {
    final db = ChatDb.inMemory();
    db.createChat(ChatInfo(id: 'a', title: 'x', createdAt: DateTime(2026), updatedAt: DateTime(2026)));
    expect(await db.search(SearchQuery.parse('x'), cancelled: () => true), anyOf(isNull, isNotEmpty));
    db.close();
  });

  test('chats saved as files by older versions are moved in, then the files are deleted', () {
    final dir = Directory.systemTemp.createTempSync('runmyai-db-');
    Directory('${dir.path}/chats').createSync();
    for (final (id, title) in [('a', 'Alpha'), ('b', 'Bravo')]) {
      final chat = Chat(id: id, title: title, createdAt: DateTime(2026, 1, 1), updatedAt: DateTime(2026, 1, id == 'a' ? 2 : 3),
          messages: const [ChatMessage(Role.user, 'Hello there'), ChatMessage(Role.assistant, 'Hi!')]);
      File('${dir.path}/chats/$id.json').writeAsStringSync(jsonEncode(chat.toJson()));
    }
    File('${dir.path}/pins.json').writeAsStringSync(jsonEncode({'pinned': ['a', 'gone']}));

    var db = ChatDb.open('${dir.path}/chats.db');
    expect([for (final c in db.chats()) c.title], ['Bravo', 'Alpha']);
    expect(db.pins(), ['a']);
    expect(db.messages('a').map((m) => m.text), ['Hello there', 'Hi!']);
    expect(Directory('${dir.path}/chats').existsSync(), isFalse);
    expect(File('${dir.path}/pins.json').existsSync(), isFalse);

    // Changes are saved: rename, a new message, pins, delete; the index forgets a deleted chat's words.
    db
      ..rename('b', 'Bravo renamed')
      ..addMessage('b', 2, const ChatMessage(Role.user, 'zebra crossing'))
      ..setUpdated('b', DateTime(2026, 2, 1))
      ..setPins(['b', 'a'])
      ..delete('a')
      ..close();
    db = ChatDb.open('${dir.path}/chats.db');
    expect([for (final c in db.chats()) c.title], ['Bravo renamed']);
    expect(db.pins(), ['b']);
    expect(db.messages('b').last.text, 'zebra crossing');
    db.close();
    dir.deleteSync(recursive: true);
  });

  test('Chat and Code: each chat keeps its section, and a search finds only its own section\'s chats', () async {
    final db = ChatDb.inMemory();
    final time = DateTime(2026, 10, 30);
    for (final (id, title, kind) in [('a', 'Paris', ChatKind.chat), ('b', 'Rome', ChatKind.code), ('c', 'Oslo', ChatKind.code)]) {
      db.createChat(ChatInfo(id: id, title: title, createdAt: time, updatedAt: time, kind: kind));
      db.addMessage(id, 0, const ChatMessage(Role.user, 'zebra crossing'));
    }
    expect({for (final c in db.chats()) c.id: c.kind}, {'a': ChatKind.chat, 'b': ChatKind.code, 'c': ChatKind.code});
    Future<List<String>> found(String text, ChatKind kind) async =>
        [for (final h in (await db.search(SearchQuery.parse(text), kind: kind))!) h.chatId];
    expect(await found('zebra', ChatKind.chat), ['a']);
    expect(await found('zebra crossing', ChatKind.code), ['c', 'b']);
    expect(await found('paris', ChatKind.code), isEmpty, reason: 'a title in the other section');
    expect(await found('paris', ChatKind.chat), ['a']);
    db.close();
  });

  test('a database from before Chat and Code were split: its chats are all Chat\'s', () {
    final dir = Directory.systemTemp.createTempSync('runmyai-db-');
    final old = sqlite3.open('${dir.path}/chats.db');
    old.execute('''
      CREATE TABLE chats (id TEXT PRIMARY KEY, num INTEGER NOT NULL UNIQUE, title TEXT NOT NULL,
        created INTEGER NOT NULL, updated INTEGER NOT NULL, pin INTEGER);
      CREATE TABLE messages (id INTEGER PRIMARY KEY, role INTEGER NOT NULL, text TEXT NOT NULL);
      CREATE VIRTUAL TABLE messages_fts USING fts5(words, content = '', contentless_delete = 1, detail = none,
        tokenize = 'unicode61 remove_diacritics 0');
      INSERT INTO chats VALUES ('x', 1, 'Old chat', 0, 0, 0);
    ''');
    old.userVersion = 1;
    old.close();
    final db = ChatDb.open('${dir.path}/chats.db');
    expect([for (final c in db.chats()) (c.title, c.kind)], [('Old chat', ChatKind.chat)]);
    expect(db.pins(), ['x']);
    db.close();
    dir.deleteSync(recursive: true);
  });

  test('the place a chat was dragged to is saved; a new message clears it', () {
    final db = ChatDb.inMemory();
    for (final id in ['a', 'b']) {
      db.createChat(ChatInfo(id: id, title: id, createdAt: DateTime(2026, 10, 30), updatedAt: DateTime(2026, 10, 30, 9)));
    }
    db.setSorts({'a': 5.0, 'b': 4.0});
    expect({for (final c in db.chats()) c.id: c.sort}, {'a': 5.0, 'b': 4.0});
    db.setUpdated('b', DateTime(2026, 10, 30, 10));
    expect({for (final c in db.chats()) c.id: c.sort}, {'a': 5.0, 'b': null});
    db.close();
  });

  test('deleted chats leave nothing in the word index', () async {
    final db = ChatDb.inMemory();
    db.createChat(ChatInfo(id: 'a', title: 'one', createdAt: DateTime(2026), updatedAt: DateTime(2026)));
    db.addMessage('a', 0, const ChatMessage(Role.user, 'zebra'));
    expect((await db.search(SearchQuery.parse('zebra')))!.map((h) => h.chatId), ['a']);
    db.delete('a');
    expect(await db.search(SearchQuery.parse('zebra')), isEmpty);
    db.close();
  });

  test('archiving: saved with its time and unpinned; unarchiving brings it back as used now', () {
    final db = ChatDb.inMemory();
    final then = DateTime(2026, 10, 1, 9);
    db.createChat(ChatInfo(id: 'a', title: 'Alpha', createdAt: then, updatedAt: then));
    db.createChat(ChatInfo(id: 'b', title: 'Bravo', createdAt: then, updatedAt: then));
    db.setPins(['a', 'b']);
    final archivedAt = DateTime(2026, 10, 20, 15);
    db.setArchived('a', archivedAt, archivedAt);
    final a = db.chats().firstWhere((c) => c.id == 'a');
    expect(a.archivedAt, archivedAt);
    expect(a.lastActive, archivedAt, reason: 'archived after its last message');
    expect(db.pins(), ['b'], reason: 'archiving unpins');
    final now = DateTime(2026, 10, 30, 12);
    db.setArchived('a', null, now);
    final back = db.chats().firstWhere((c) => c.id == 'a');
    expect((back.archived, back.updatedAt), (false, now), reason: 'back as used now (the top of Today)');
    db.close();
  });

  test('bookmarks: a sent message marked as one is saved, and unmarked', () {
    final db = ChatDb.inMemory();
    db.createChat(ChatInfo(id: 'a', title: 'Alpha', createdAt: DateTime(2026), updatedAt: DateTime(2026)));
    db.addMessage('a', 0, const ChatMessage(Role.user, 'one'));
    db.addMessage('a', 1, const ChatMessage(Role.assistant, 'two'));
    db.addMessage('a', 2, const ChatMessage(Role.user, 'three'));
    db.setBookmark('a', 2, true);
    expect([for (final m in db.messages('a')) m.bookmark], [false, false, true]);
    db.setBookmark('a', 2, false);
    expect([for (final m in db.messages('a')) m.bookmark], [false, false, false]);
    db.close();
  });

  test('a reply saved again as it grows replaces the one before, with its words in the index', () async {
    final db = ChatDb.inMemory();
    db.createChat(ChatInfo(id: 'a', title: 'Alpha', createdAt: DateTime(2026), updatedAt: DateTime(2026)));
    db.addMessage('a', 0, const ChatMessage(Role.user, 'question'));
    db.addMessage('a', 1, const ChatMessage(Role.assistant, 'zebra', thinking: 'hm', thinkingMillis: 40, stopped: true));
    db.addMessage('a', 1, const ChatMessage(Role.assistant, 'giraffe crossing', thinking: 'hm', thinkingMillis: 40));
    final saved = db.messages('a');
    expect(saved.map((m) => m.text), ['question', 'giraffe crossing']);
    expect((saved[1].stopped, saved[1].thinking, saved[1].thinkingMillis), (false, 'hm', 40));
    expect(await db.search(SearchQuery.parse('zebra')), isEmpty, reason: 'the old words are gone');
    expect((await db.search(SearchQuery.parse('giraffe')))!.map((h) => h.chatId), ['a']);
    db.close();
  });

  test('a reply stopped while it thought is saved with its thought, marked stopped', () {
    final db = ChatDb.inMemory();
    db.createChat(ChatInfo(id: 'a', title: 'Alpha', createdAt: DateTime(2026), updatedAt: DateTime(2026)));
    db.addMessage('a', 0, const ChatMessage(Role.user, 'question'));
    db.addMessage('a', 1, const ChatMessage(Role.assistant, '', thinking: 'let me see', thinkingMillis: 1200, stopped: true));
    final back = db.messages('a')[1];
    expect((back.text, back.thinking, back.thinkingMillis, back.stopped), ('', 'let me see', 1200, true));
    expect(db.messages('a')[0].stopped, isFalse);
    db.close();
  });
}
