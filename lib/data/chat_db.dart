import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import '../search/chat_search.dart';
import 'models.dart';
import 'reply_stats.dart';

/// The chats: one file per chat in the chats folder (the real store, see "The chat files" below), and an index of
/// them in one SQLite database (chat-index.db in the app's data folder) for the chat list and the search. The index
/// is made from the files: at start the folder is scanned and files that are new, changed or gone (copied in from
/// another computer, deleted by hand) are brought into it, so a lost index is made again from the files. A change
/// goes into the index at once and into the chat's file a moment later (a reply that grows is written as one file
/// every [writeDelay], not on every word); a change not yet in its file is marked in the index, and the next start
/// writes it.
///
/// Tables of the index:
///   chats          id, a number (num), title, created / updated (milliseconds), pin (place among the pinned, or null),
///                  kind (0 = the Chat section, 1 = Code), sort (its place among its day's chats after the user
///                  dragged it; null = by when it was last used)
///   messages       one row per message, of every version: who wrote it, the text, whether it is a bookmark (1, or
///                  NULL) and whether the reply did not get to its end (stopped: 1, or NULL). Its row number says
///                  which chat and which message it is: the chat's number times 2^20 plus the message's own number
///                  (the order the messages were made in, the versions of a message included). So a chat's messages
///                  are one range of numbers, and a number from the word index tells its chat and message with
///                  nothing looked up.
///                  The messages of a chat form a tree: parent is the message it follows (NULL: it starts the chat),
///                  sel the follower shown (NULL: the newest; chats.sel does the same for the first messages) and
///                  conv the conversation id the engine keeps its saved state under (NULL: the chat's own id). A
///                  message with several followers (an edited message, a reply written again) has versions; the
///                  version shown at each place makes the path the chat opens on. A reply also has stats: how it
///                  went (speed, tokens, time ...) as one JSON text, shown on the card under it.
///   files          each chat's file: its path in the chats folder ("Chat/Title.json"), its time and size when it was
///                  last read or written (a file that differs was changed outside the app), and dirty (1: the chat
///                  has changes its file does not have yet).
///   messages_fts   the word index: for each message, its words as the search splits them. It keeps no copy of
///                  the text (contentless) and only which messages hold which words (detail=none, the smallest
///                  kind): the search checks the order and closeness of the words itself. It also keeps every
///                  word's first 1 to 3 letters, for words still being typed.
///
/// The benchmark runs are in a database of their own (benchmarks.db next to the index, attached as "bench"): one row
/// per run, newest last, the run's details and its shrunk graphs as one JSON text. Only the newest
/// ChatDb.maxBenchmarks runs are kept.
///
/// Used from one background worker (lib/data/chat_store.dart); every call here runs on that worker.
class ChatDb {
  ChatDb._(this._db, this._folder);

  final Database _db;

  /// The chats folder; null: the chats are kept in the index only (tests).
  final Directory? _folder;

  /// Each chat's number, by chat id (loaded once, kept up to date here).
  late final Map<String, int> _num = {
    for (final r in _db.select('SELECT id, num FROM chats')) r['id'] as String: r['num'] as int,
  };

  /// A chat holds up to 2^20 (about a million) messages.
  static const _placeBits = 20;
  static const _placeMask = (1 << _placeBits) - 1;
  int _first(int num) => num << _placeBits;
  int _last(int num) => (num << _placeBits) | _placeMask;

  /// Opens the chats saved in [folder], with their index and the benchmark runs in [data]. The chats of a version
  /// that kept them in data/chats.db are moved into files once, and chats.db is kept, renamed to [backupName]. Chats
  /// saved by still older versions (data/chats/ID.json and data/pins.json) are moved in, and their files deleted once
  /// they are in.
  static ChatDb open(Directory data, Directory folder) {
    String at(String name) => '${data.path}${Platform.pathSeparator}$name';
    final old = at('chats.db');
    final index = at('chat-index.db');
    final moving = File(old).existsSync();
    if (moving) {
      // The old database becomes the index (an index left by a move that did not finish is made again from it).
      _deleteDatabase(index);
      File(old).copySync(index);
      if (File('$old-wal').existsSync()) File('$old-wal').copySync('$index-wal');
    }
    final db = ChatDb._(sqlite3.open(index), folder);
    db._setUp(at('benchmarks.db'));
    if (moving) db._db.execute('DELETE FROM files');
    try {
      db._moveInOldChats(data);
    } catch (e) {
      // The old files stay where they are, and the next start tries again.
      stderr.writeln('Run My AI: could not move the saved chats into the database: $e');
    }
    db.scanFiles();
    if (moving) {
      // Every chat is in its file now (one that could not be written stays marked in the index for the next start).
      for (final end in ['', '-wal', '-shm']) {
        if (File('$old$end').existsSync()) File('$old$end').renameSync('${at(backupName)}$end');
      }
    }
    return db;
  }

  /// What chats.db of an older version is renamed to once its chats are in files.
  static const backupName = 'chats.db.backup';

