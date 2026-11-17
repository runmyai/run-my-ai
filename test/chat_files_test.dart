// The chats as files (lib/data/chat_db.dart): one file per chat holds everything, the index is made again from the
// files, file names follow the titles, files copied in or deleted by hand are picked up, chats.db of an older version
// is moved into files once, and writes are safe.
// Run: flutter test test/chat_files_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/data/chat_db.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/reply_stats.dart';
import 'package:runmyai/search/chat_search.dart';
import 'package:sqlite3/sqlite3.dart';

late Directory dir;
Directory get folder => Directory('${dir.path}/chats');
ChatDb open() => ChatDb.open(dir, folder);
File chatFile(String name, {String kind = 'Chat'}) => File('${folder.path}/$kind/$name');
List<String> names([String kind = 'Chat']) =>
    [for (final f in Directory('${folder.path}/$kind').listSync()) f.path.split('/').last]..sort();

final t0 = DateTime(2026, 11, 1, 9, 30);
ChatInfo info(String id, String title, {ChatKind kind = ChatKind.chat}) =>
    ChatInfo(id: id, title: title, createdAt: t0, updatedAt: t0, kind: kind);

/// Everything the app reads of a chat, as one text to compare.
String describe(ChatDb db, String id) {
  final c = db.chats().firstWhere((c) => c.id == id);
  final p = db.path(id);
  return [
    '${c.title} ${c.kind} ${c.createdAt} ${c.updatedAt} ${c.sort} ${c.archivedAt} ${c.modelId} ${c.contextLength}',
    'pinned ${db.pins().indexOf(id)} next ${p.nextNode} branches ${db.branches()[id]}',
    for (final m in p.messages)
      '${m.node} ${m.role} ${m.version}/${m.versions} "${m.text}" "${m.thinking}" ${m.thinkingMillis} '
          '${m.bookmark} ${m.stopped} ${m.conv} ${m.stats == null ? null : jsonEncode(m.stats!.toJson())}',
  ].join('\n');
}

Future<List<String>> found(ChatDb db, String text) async =>
    [for (final h in (await db.search(SearchQuery.parse(text)))!) h.chatId];

