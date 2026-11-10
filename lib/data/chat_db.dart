import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import '../search/chat_search.dart';
import 'models.dart';
import 'reply_stats.dart';

/// The chats, saved in one SQLite database (chats.db in the app's data folder), with a word index for search.
///
/// Tables:
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
///   benchmarks     one row per benchmark run, newest last: the run's details and its shrunk graphs as one JSON text.
///                  Only the newest ChatDb.maxBenchmarks runs are kept.
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
    // Version 10: the history of benchmark runs, newest last; each run's details as one JSON text.
    if (_db.userVersion < 10) {
      _db.execute('CREATE TABLE IF NOT EXISTS benchmarks (id INTEGER PRIMARY KEY AUTOINCREMENT, data TEXT NOT NULL)');
      _db.userVersion = 10;
    }
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
  }

  void close() {
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
  List<String> pins() => [for (final r in _db.select('SELECT id FROM chats WHERE pin IS NOT NULL ORDER BY pin')) r['id'] as String];

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
    final num = (_db.select('SELECT COALESCE(MAX(num), 0) + 1 AS n FROM chats').first['n'] as int);
    _db.execute(
      'INSERT INTO chats (id, num, title, created, updated, kind) VALUES (?, ?, ?, ?, ?, ?)',
      [chat.id, num, chat.title, chat.createdAt.millisecondsSinceEpoch, chat.updatedAt.millisecondsSinceEpoch, chat.kind.index],
    );
    _num[chat.id] = num;
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
    _db.execute('INSERT INTO benchmarks (data) VALUES (?)', [data]);
    final id = _db.lastInsertRowId;
    _db.execute('DELETE FROM benchmarks WHERE id NOT IN (SELECT id FROM benchmarks ORDER BY id DESC LIMIT ?)', [keep]);
    return id;
  }

  void deleteBenchmark(int id) => _db.execute('DELETE FROM benchmarks WHERE id = ?', [id]);

  /// Every benchmark run's id and details, the newest first.
  List<(int, String)> benchmarks() => [
    for (final r in _db.select('SELECT id, data FROM benchmarks ORDER BY id DESC')) (r['id'] as int, r['data'] as String),
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
  void setChoices(String chatId, String? modelId, int? contextLength) =>
      _db.execute('UPDATE chats SET model = ?, context = ? WHERE id = ?', [modelId, contextLength, chatId]);

  /// Removes message [node] of the chat and any message after it, with their words in the index.
  void removeMessage(String chatId, int node) => _inTransaction(() {
        final num = _num[chatId];
        if (num == null) return;
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
