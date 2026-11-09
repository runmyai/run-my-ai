import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../search/chat_search.dart';
import 'models.dart';

/// The chats, saved in one SQLite database (chats.db in the app's data folder), with a word index for search.
///
/// Tables:
///   chats          id, a number (num), title, created / updated (milliseconds), pin (place among the pinned, or null),
///                  kind (0 = the Chat section, 1 = Code), sort (its place among its day's chats after the user
///                  dragged it; null = by when it was last used)
///   messages       one row per message: who wrote it, the text, and whether it is a bookmark (1, or NULL). Its
///                  row number says where it is: the chat's
///                  number times 2^20 plus its place in the chat. So a chat's messages are one range of numbers,
///                  in order, and a number from the word index tells its chat and place with nothing looked up.
///   messages_fts   the word index: for each message, its words as the search splits them. It keeps no copy of
///                  the text (contentless) and only which messages hold which words (detail=none, the smallest
///                  kind): the search checks the order and closeness of the words itself. It also keeps every
///                  word's first 1 to 3 letters, for words still being typed.
///
/// Used from one background worker (lib/data/chat_store.dart); every call here runs on that worker.
class ChatDb {
  ChatDb._(this._db);

  final Database _db;

  /// Each chat's number, by chat id (loaded once, kept up to date here).
  late final Map<String, int> _num = {
    for (final r in _db.select('SELECT id, num FROM chats')) r['id'] as String: r['num'] as int,
  };

  /// A chat holds up to 2^20 (about a million) messages.
  static const _placeBits = 20;
  static const _placeMask = (1 << _placeBits) - 1;
  int _first(int num) => num << _placeBits;
  int _last(int num) => (num << _placeBits) | _placeMask;

  /// Opens (or creates) the database at [path]. Chats saved by older versions of the app (chats/ID.json and
  /// pins.json next to the database) are moved in, and their files deleted once they are in.
  static ChatDb open(String path) {
    final db = ChatDb._(sqlite3.open(path));
    db._setUp();
    try {
      db._moveInOldChats(File(path).parent);
    } catch (e) {
      // The old files stay where they are, and the next start tries again.
      stderr.writeln('Run My AI: could not move the saved chats into the database: $e');
    }
    return db;
  }

  /// A database that lives in memory only (tests).
  static ChatDb inMemory() => ChatDb._(sqlite3.openInMemory()).._setUp();