void main() {
  setUp(() => dir = Directory.systemTemp.createTempSync('runmyai-files-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a chat with versions, branches, stats and every setting comes back whole from its file alone', () async {
    var db = open();
    db
      ..createChat(info('a', 'Trip plan'))
      ..addMessage('a', 0, const ChatMessage(Role.user, 'zebra question'))
      ..addMessage('a', 1, const ChatMessage(Role.assistant, 'first answer', thinking: 'hm', thinkingMillis: 900,
          stats: ReplyStats(wordsPerSecond: 41.5, promptTokens: 12, modelName: 'Flint', contextLength: 65536)))
      ..addMessage('a', 2, const ChatMessage(Role.assistant, 'second answer', stopped: true, conv: 'a-b1'), parent: 0)
      ..addMessage('a', 3, const ChatMessage(Role.user, 'follow up'))
      ..addMessage('a', 4, const ChatMessage(Role.user, 'edited start', conv: 'a-b2'), parent: ChatDb.noParent)
      ..addMessage('a', 5, const ChatMessage(Role.assistant, 'answer to the edit', conv: 'a-b2'))
      ..setBookmark('a', 3, true)
      ..select('a', 3)
      ..setChoices('a', 'flint/q4', 32768)
      ..setUpdated('a', DateTime(2026, 11, 2, 8))
      ..setSorts({'a': 12.5})
      ..createChat(info('b', 'Other', kind: ChatKind.code))
      ..setPins(['b', 'a'])
      ..setArchived('b', DateTime(2026, 11, 3), DateTime(2026, 11, 3));
    final before = {for (final id in ['a', 'b']) id: describe(db, id)};
    final flipped = db.flip('a', 0, 1).messages.map((m) => m.text).toList();
    db.flip('a', 4, -1);
    db.close();
    expect(names(), ['Trip plan.json']);
    expect(names('Code'), ['Other.json']);
    final text = chatFile('Trip plan.json').readAsStringSync();
    expect(jsonDecode(text)['format'], ChatDb.fileFormat);

    // A new computer: only the files.
    for (final f in dir.listSync().whereType<File>()) {
      f.deleteSync();
    }
    db = open();
    expect({for (final id in ['a', 'b']) id: describe(db, id)}, before);
    expect(db.flip('a', 0, 1).messages.map((m) => m.text).toList(), flipped);
    db.flip('a', 4, -1);
    expect(await found(db, 'zebra'), ['a'], reason: 'the word index is made from the files');
    expect(await found(db, 'zeb'), ['a'], reason: 'with partial words');
    // Written again from the index made from it, the file is the same.
    db
      ..rename('a', 'Trip plan')
      ..writeFiles();
    expect(chatFile('Trip plan.json').readAsStringSync(), text);
    db.close();
  });

  test('file names: characters Linux or Windows do not allow, ends, device names, long and empty titles', () {
    expect(chatFileName('What is 2/3 * 4?'), 'What is 2_3 _ 4_');
    expect(chatFileName(r'a\b:c"d<e>f|g'), 'a_b_c_d_e_f_g');
    expect(chatFileName('tab\there\nline\x7f'), 'tab_here_line_');
    expect(chatFileName('  ends with dots... '), 'ends with dots');
    expect(chatFileName('.hidden'), 'hidden');
    expect(chatFileName('CON'), '_CON');
    expect(chatFileName('nul.txt'), '_nul.txt');
    expect(chatFileName('Com1'), '_Com1');
    expect(chatFileName('lpt9 '), '_lpt9');
    expect(chatFileName('Console'), 'Console');
    expect(chatFileName(''), 'Untitled');
    expect(chatFileName(' ... '), 'Untitled');
    expect(chatFileName('Café ✓ 日本'), 'Café ✓ 日本');
    final long = chatFileName('word ' * 60);
    expect(long.length, lessThanOrEqualTo(100));
    expect(long.endsWith(' '), isFalse);
    final wide = chatFileName('日' * 100);
    expect(utf8.encode(wide).length, lessThanOrEqualTo(180));
    expect(chatFileName('😀' * 80), '😀' * 45, reason: 'whole characters (4 bytes each here), never half of one');
    expect(chatFileName('a😀' * 40).length, 100, reason: 'at most 100 UTF-16 units, as Windows counts a name');
  });

  test('duplicates get " (2)", " (3)"; a rename renames the file; a name that still fits is kept', () {
    final db = open();
    for (final id in ['a', 'b', 'c']) {
      db.createChat(info(id, 'Plan'));
    }
    db.createChat(info('d', 'plan')); // the same name to Windows
    db.createChat(info('e', 'Plan', kind: ChatKind.code));
    db.writeFiles();
    expect(names(), ['Plan (2).json', 'Plan (3).json', 'Plan.json', 'plan (4).json']);
    expect(names('Code'), ['Plan.json'], reason: 'each section has its own names');

    db
      ..rename('a', 'Budget: May/June')
      ..writeFiles();
    expect(names(), ['Budget_ May_June.json', 'Plan (2).json', 'Plan (3).json', 'plan (4).json']);
    expect(jsonDecode(chatFile('Budget_ May_June.json').readAsStringSync())['title'], 'Budget: May/June');

    // "Plan" is free now, but chat b keeps "Plan (2)" while its title still fits it.
    db
      ..addMessage('b', 0, const ChatMessage(Role.user, 'hi'))
      ..writeFiles();
    expect(names(), contains('Plan (2).json'));
    // A file of that name copied in while the app runs is never overwritten.
    chatFile('Fresh.json').writeAsStringSync('not ours');
    db
      ..rename('c', 'Fresh')
      ..writeFiles();
    expect(chatFile('Fresh.json').readAsStringSync(), 'not ours');
    expect(names(), contains('Fresh (2).json'));
    db.close();
  });

  test('a file copied in from another computer appears after a scan; a file deleted by hand disappears', () async {
    final other = Directory('${dir.path}/other')..createSync();
    final pcA = ChatDb.open(other, Directory('${other.path}/chats'));
    pcA
      ..createChat(info('x', 'From the laptop'))
      ..addMessage('x', 0, const ChatMessage(Role.user, 'giraffe crossing'))
      ..close();

    final db = open()..createChat(info('a', 'Here'));
    db.writeFiles();
    File('${other.path}/chats/Chat/From the laptop.json').copySync(chatFile('From the laptop.json').path);
    db.scanFiles();
    expect({for (final c in db.chats()) c.id}, {'a', 'x'});
    expect(db.messages('x').single.text, 'giraffe crossing');
    expect(await found(db, 'giraffe'), ['x']);

    chatFile('Here.json').deleteSync();
    db.scanFiles();
    expect([for (final c in db.chats()) c.id], ['x']);
    // A file renamed by hand is still the same chat.
    chatFile('From the laptop.json').renameSync(chatFile('Renamed by hand.json').path);
    db.scanFiles();
    expect([for (final c in db.chats()) c.id], ['x']);
    expect(await found(db, 'giraffe'), ['x']);
    // A file edited outside the app wins over the index.
    final json = jsonDecode(chatFile('Renamed by hand.json').readAsStringSync()) as Map;
    (json['messages'] as List).first['text'] = 'zebra crossing';
    chatFile('Renamed by hand.json').writeAsStringSync(jsonEncode(json));
    db.scanFiles();
    expect(db.messages('x').single.text, 'zebra crossing');
    expect(await found(db, 'giraffe'), isEmpty);
    db.close();
  });

  test('the same chat in two files: both are kept, the copy as a chat of its own with new ids', () {
    var db = open();
    db
      ..createChat(info('a', 'Notes'))
      ..addMessage('a', 0, const ChatMessage(Role.user, 'one'))
      ..addMessage('a', 1, const ChatMessage(Role.assistant, 'two', conv: 'a-b5'), parent: 0)
      ..close();
    chatFile('Notes.json').copySync(chatFile('Notes copy.json').path);
    db = open();
    final ids = [for (final c in db.chats()) c.id];
    expect(ids, hasLength(2));
    expect(ids, contains('a'));
    final copy = ids.firstWhere((id) => id != 'a');
    expect(db.messages(copy).map((m) => m.text), ['one', 'two']);
    expect(db.branches()[copy], ['$copy-b5'], reason: 'its own conversations for the engine');
    expect(db.branches()['a'], ['a-b5']);
    db.close();
    // Written again with its new id, under its title's name like any chat.
    expect(names(), ['Notes (2).json', 'Notes.json']);
    expect(jsonDecode(chatFile('Notes (2).json').readAsStringSync())['id'], copy);
    db = open();
    expect(db.chats(), hasLength(2), reason: 'stable from then on');
    db.close();
  });

  test('chats.db of an older version is moved into files once and kept as a backup; a move cut off starts again', () async {
    // An older version's data folder: chats.db with chats, branches and benchmark runs (made with today's code, then
    // turned back into what that version left).
    var db = open();
    db
      ..createChat(info('a', 'Alpha'))
      ..addMessage('a', 0, const ChatMessage(Role.user, 'zebra'))
      ..addMessage('a', 1, const ChatMessage(Role.assistant, 'reply', stats: ReplyStats(wordsPerSecond: 9)))
      ..addMessage('a', 2, const ChatMessage(Role.assistant, 'reply again', conv: 'a-b1'), parent: 0)
      ..createChat(info('b', 'Bravo', kind: ChatKind.code))
      ..setPins(['b']);
    final before = {for (final id in ['a', 'b']) id: describe(db, id)};
    db.close();
    File('${dir.path}/chat-index.db').renameSync('${dir.path}/chats.db');
    File('${dir.path}/benchmarks.db').deleteSync();
    folder.deleteSync(recursive: true);
    final raw = sqlite3.open('${dir.path}/chats.db');
    raw.execute('DROP TABLE files');
    raw.execute('CREATE TABLE benchmarks (id INTEGER PRIMARY KEY AUTOINCREMENT, data TEXT NOT NULL)');
    raw.execute('''INSERT INTO benchmarks (data) VALUES ('{"run":1}')''');
    raw.close();
    final oldBytes = File('${dir.path}/chats.db').readAsBytesSync();

    // A move cut off: one chat's file written, an index left half made.
    final first = open();
    first.close();
    File('${dir.path}/chat-index.db').copySync('${dir.path}/stale.db');
    File('${dir.path}/${ChatDb.backupName}').renameSync('${dir.path}/chats.db');
    File('${dir.path}/stale.db').renameSync('${dir.path}/chat-index.db');
    chatFile('Bravo.json', kind: 'Code').deleteSync();

    db = open();
    expect(File('${dir.path}/chats.db').existsSync(), isFalse);
    expect(File('${dir.path}/${ChatDb.backupName}').readAsBytesSync(), oldBytes, reason: 'kept untouched');
    expect(names(), ['Alpha.json'], reason: 'no chat twice');
    expect(names('Code'), ['Bravo.json']);
    expect({for (final id in ['a', 'b']) id: describe(db, id)}, before);
    expect([for (final (_, d) in db.benchmarks()) d], ['{"run":1}'], reason: 'the runs once, in their own database');
    expect(await found(db, 'zebra'), ['a']);
    db.close();

    // The files alone hold it all.
    File('${dir.path}/chat-index.db').deleteSync();
    db = open();
    expect({for (final id in ['a', 'b']) id: describe(db, id)}, before);
    db.close();
  });

  test('safe writes: a change is written a moment later, a cut-off write leaves the chat whole, and a change not yet '
      'in its file is written at the next start', () {
    final db = open()
      ..createChat(info('a', 'Alpha'))
      ..addMessage('a', 0, const ChatMessage(Role.user, 'one'));
    expect(chatFile('Alpha.json').existsSync(), isFalse, reason: 'not on every change');
    db.writeFiles();
    final whole = chatFile('Alpha.json').readAsStringSync();
    expect(names(), ['Alpha.json'], reason: 'no temporary file left');

    // A crash in the middle of a write: the temporary file is cut off, the chat's file is as it was.
    chatFile('Alpha.json.tmp').writeAsStringSync(whole.substring(0, whole.length ~/ 2));
    // A change in the index that did not reach the file before the crash.
    db.addMessage('a', 1, const ChatMessage(Role.assistant, 'two'));
    final next = open(); // the next start (the first one never wrote)
    expect(names(), ['Alpha.json']);
    expect(next.messages('a').map((m) => m.text), ['one', 'two']);
    expect(chatFile('Alpha.json').readAsStringSync(), contains('"two"'));
    next.close();
    db.close();
  });

  test('a file that cannot be read, or that a newer version wrote, is left out and left alone', () {
    open().close();
    chatFile('broken.json').writeAsStringSync('{"format": 1, "id": "x", "title"');
    final newer = {'format': ChatDb.fileFormat + 1, 'id': 'y', 'title': 'Future', 'created': '2030-01-01T00:00:00.000Z',
        'updated': '2030-01-01T00:00:00.000Z', 'messages': []};
    chatFile('Future.json').writeAsStringSync(jsonEncode(newer));
    final db = open();
    expect(db.chats(), isEmpty);
    db
      ..createChat(info('z', 'Future'))
      ..close();
    expect(names(), ['Future (2).json', 'Future.json', 'broken.json']);
    expect(jsonDecode(chatFile('Future.json').readAsStringSync())['format'], ChatDb.fileFormat + 1);
  });
}