  static void _deleteDatabase(String path) {
    for (final end in ['', '-wal', '-shm']) {
      if (File('$path$end').existsSync()) File('$path$end').deleteSync();
    }
  }

  /// A database that lives in memory only, with no files (tests).
  static ChatDb inMemory() => ChatDb._(sqlite3.openInMemory(), null).._setUp(':memory:');

  void _setUp(String benchmarks) {
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
    // Version 8: a reply can hold what the model thought before it, and for how long.
    if (_db.userVersion < 8) {
      _db.execute('ALTER TABLE messages ADD COLUMN thinking TEXT');
      _db.execute('ALTER TABLE messages ADD COLUMN thinking_ms INTEGER');
      _db.userVersion = 8;
    }
    // Version 9: each chat remembers its model and context length.
    if (_db.userVersion < 9) {
      _db.execute('ALTER TABLE chats ADD COLUMN model TEXT');
      _db.execute('ALTER TABLE chats ADD COLUMN context INTEGER');
      _db.userVersion = 9;
    }
    // Version 10: the history of benchmark runs (in a database of its own now, below).
    if (_db.userVersion < 10) _db.userVersion = 10;
    // Version 11: a reply that did not get to its end is marked (1; NULL = not one).
    if (_db.userVersion < 11) {
      _db.execute('ALTER TABLE messages ADD COLUMN stopped INTEGER');
      _db.userVersion = 11;
    }
    // Version 12: a message can have several versions, each with its own later messages (see the tables above). A
    // chat saved before is one path: each message follows the one before it, so what it shows does not change.
    if (_db.userVersion < 12) {
      _inTransaction(() {
        _db.execute('''
          ALTER TABLE messages ADD COLUMN parent INTEGER;
          ALTER TABLE messages ADD COLUMN sel INTEGER;
          ALTER TABLE messages ADD COLUMN conv TEXT;
          ALTER TABLE chats ADD COLUMN sel INTEGER;
          -- Lists the branches (every conversation id) without reading the messages' texts.
          CREATE INDEX messages_conv ON messages (conv) WHERE conv IS NOT NULL;
          CREATE TEMP TABLE before (id INTEGER PRIMARY KEY, prev INTEGER);
          INSERT INTO before SELECT id, LAG(id) OVER (PARTITION BY id >> $_placeBits ORDER BY id) FROM messages;
          UPDATE messages SET parent = (SELECT prev FROM before WHERE before.id = messages.id);
          DROP TABLE before;
        ''');
        _db.userVersion = 12;
      });
    }
    // Version 13: how a reply went (its stats as one JSON text, what the card under the reply shows).
    if (_db.userVersion < 13) {
      _db.execute('ALTER TABLE messages ADD COLUMN stats TEXT');
      _db.userVersion = 13;
    }
    _db.execute(
        'CREATE TABLE IF NOT EXISTS files (chat TEXT PRIMARY KEY, path TEXT, mtime INTEGER, size INTEGER, dirty INTEGER)');
    // The benchmark runs are kept apart from the index, which can be made again from the chat files while they
    // cannot. The runs an older version kept in chats.db move there.
    _db.execute('ATTACH DATABASE ? AS bench', [benchmarks]);
    _db.execute('CREATE TABLE IF NOT EXISTS bench.benchmarks (id INTEGER PRIMARY KEY AUTOINCREMENT, data TEXT NOT NULL)');
    if (_db.select("SELECT 1 FROM main.sqlite_master WHERE name = 'benchmarks'").isNotEmpty) {
      _inTransaction(() {
        _db.execute('INSERT OR IGNORE INTO bench.benchmarks (id, data) SELECT id, data FROM main.benchmarks');
        _db.execute('DROP TABLE main.benchmarks');
      });
    }
  }

  void close() {
    writeFiles();
    _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    _db.close();
  }

  // ---- The chat list -------------------------------------------------------------------------------------------