  void _setUp() {
    _db.execute('''
      -- 16 KiB pages: a long message fits in one page instead of spilling into half-empty ones (a new database
      -- only; it must come before anything is written).
      PRAGMA page_size = 16384;
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      -- At most 2 MB of the database kept in memory, and the write-ahead file cut back to 4 MB after each save.
      PRAGMA cache_size = -2000;
      PRAGMA journal_size_limit = 4194304;
      PRAGMA temp_store = MEMORY;
    ''');
    if (_db.userVersion < 1) {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS chats (
          id TEXT PRIMARY KEY,
          num INTEGER NOT NULL UNIQUE,
          title TEXT NOT NULL,
          created INTEGER NOT NULL,
          updated INTEGER NOT NULL,
          pin INTEGER
        );
        CREATE TABLE IF NOT EXISTS messages (
          id INTEGER PRIMARY KEY,
          role INTEGER NOT NULL,
          text TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
          words, content = '', contentless_delete = 1, detail = none,
          tokenize = 'unicode61 remove_diacritics 0'
        );
      ''');
      _db.userVersion = 1;
    }
    // Version 2: Chat and Code have their own chats; the chats saved before are all Chat's.
    if (_db.userVersion < 2) {
      _db.execute('ALTER TABLE chats ADD COLUMN kind INTEGER NOT NULL DEFAULT 0');
      _db.userVersion = 2;
    }
    // Version 3: chats can be dragged into another order within their day.
    if (_db.userVersion < 3) {
      _db.execute('ALTER TABLE chats ADD COLUMN sort REAL');
      _db.userVersion = 3;
    }
    // Version 4: the word index also keeps the first 1 to 3 letters of every word, so a word still being typed
    // ("p", "pro") is found about as fast as a whole word. Built again from the saved messages, one at a time.
    if (_db.userVersion < 4) {
      _inTransaction(() {
        _db.execute('''
          DROP TABLE IF EXISTS messages_fts;
          CREATE VIRTUAL TABLE messages_fts USING fts5(
            words, content = '', contentless_delete = 1, detail = none,
            tokenize = 'unicode61 remove_diacritics 0', prefix = '1 2 3'
          );
        ''');
        final insert = _db.prepare('INSERT INTO messages_fts (rowid, words) VALUES (?, ?)');
        final messages = _db.prepare('SELECT id, text FROM messages');
        try {
          final cursor = messages.selectCursor();
          while (cursor.moveNext()) {
            insert.execute([cursor.current['id'], searchWords(cursor.current['text'] as String)]);
          }
        } finally {
          insert.close();
          messages.close();
        }
        _db.userVersion = 4;
      });
      _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    }
    // Version 5: chats can be archived (when, in milliseconds; NULL = not archived).
    if (_db.userVersion < 5) {
      _db.execute('ALTER TABLE chats ADD COLUMN archived INTEGER');
      _db.userVersion = 5;
    }
    // Version 6: sent messages can be bookmarked (1; NULL = not one).
    if (_db.userVersion < 6) {
      _db.execute('ALTER TABLE messages ADD COLUMN bookmark INTEGER');
      _db.userVersion = 6;
    }
    // Version 7: (a test build named that column "chapter").
    if (_db.userVersion < 7) {
      if (_db.select("SELECT 1 FROM pragma_table_info('messages') WHERE name = 'chapter'").isNotEmpty) {
        _db.execute('ALTER TABLE messages RENAME COLUMN chapter TO bookmark');
      }
      _db.userVersion = 7;
    }
  }

  void close() {
    _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    _db.close();
  }

  // ---- The chat list -------------------------------------------------------------------------------------------

  /// All chats (of both sections), the most recently used first.
  List<ChatInfo> chats() => [
        for (final r in _db.select(
            'SELECT id, title, created, updated, kind, sort, archived FROM chats ORDER BY updated DESC, id DESC'))
          ChatInfo(
            id: r['id'] as String,
            title: r['title'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(r['created'] as int),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated'] as int),
            kind: ChatKind.values[r['kind'] as int],
            sort: (r['sort'] as num?)?.toDouble(),
            archivedAt: r['archived'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['archived'] as int),
          ),
      ];

  /// The pinned chats' ids (of both sections), in the user's order.
  List<String> pins() => [for (final r in _db.select('SELECT id FROM chats WHERE pin IS NOT NULL ORDER BY pin')) r['id'] as String];

  List<ChatMessage> messages(String chatId) {
    final num = _num[chatId];
    if (num == null) return const [];
    return [
      for (final r in _db.select(
          'SELECT role, text, bookmark FROM messages WHERE id BETWEEN ? AND ? ORDER BY id', [_first(num), _last(num)]))
        ChatMessage(Role.values[r['role'] as int], r['text'] as String, bookmark: r['bookmark'] != null),
    ];
  }

  // ---- Changes ---------------------------------------------------------------------------------------------------

  void createChat(ChatInfo chat) {
    if (_num.containsKey(chat.id)) return;
    final num = (_db.select('SELECT COALESCE(MAX(num), 0) + 1 AS n FROM chats').first['n'] as int);
    _db.execute(
      'INSERT INTO chats (id, num, title, created, updated, kind) VALUES (?, ?, ?, ?, ?, ?)',
      [chat.id, num, chat.title, chat.createdAt.millisecondsSinceEpoch, chat.updatedAt.millisecondsSinceEpoch, chat.kind.index],
    );
    _num[chat.id] = num;
  }

  /// Adds a message at place [pos] of the chat, and its words to the index.
  void addMessage(String chatId, int pos, ChatMessage message) => _inTransaction(() => _addMessage(chatId, pos, message));

  void _addMessage(String chatId, int pos, ChatMessage message) {
    final num = _num[chatId];
    if (num == null || pos > _placeMask) return;
    final id = _first(num) | pos;
    _db.execute('INSERT INTO messages (id, role, text) VALUES (?, ?, ?)', [id, message.role.index, message.text]);
    _db.execute('INSERT INTO messages_fts (rowid, words) VALUES (?, ?)', [id, searchWords(message.text)]);
  }

  /// A new message: the chat's time changes and it leaves any place it was dragged to (the top of Today).
  void setUpdated(String chatId, DateTime updatedAt) =>
      _db.execute('UPDATE chats SET updated = ?, sort = NULL WHERE id = ?', [updatedAt.millisecondsSinceEpoch, chatId]);

  /// The chats' places within their day, after the user dragged one.
  void setSorts(Map<String, double> sorts) => _inTransaction(() {
        for (final MapEntry(key: id, value: sort) in sorts.entries) {
          _db.execute('UPDATE chats SET sort = ? WHERE id = ?', [sort, id]);
        }
      });

  /// Archives the chat at [at] (it is unpinned too), or (null) unarchives it, as last used at [now].
  void setArchived(String chatId, DateTime? at, DateTime now) => at != null
      ? _db.execute('UPDATE chats SET archived = ?, pin = NULL WHERE id = ?', [at.millisecondsSinceEpoch, chatId])
      : _db.execute('UPDATE chats SET archived = NULL, updated = ?, sort = NULL WHERE id = ?',
          [now.millisecondsSinceEpoch, chatId]);

  /// Marks the message at place [pos] of the chat as a bookmark, or not.
  void setBookmark(String chatId, int pos, bool bookmark) {
    final num = _num[chatId];
    if (num == null || pos > _placeMask) return;
    _db.execute('UPDATE messages SET bookmark = ? WHERE id = ?', [bookmark ? 1 : null, _first(num) | pos]);
  }

  void rename(String chatId, String title) => _db.execute('UPDATE chats SET title = ? WHERE id = ?', [title, chatId]);

  /// Deletes the chat, its messages and their words in the index.
  void delete(String chatId) {
    final num = _num.remove(chatId);
    _inTransaction(() {
      if (num != null) {
        _db.execute('DELETE FROM messages_fts WHERE rowid IN (SELECT id FROM messages WHERE id BETWEEN ? AND ?)',
            [_first(num), _last(num)]);
        _db.execute('DELETE FROM messages WHERE id BETWEEN ? AND ?', [_first(num), _last(num)]);
      }
      _db.execute('DELETE FROM chats WHERE id = ?', [chatId]);
    });
  }

  /// Sets which chats are pinned, in this order.
  void setPins(List<String> ids) => _inTransaction(() {
        _db.execute('UPDATE chats SET pin = NULL WHERE pin IS NOT NULL');
        for (var i = 0; i < ids.length; i++) {
          _db.execute('UPDATE chats SET pin = ? WHERE id = ?', [i, ids[i]]);
        }
      });

  void _inTransaction(void Function() body) {
    _db.execute('BEGIN');
    try {
      body();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ---- Search ----------------------------------------------------------------------------------------------------

  /// The chats of section [kind] that match [query], best first; the same results as [searchChats] over those chats
  /// in memory.
  ///
  /// The word index says which messages hold the typed words (as message numbers, which also give each one's chat
  /// and place). Texts are read only where the order and closeness of several words decides a chat's place, and
  /// for the lines under the first [linesAtOnce] titles; the rest of the lines are read when the list reaches
  /// them ([fillLines]). Every few milliseconds the search lets the worker take other requests, and gives up
  /// (returns null) when [cancelled] says a newer search has started.
  Future<List<ChatHit>?> search(SearchQuery query, {ChatKind kind = ChatKind.chat, bool Function()? cancelled}) async {
    if (query.isEmpty) return const [];
    final clock = Stopwatch()..start();
    Future<bool> pause() async {
      if (clock.elapsedMilliseconds < 8) return false;
      await Future<void>.delayed(Duration.zero);
      clock.reset();
      return cancelled?.call() ?? false;
    }

    final matcher = ChatMatcher(query);
    final chatOf = <int, String>{};
    // Only this section's chats; messages of the other section's chats are skipped below (no chat to add them to).
    for (final r in _db.select('SELECT id, num, title, updated FROM chats WHERE kind = ?', [kind.index])) {
      final id = r['id'] as String;
      chatOf[r['num'] as int] = id;
      matcher.addChat(id, r['title'] as String, DateTime.fromMillisecondsSinceEpoch(r['updated'] as int));
    }
    if (await pause()) return null;

    // A term ending in "*" asks the index for every word starting with it.
    String quoted(String term) => term.endsWith('*') ? '"${term.substring(0, term.length - 1)}"*' : '"$term"';
    // The index is asked for counts and firsts per chat, never for every matching message: a short beginning like
    // "p" is in most messages, and only one row per chat comes back.
    const fts = 'SELECT rowid AS id FROM messages_fts WHERE messages_fts MATCH ?';
    final keyWords = query.keyWords.toList();

    // Each key word: the chats whose messages hold it, and the first such message in each. (One typed word: that
    // message is an exact match, and nothing is read.)
    final firsts = <String, Map<int, int>>{};
    for (final word in keyWords) {
      final first = firsts[word] = {};
      for (final r in _db.select('SELECT id >> $_placeBits AS num, MIN(id) AS first FROM ($fts) GROUP BY num', [quoted(word)])) {
        final chatId = chatOf[r['num'] as int];
        if (chatId == null) continue;
        first[r['num'] as int] = r['first'] as int;
        matcher.addFound(chatId, word);
        if (query.words.length == 1) matcher.addMessageFromIndex(chatId, (r['first'] as int) & _placeMask, 1, 0);
      }
      if (await pause()) return null;
    }

    final read = _db.prepare('SELECT role, text FROM messages WHERE id = ?');
    final has = _db.prepare('SELECT 1 FROM messages_fts WHERE messages_fts MATCH ? AND rowid BETWEEN ? AND ? LIMIT 1');
    try {
      if (query.words.length > 1) {
        // The messages with every typed word, in each chat's order: read them, and stop in a chat at the first with
        // the words exactly as typed.
        final allWords = _db.select('$fts ORDER BY id', [query.distinct.map(quoted).join(' AND ')]);
        for (final r in allWords) {
          final id = r['id'] as int;
          final chatId = chatOf[id >> _placeBits];
          if (chatId == null || matcher.hasExactMessage(chatId)) continue;
          final m = read.select([id]).first;
          matcher.addMessage(chatId, id & _placeMask, Role.values[m['role'] as int], m['text'] as String);
          if (await pause()) return null;
        }
        // A chat with no message holding every word: its best is the first message with the most key words,
        // counted by the index (nothing read). With one or two key words that comes from the firsts above (and,
        // for two, the first message holding both); with more, the index counts each message's key words.
        if (query.nonFiller.isNotEmpty) {
          final best = <int, (int, int)>{}; // chat number -> (message number, key words in it)
          if (keyWords.length <= 2) {
            for (final first in firsts.values) {
              for (final MapEntry(key: num, value: id) in first.entries) {
                if (best[num] case (final had, _) when had < id) continue;
                best[num] = (id, 1);
              }
            }
            if (keyWords.length == 2) {
              final both = _db.select('SELECT id >> $_placeBits AS num, MIN(id) AS first FROM ($fts) GROUP BY num',
                  [keyWords.map(quoted).join(' AND ')]);
              for (final r in both) {
                best[r['num'] as int] = (r['first'] as int, 2);
              }
            }
          } else {
            final each = List.filled(keyWords.length, fts).join(' UNION ALL ');
            final rows = _db.select(
              'SELECT id, c FROM ('
              '  SELECT id, c, ROW_NUMBER() OVER (PARTITION BY id >> $_placeBits ORDER BY c DESC, id) AS place'
              '  FROM (SELECT id, COUNT(*) AS c FROM ($each) GROUP BY id))'
              ' WHERE place = 1',
              [for (final w in keyWords) quoted(w)],
            );
            for (final r in rows) {
              best[(r['id'] as int) >> _placeBits] = (r['id'] as int, r['c'] as int);
            }
          }
          for (final MapEntry(key: num, value: (id, count)) in best.entries) {
            final chatId = chatOf[num];
            if (chatId == null || matcher.hasStrongMessage(chatId)) continue;
            matcher.addMessageFromIndex(chatId, id & _placeMask, 4, -count);
          }
          if (await pause()) return null;
        }
      }

      // Filler words not seen yet may still be in the chat: ask the index, within the chat's range of message
      // numbers. (Every key word was already counted from the index above.)
      for (final chatId in matcher.chatsToCheck()) {
        final num = _num[chatId]!;
        for (final word in matcher.missingWords(chatId).where((w) => !query.keyWords.contains(w)).toList()) {
          if (has.select([quoted(word), _first(num), _last(num)]).isNotEmpty) matcher.addFound(chatId, word);
        }
        if (await pause()) return null;
      }
    } finally {
      read.close();
      has.close();
    }
    // The lines under the first titles are read now; the rest when the list is scrolled to them.
    final hits = matcher.results();
    return [...fillLines(query, hits.take(linesAtOnce).toList()), ...hits.skip(linesAtOnce)];
  }

  /// How many results get their line under the title straight away.
  static const linesAtOnce = 50;

  /// [hits] with the lines under their titles read from their best messages.
  List<ChatHit> fillLines(SearchQuery query, List<ChatHit> hits) {
    final read = _db.prepare('SELECT role, text FROM messages WHERE id = ?');
    try {
      return [
        for (final h in hits)
          if (h.snippetPending && _num[h.chatId] != null)
            if (read.select([_first(_num[h.chatId]!) | h.messageIndex!]).firstOrNull case final r?)
              h.withLineFrom(r['text'] as String, Role.values[r['role'] as int], query)
            else
              h
          else
            h,
      ];
    } finally {
      read.close();
    }
  }

  // ---- Chats saved by older versions -----------------------------------------------------------------------------

  void _moveInOldChats(Directory dir) {
    final folder = Directory('${dir.path}${Platform.pathSeparator}chats');
    final pinsFile = File('${dir.path}${Platform.pathSeparator}pins.json');
    if (!folder.existsSync()) return;
    final files = folder.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
    final chats = [for (final f in files) ?_readOldChat(f)];
    List<String> pins = const [];
    try {
      if (pinsFile.existsSync()) {
        pins = [for (final id in (jsonDecode(pinsFile.readAsStringSync()) as Map)['pinned'] as List? ?? const []) id as String];
      }
    } on FormatException {
      // An unreadable pins file only loses the pins.
    }
    _inTransaction(() {
      for (final chat in chats) {
        createChat(chat.info);
        for (var i = 0; i < chat.messages.length; i++) {
          _addMessage(chat.id, i, chat.messages[i]);
        }
      }
      final known = chats.map((c) => c.id).toSet();
      final kept = pins.where(known.contains).toList();
      for (var i = 0; i < kept.length; i++) {
        _db.execute('UPDATE chats SET pin = ? WHERE id = ?', [i, kept[i]]);
      }
    });
    // In the database now: the old files go, so nothing is kept twice. A file that could not be read stays.
    for (final f in files) {
      if (chats.any((c) => f.path.endsWith('${Platform.pathSeparator}${c.id}.json'))) f.deleteSync();
    }
    for (final f in folder.listSync().whereType<File>().where((f) => f.path.endsWith('.tmp'))) {
      f.deleteSync();
    }
    if (folder.listSync().isEmpty) folder.deleteSync();
    if (pinsFile.existsSync()) pinsFile.deleteSync();
    // One big save: give its write-ahead file back to the disk now.
    _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  }

  Chat? _readOldChat(File f) {
    try {
      return Chat.fromJson((jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }
}