  /// All chats (of both sections), the most recently used first.
  List<ChatInfo> chats() => [
        for (final r in _db.select(
            'SELECT id, title, created, updated, kind, sort, archived, model, context FROM chats ORDER BY updated DESC, id DESC'))
          ChatInfo(
            id: r['id'] as String,
            title: r['title'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(r['created'] as int),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated'] as int),
            kind: ChatKind.values[r['kind'] as int],
            sort: (r['sort'] as num?)?.toDouble(),
            archivedAt: r['archived'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['archived'] as int),
            modelId: r['model'] as String?,
            contextLength: r['context'] as int?,
          ),
      ];

  /// The pinned chats' ids (of both sections), in the user's order.
  List<String> pins() =>
      [for (final r in _db.select('SELECT id FROM chats WHERE pin IS NOT NULL ORDER BY pin, id')) r['id'] as String];

  /// The messages shown: the path through the chat's versions (see [path]).
  List<ChatMessage> messages(String chatId) => path(chatId).messages;

  /// The key of "before the first message" among the messages' followers.
  static const _start = -1;

  /// The parent to give [addMessage] for a message that starts the chat.
  static const noParent = -1;

  /// The messages of the chat as shown, and the number its next message gets. At each place the version shown is
  /// the one last chosen there (by the user, or by a message made there: see [select]); a place never chosen shows
  /// its newest version. Each message says which version it is and how many there are.
  ChatPath path(String chatId) {
    final num = _num[chatId];
    if (num == null) return const ChatPath([], 0);
    // The shape of the tree first, without any text: each message's versions of the next one (oldest first), and
    // which of them was chosen.
    final followers = <int, List<int>>{};
    final chosen = <int, int>{};
    var next = 0;
    for (final r in _db.select(
        'SELECT id, parent, sel FROM messages WHERE id BETWEEN ? AND ? ORDER BY id', [_first(num), _last(num)])) {
      final id = r['id'] as int;
      (followers[r['parent'] as int? ?? _start] ??= []).add(id);
      if (r['sel'] case final int sel) chosen[id] = sel;
      next = max(next, (id & _placeMask) + 1);
    }
    if (_db.select('SELECT sel FROM chats WHERE id = ?', [chatId]).firstOrNull?['sel'] case final int sel) {
      chosen[_start] = sel;
    }
    final shown = <(int, int, int)>[]; // id, version, versions
    var at = _start;
    for (var versions = followers[at]; versions != null && shown.length <= _placeMask; versions = followers[at]) {
      final pick = versions.contains(chosen[at]) ? chosen[at]! : versions.last;
      shown.add((pick, versions.indexOf(pick), versions.length));
      at = pick;
    }
    final read = _db.prepare(
        'SELECT role, text, bookmark, thinking, thinking_ms, stopped, conv, stats FROM messages WHERE id = ?');
    try {
      return ChatPath([
        for (final (id, version, versions) in shown)
          if (read.select([id]).firstOrNull case final r?)
            ChatMessage(
              Role.values[r['role'] as int],
              r['text'] as String,
              bookmark: r['bookmark'] != null,
              thinking: r['thinking'] as String? ?? '',
              thinkingMillis: r['thinking_ms'] as int?,
              stopped: r['stopped'] != null,
              node: id & _placeMask,
              version: version,
              versions: versions,
              conv: r['conv'] as String?,
              stats: _readStats(r['stats'] as String?),
            ),
      ], next);
    } finally {
      read.close();
    }
  }

  /// Makes message [node] the version shown at its place, and every message it follows the version shown at theirs,
  /// so the chat opens on the path that holds it.
  void select(String chatId, int node) => _inTransaction(() {
        final num = _num[chatId];
        if (num == null) return;
        _changed(chatId);
        final parentOf = _db.prepare('SELECT parent FROM messages WHERE id = ?');
        try {
          var id = _first(num) | node;
          for (var steps = 0; steps <= _placeMask; steps++) {
            final row = parentOf.select([id]).firstOrNull;
            if (row == null) return;
            final parent = row['parent'] as int?;
            if (parent == null) {
              _db.execute('UPDATE chats SET sel = ? WHERE id = ?', [id, chatId]);
              return;
            }
            _db.execute('UPDATE messages SET sel = ? WHERE id = ?', [id, parent]);
            id = parent;
          }
        } finally {
          parentOf.close();
        }
      });

  /// Shows the version of message [node] that is [step] places after it (before it, for a negative step), as far as
  /// there is one, and returns the chat's path then.
  ChatPath flip(String chatId, int node, int step) {
    final num = _num[chatId];
    if (num != null) {
      final id = _first(num) | node;
      final parent = _db.select('SELECT parent FROM messages WHERE id = ?', [id]).firstOrNull?['parent'] as int?;
      final versions = [
        for (final r in parent == null
            ? _db.select('SELECT id FROM messages WHERE parent IS NULL AND id BETWEEN ? AND ? ORDER BY id',
                [_first(num), _last(num)])
            : _db.select('SELECT id FROM messages WHERE parent = ? ORDER BY id', [parent]))
          r['id'] as int,
      ];
      final at = versions.indexOf(id);
      if (at >= 0) select(chatId, versions[(at + step).clamp(0, versions.length - 1)] & _placeMask);
    }
    return path(chatId);
  }

  /// The chat's path with message [node] on it (see [select]).
  ChatPath pathTo(String chatId, int node) {
    select(chatId, node);
    return path(chatId);
  }

  /// The conversation ids of the chats' branches (every id but a chat's own that its messages are saved under), by
  /// chat id.
  Map<String, List<String>> branches() {
    final chatOf = {for (final e in _num.entries) e.value: e.key};
    final found = <String, List<String>>{};
    for (final r in _db.select('SELECT DISTINCT id >> $_placeBits AS num, conv FROM messages WHERE conv IS NOT NULL')) {
      if (chatOf[r['num'] as int] case final chat?) (found[chat] ??= []).add(r['conv'] as String);
    }
    return found;
  }

  // ---- Changes ---------------------------------------------------------------------------------------------------

  void createChat(ChatInfo chat) {
    if (_num.containsKey(chat.id)) return;
    _insertChat(
        chat.id, chat.title, chat.createdAt.millisecondsSinceEpoch, chat.updatedAt.millisecondsSinceEpoch, chat.kind);
    _changed(chat.id);
  }

  int _insertChat(String id, String title, int created, int updated, ChatKind kind) {
    final num = (_db.select('SELECT COALESCE(MAX(num), 0) + 1 AS n FROM chats').first['n'] as int);
    _db.execute('INSERT INTO chats (id, num, title, created, updated, kind) VALUES (?, ?, ?, ?, ?, ?)',
        [id, num, title, created, updated, kind.index]);
    return _num[id] = num;
  }

  /// Saves message number [pos] of the chat, and its words in the index. A new message follows message [parent]
  /// ([noParent]: it starts the chat) and becomes the version shown there; left out, it follows the one before it in
  /// number, the way a chat that is one line of messages is saved. A number that already holds a message (a reply
  /// saved again as it grows) gets the new text, with the old one's words gone from the index.
  void addMessage(String chatId, int pos, ChatMessage message, {int? parent}) =>
      _inTransaction(() => _addMessage(chatId, pos, message, parent: parent));

  void _addMessage(String chatId, int pos, ChatMessage message, {int? parent}) {
    final num = _num[chatId];
    if (num == null || pos > _placeMask) return;
    _changed(chatId);
    final id = _first(num) | pos;
    final thinking = message.thinking.isEmpty ? null : message.thinking;
    final stopped = message.stopped ? 1 : null;
    final stats = message.stats == null || message.stats!.isEmpty ? null : jsonEncode(message.stats!.toJson());
    _db.execute('DELETE FROM messages_fts WHERE rowid = ?', [id]);
    if (_db.select('SELECT 1 FROM messages WHERE id = ?', [id]).isNotEmpty) {
      // (The stats stay as they are when the message comes without them: a reply is saved again as it grows.)
      _db.execute(
          'UPDATE messages SET role = ?, text = ?, thinking = ?, thinking_ms = ?, stopped = ?, stats = COALESCE(?, stats) WHERE id = ?',
          [message.role.index, message.text, thinking, message.thinkingMillis, stopped, stats, id]);
    } else {
      final after = parent == noParent || (parent == null && pos == 0) ? null : _first(num) | (parent ?? pos - 1);
      _db.execute(
          'INSERT INTO messages (id, role, text, thinking, thinking_ms, stopped, parent, conv, stats) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [id, message.role.index, message.text, thinking, message.thinkingMillis, stopped, after, message.conv, stats]);
      // The new message is the version shown at its place.
      if (after == null) {
        _db.execute('UPDATE chats SET sel = ? WHERE id = ?', [id, chatId]);
      } else {
        _db.execute('UPDATE messages SET sel = ? WHERE id = ?', [id, after]);
      }
    }
    _db.execute('INSERT INTO messages_fts (rowid, words) VALUES (?, ?)', [id, searchWords(message.text)]);
  }

  /// Saves a benchmark run's details, keeping only the newest [keep] runs; returns the new run's id.
  int addBenchmark(String data, {int keep = maxBenchmarks}) {
    _db.execute('INSERT INTO bench.benchmarks (data) VALUES (?)', [data]);
    final id = _db.lastInsertRowId;
    _db.execute(
        'DELETE FROM bench.benchmarks WHERE id NOT IN (SELECT id FROM bench.benchmarks ORDER BY id DESC LIMIT ?)', [keep]);
    return id;
  }

  void deleteBenchmark(int id) => _db.execute('DELETE FROM bench.benchmarks WHERE id = ?', [id]);

  /// Every benchmark run's id and details, the newest first.
  List<(int, String)> benchmarks() => [
    for (final r in _db.select('SELECT id, data FROM bench.benchmarks ORDER BY id DESC')) (r['id'] as int, r['data'] as String),
  ];

  /// How many benchmark runs are kept (each with its graphs).
  static const maxBenchmarks = 60;

  static ReplyStats? _readStats(String? json) {
    if (json == null) return null;
    try {
      return ReplyStats.fromJson((jsonDecode(json) as Map).cast<String, Object?>());
    } on FormatException {
      return null;
    }
  }

  /// The model file and context length the chat uses.
  void setChoices(String chatId, String? modelId, int? contextLength) {
    _db.execute('UPDATE chats SET model = ?, context = ? WHERE id = ?', [modelId, contextLength, chatId]);
    _changed(chatId);
  }

  /// Removes message [node] of the chat and any message after it, with their words in the index.
  void removeMessage(String chatId, int node) => _inTransaction(() {
        final num = _num[chatId];
        if (num == null) return;
        _changed(chatId);
        final followers = <int, List<int>>{};
        for (final r in _db.select(
            'SELECT id, parent FROM messages WHERE id BETWEEN ? AND ? AND parent IS NOT NULL', [_first(num), _last(num)])) {
          (followers[r['parent'] as int] ??= []).add(r['id'] as int);
        }
        final gone = [_first(num) | node];
        for (var i = 0; i < gone.length; i++) {
          gone.addAll(followers[gone[i]] ?? const []);
        }
        for (final id in gone) {
          _db.execute('DELETE FROM messages_fts WHERE rowid = ?', [id]);
          _db.execute('DELETE FROM messages WHERE id = ?', [id]);
        }
      });

  /// A new message: the chat's time changes and it leaves any place it was dragged to (the top of Today).
  void setUpdated(String chatId, DateTime updatedAt) {
    _db.execute('UPDATE chats SET updated = ?, sort = NULL WHERE id = ?', [updatedAt.millisecondsSinceEpoch, chatId]);
    _changed(chatId);
  }

  /// The chats' places within their day, after the user dragged one.
  void setSorts(Map<String, double> sorts) => _inTransaction(() {
        for (final MapEntry(key: id, value: sort) in sorts.entries) {
          _db.execute('UPDATE chats SET sort = ? WHERE id = ?', [sort, id]);
          _changed(id);
        }
      });

  /// Archives the chat at [at] (it is unpinned too), or (null) unarchives it, as last used at [now].
  void setArchived(String chatId, DateTime? at, DateTime now) {
    at != null
        ? _db.execute('UPDATE chats SET archived = ?, pin = NULL WHERE id = ?', [at.millisecondsSinceEpoch, chatId])
        : _db.execute('UPDATE chats SET archived = NULL, updated = ?, sort = NULL WHERE id = ?',
            [now.millisecondsSinceEpoch, chatId]);
    _changed(chatId);
  }

  /// Marks the message at place [pos] of the chat as a bookmark, or not.
  void setBookmark(String chatId, int pos, bool bookmark) {
    final num = _num[chatId];
    if (num == null || pos > _placeMask) return;
    _db.execute('UPDATE messages SET bookmark = ? WHERE id = ?', [bookmark ? 1 : null, _first(num) | pos]);
    _changed(chatId);
  }

  /// A new title; the chat's file is renamed with it.
  void rename(String chatId, String title) {
    _db.execute('UPDATE chats SET title = ? WHERE id = ?', [title, chatId]);
    _changed(chatId);
  }

  /// Deletes the chat: its file, its messages and their words in the index.
  void delete(String chatId) {
    final path = _db.select('SELECT path FROM files WHERE chat = ?', [chatId]).firstOrNull?['path'] as String?;
    _forget(chatId);
    if (path != null && File(_onDisk(path)).existsSync()) File(_onDisk(path)).deleteSync();
  }

  /// Takes the chat out of the index (its file is left as it is).
  void _forget(String chatId) {
    _dirty.remove(chatId);
    final num = _num.remove(chatId);
    _inTransaction(() {
      if (num != null) {
        _db.execute('DELETE FROM messages_fts WHERE rowid IN (SELECT id FROM messages WHERE id BETWEEN ? AND ?)',
            [_first(num), _last(num)]);
        _db.execute('DELETE FROM messages WHERE id BETWEEN ? AND ?', [_first(num), _last(num)]);
      }
      _db.execute('DELETE FROM chats WHERE id = ?', [chatId]);
      _db.execute('DELETE FROM files WHERE chat = ?', [chatId]);
    });
  }

  /// Sets which chats are pinned, in this order.
  void setPins(List<String> ids) => _inTransaction(() {
        for (final id in {...pins(), ...ids}) {
          if (_num.containsKey(id)) _changed(id);
        }
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

  // ---- The chat files --------------------------------------------------------------------------------------------
  //
  // Each chat is one JSON file in the chats folder: Chat/<title>.json or Code/<title>.json by its section (the folder
  // decides the section), named by its title (see chatFileName; a second chat of the same name gets " (2)", and so
  // on) and renamed with it. It holds everything the index holds for the chat:
  //   format     the version of this layout (fileFormat); a file of a newer layout is left alone
  //   id, title, kind ("chat" / "code"), created, updated, archived (UTC times), pin, sort, model, context
  //   shown      the first message shown (chats.sel), as a message number
  //   messages   every message of every version, in the order they were made: node (its number in the chat),
  //              parent, shown (the follower shown), role, text, thinking, thinkingMillis, bookmark, stopped,
  //              conv, stats. A value that is not set is left out.
  // Copying files into the folder adds their chats. A file whose chat id another file already has (the same chat
  // copied twice, renamed on the way) becomes a chat of its own with a new id: the two may have gone on differently
  // since they were one, and keeping both loses nothing.

  /// The version of the files' layout.
  static const fileFormat = 1;

  /// How long a change waits before it is written to its chat's file: a reply that grows is written once per this
  /// time, with every change made meanwhile.
  static const writeDelay = Duration(seconds: 2);

  /// The chats whose files are behind the index, and the timer that writes them.
  final _dirty = <String>{};
  Timer? _writeTimer;

  static const _fileJson = JsonEncoder.withIndent(' ');

  static String _folderOf(ChatKind kind) => kind == ChatKind.code ? 'Code' : 'Chat';

  /// A path of the index ("Chat/Title.json") on the disk.
  String _onDisk(String path) =>
      '${_folder!.path}${Platform.pathSeparator}${path.replaceAll('/', Platform.pathSeparator)}';

  /// The chat changed: its file is written soon.
  void _changed(String chatId) {
    if (_folder == null) return;
    if (_dirty.add(chatId)) {
      _db.execute('INSERT INTO files (chat, dirty) VALUES (?, 1) ON CONFLICT (chat) DO UPDATE SET dirty = 1', [chatId]);
    }
    _writeTimer ??= Timer(writeDelay, writeFiles);
  }

  /// Writes every chat's file that is behind the index. A file that cannot be written stays marked, for the next try.
  void writeFiles() {
    _writeTimer?.cancel();
    _writeTimer = null;
    for (final id in [..._dirty]) {
      try {
        _writeFile(id);
        _dirty.remove(id);
      } catch (e) {
        stderr.writeln('Run My AI: could not save the chat $id to its file: $e');
      }
    }
  }

  void _writeFile(String chatId) {
    final c = _db.select('SELECT * FROM chats WHERE id = ?', [chatId]).firstOrNull;
    if (c == null) return;
    final num = c['num'] as int;
    String? time(Object? ms) =>
        ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms as int, isUtc: true).toIso8601String();
    final kind = ChatKind.values[c['kind'] as int];
    final json = <String, Object?>{
      'format': fileFormat,
      'id': chatId,
      'title': c['title'],
      'kind': kind.name,
      'created': time(c['created']),
      'updated': time(c['updated']),
      if (c['archived'] != null) 'archived': time(c['archived']),
      if (c['pin'] != null) 'pin': c['pin'],
      if (c['sort'] != null) 'sort': c['sort'],
      if (c['model'] != null) 'model': c['model'],
      if (c['context'] != null) 'context': c['context'],
      if (c['sel'] != null) 'shown': (c['sel'] as int) & _placeMask,
      'messages': [
        for (final m in _db.select('SELECT * FROM messages WHERE id BETWEEN ? AND ? ORDER BY id', [_first(num), _last(num)]))
          {
            'node': (m['id'] as int) & _placeMask,
            if (m['parent'] != null) 'parent': (m['parent'] as int) & _placeMask,
            if (m['sel'] != null) 'shown': (m['sel'] as int) & _placeMask,
            'role': Role.values[m['role'] as int].name,
            'text': m['text'],
            if (m['thinking'] != null) 'thinking': m['thinking'],
            if (m['thinking_ms'] != null) 'thinkingMillis': m['thinking_ms'],
            if (m['bookmark'] != null) 'bookmark': true,
            if (m['stopped'] != null) 'stopped': true,
            if (m['conv'] != null) 'conv': m['conv'],
            if (m['stats'] case final String stats) 'stats': jsonDecode(stats),
          },
      ],
    };
    final had = _db.select('SELECT path FROM files WHERE chat = ?', [chatId]).firstOrNull?['path'] as String?;
    final path = _pathFor(chatId, kind, c['title'] as String, had);
    final file = File(_onDisk(path));
    file.parent.createSync(recursive: true);
    // A new title: the file is renamed first, so a crash in between leaves the chat in one file, never two.
    if (had != null && had != path && File(_onDisk(had)).existsSync()) File(_onDisk(had)).renameSync(file.path);
    // A temporary file first, renamed over the chat's file: a crash never leaves a half-written chat.
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(_fileJson.convert(json), flush: true);
    tmp.renameSync(file.path);
    _record(chatId, path, file.statSync());
  }

  void _record(String chatId, String path, FileStat stat, {bool dirty = false}) => _db.execute(
      'INSERT OR REPLACE INTO files (chat, path, mtime, size, dirty) VALUES (?, ?, ?, ?, ?)',
      [chatId, path, stat.modified.millisecondsSinceEpoch, stat.size, dirty ? 1 : 0]);

  /// The path of the chat's file for [title]: [had] while it still fits the title (as "Title.json" or
  /// "Title (2).json"), else the first free one of "Title.json", "Title (2).json" ... Names are compared ignoring
  /// case, as Windows and macOS do.
  String _pathFor(String chatId, ChatKind kind, String title, String? had) {
    final folder = _folderOf(kind);
    final base = chatFileName(title);
    if (had != null && had.startsWith('$folder/') && had.toLowerCase().endsWith('.json')) {
      final stem = had.substring(folder.length + 1, had.length - 5);
      if (stem == base || RegExp('^${RegExp.escape(base)} \\(\\d+\\)\$').hasMatch(stem)) return had;
    }
    final taken = {
      for (final r in _db.select('SELECT path FROM files WHERE path IS NOT NULL AND chat != ?', [chatId]))
        (r['path'] as String).toLowerCase(),
    };
    for (var n = 1;; n++) {
      final path = '$folder/${n == 1 ? base : '$base ($n)'}.json';
      final lower = path.toLowerCase();
      if (taken.contains(lower)) continue;
      // (A file of that name the index does not know: copied in while the app runs, so not overwritten.)
      if (lower != had?.toLowerCase() && File(_onDisk(path)).existsSync()) continue;
      return path;
    }
  }

  /// Brings the chats folder into the index: files that are new or changed since they were last read or written are
  /// read (a file wins over the index), chats whose files are gone are taken out, and chats whose files are behind
  /// (or that have none yet) are written.
  void scanFiles() {
    final onDisk = <String, (FileStat, ChatKind)>{};
    for (final kind in ChatKind.values) {
      final dir = Directory(_onDisk(_folderOf(kind)))..createSync(recursive: true);
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.path.substring(dir.path.length + 1);
        if (name.endsWith('.json.tmp')) {
          // A write cut off by a crash; the chat's file itself is whole.
          f.deleteSync();
        } else if (name.toLowerCase().endsWith('.json')) {
          onDisk['${_folderOf(kind)}/$name'] = (f.statSync(), kind);
        }
      }
    }
    final records = _db.select('SELECT chat, path, mtime, size FROM files WHERE path IS NOT NULL');
    final pathOf = {for (final r in records) r['chat'] as String: r['path'] as String};
    final known = {for (final r in records) r['path'] as String: r};
    // The files as they were last read or written first, then the rest.
    final owner = <String, String>{}; // path -> the chat whose file it is
    final changed = <String>[];
    for (final MapEntry(key: path, value: (stat, _)) in onDisk.entries) {
      final r = known[path];
      if (r != null &&
          r['mtime'] == stat.modified.millisecondsSinceEpoch &&
          r['size'] == stat.size &&
          _num.containsKey(r['chat'])) {
        owner[path] = r['chat'] as String;
      } else {
        changed.add(path);
      }
    }
    for (final path in changed..sort()) {
      final (stat, kind) = onDisk[path]!;
      final _ChatFile chat;
      try {
        chat = _ChatFile.parse(File(_onDisk(path)).readAsStringSync());
      } catch (e) {
        stderr.writeln('Run My AI: the chat file $path could not be read and is left out: $e');
        continue;
      }
      if (chat.format > fileFormat) {
        stderr.writeln('Run My AI: the chat file $path was saved by a newer version of the app and is left out');
        continue;
      }
      var id = chat.id;
      final at = pathOf[id];
      if (at != null && at != path && owner[at] == id) {
        // The same chat in a second file: it becomes a chat of its own.
        id = '${DateTime.now().microsecondsSinceEpoch}';
        while (_num.containsKey(id)) {
          id = '${int.parse(id) + 1}';
        }
      }
      _import(chat, id, path, kind, stat);
      pathOf[id] = path;
      owner[path] = id;
    }
    // Chats whose files are gone (deleted, or replaced by another chat's file).
    for (final r in _db.select('SELECT chat, path FROM files WHERE path IS NOT NULL')) {
      if (owner[r['path'] as String] != r['chat']) _forget(r['chat'] as String);
    }
    _dirty.addAll([
      for (final r in _db.select(
          'SELECT id FROM chats WHERE id NOT IN (SELECT chat FROM files WHERE path IS NOT NULL AND dirty = 0)'))
        r['id'] as String,
    ]);
    writeFiles();
  }

  /// Puts [chat], read from its file at [path], into the index as chat [id] (a new id when the file's is taken),
  /// in place of what the index had for it.
  void _import(_ChatFile chat, String id, String path, ChatKind kind, FileStat stat) {
    // A chat given a new id gets new conversation ids too, so the engine's saved states of the two are not mixed.
    String? conv(String? c) =>
        id != chat.id && c != null && c.startsWith(chat.id) ? '$id${c.substring(chat.id.length)}' : c;
    _inTransaction(() {
      var num = _num[id];
      if (num == null) {
        num = _insertChat(id, chat.title, chat.created, chat.updated, kind);
      } else {
        _db.execute('DELETE FROM messages_fts WHERE rowid IN (SELECT id FROM messages WHERE id BETWEEN ? AND ?)',
            [_first(num), _last(num)]);
        _db.execute('DELETE FROM messages WHERE id BETWEEN ? AND ?', [_first(num), _last(num)]);
      }
      final first = _first(num);
      _db.execute(
          'UPDATE chats SET title = ?, created = ?, updated = ?, kind = ?, pin = ?, sort = ?, archived = ?, model = ?, '
          'context = ?, sel = ? WHERE id = ?',
          [chat.title, chat.created, chat.updated, kind.index, chat.pin, chat.sort, chat.archived, chat.model,
              chat.context, chat.shown == null ? null : first | chat.shown!, id]);
      final insert = _db.prepare('INSERT INTO messages (id, role, text, bookmark, thinking, thinking_ms, stopped, parent, '
          'sel, conv, stats) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
      final words = _db.prepare('INSERT INTO messages_fts (rowid, words) VALUES (?, ?)');
      try {
        for (final m in chat.messages) {
          insert.execute([first | m.node, m.role.index, m.text, m.bookmark ? 1 : null, m.thinking, m.thinkingMillis,
              m.stopped ? 1 : null, m.parent == null ? null : first | m.parent!, m.shown == null ? null : first | m.shown!,
              conv(m.conv), m.stats]);
          words.execute([first | m.node, searchWords(m.text)]);
        }
      } finally {
        insert.close();
        words.close();
      }
      // (A chat given a new id is written again at once, with that id.)
      _record(id, path, stat, dirty: id != chat.id);
    });
    if (id != chat.id) _dirty.add(id);
  }

  // ---- Chats saved by older versions -----------------------------------------------------------------------------

  void _moveInOldChats(Directory dir) {
    final folder = Directory('${dir.path}${Platform.pathSeparator}chats');
    final pinsFile = File('${dir.path}${Platform.pathSeparator}pins.json');
    if (!folder.existsSync()) return;
    final files = folder.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
    // (The chats folder of today is this folder too: its chats are in Chat/ and Code/, not here.)
    if (files.isEmpty) return;
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

/// The file name (without ".json") for a chat titled [title], allowed on Linux, Windows and macOS: the characters
/// / \\ : * ? " < > | and control characters become "_", spaces and dots at the ends go (Windows drops trailing ones,
/// and a leading dot hides a file on Linux), a name Windows keeps for devices (CON, NUL, COM1 ...) gets "_" in front,
/// a long title is cut (whole characters, at most 100 of them and 180 bytes, so the path stays short enough for
/// Windows), and an empty one becomes "Untitled".
String chatFileName(String title) {
  var name = title.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f\x7f]'), '_').trim();
  var bytes = 0, end = 0; // end: in UTF-16 units, as Windows counts a name
  for (final rune in name.runes) {
    final units = rune > 0xffff ? 2 : 1;
    final size = utf8.encode(String.fromCharCode(rune)).length;
    if (end + units > 100 || bytes + size > 180) break;
    bytes += size;
    end += units;
  }
  name = name.substring(0, end).replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  if (name.isEmpty) return 'Untitled';
  if (RegExp(r'^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³]) *(\.|$)', caseSensitive: false).hasMatch(name)) name = '_$name';
  return name;
}

/// A chat as its file holds it (see "The chat files" in [ChatDb]), checked as it is read: a value of the wrong type
/// makes the whole file unreadable rather than half read.
class _ChatFile {
  _ChatFile._(Map<String, Object?> json)
      : format = json['format'] as int,
        id = json['id'] as String,
        title = json['title'] as String,
        created = _time(json['created'])!,
        updated = _time(json['updated'])!,
        archived = _time(json['archived']),
        pin = json['pin'] as int?,
        sort = (json['sort'] as num?)?.toDouble(),
        model = json['model'] as String?,
        context = json['context'] as int?,
        shown = _node(json['shown']),
        messages = [for (final m in json['messages'] as List) _FileMessage((m as Map).cast<String, Object?>())];

  factory _ChatFile.parse(String text) => _ChatFile._((jsonDecode(text) as Map).cast<String, Object?>());

  final int format;
  final String id;
  final String title;
  final int created;
  final int updated;
  final int? archived;
  final int? pin;
  final double? sort;
  final String? model;
  final int? context;
  final int? shown;
  final List<_FileMessage> messages;

  static int? _time(Object? t) => t == null ? null : DateTime.parse(t as String).millisecondsSinceEpoch;

  static int? _node(Object? n) {
    if (n == null) return null;
    if (n is! int || n < 0 || n > ChatDb._placeMask) throw FormatException('not a message number: $n');
    return n;
  }
}

class _FileMessage {
  _FileMessage(Map<String, Object?> m)
      : node = _ChatFile._node(m['node'])!,
        parent = _ChatFile._node(m['parent']),
        shown = _ChatFile._node(m['shown']),
        role = Role.values.byName(m['role'] as String),
        text = m['text'] as String,
        thinking = m['thinking'] as String?,
        thinkingMillis = m['thinkingMillis'] as int?,
        bookmark = m['bookmark'] as bool? ?? false,
        stopped = m['stopped'] as bool? ?? false,
        conv = m['conv'] as String?,
        stats = m['stats'] is Map ? jsonEncode(m['stats']) : null;

  final int node;
  final int? parent;
  final int? shown;
  final Role role;
  final String text;
  final String? thinking;
  final int? thinkingMillis;
  final bool bookmark;
  final bool stopped;
  final String? conv;
  final String? stats;
}
