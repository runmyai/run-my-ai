import '../data/models.dart';

/// Search across chats: titles, the user's messages and the AI's replies.
///
/// Words match whole, except the last word typed while no space follows it yet: it matches any word that starts
/// with it ("No pro" finds "No problem"; "No pro " only the word "pro"). Upper / lower case and accents are
/// ignored. A chat is ranked by the best of:
///   1. the words exactly as typed, one after another;
///   2. all the words in one message (or the title), in any order - the closer together, the higher;
///   3. all the words, but spread over different messages;
///   4. only some of the words - the more of them, the higher (filler words such as "is" or "the" do not count here).
/// Inside levels 1-3 a match in the title comes first; then, in every level, the most recently used chat.
/// The same search over the same chats always gives the same order.

/// Words that alone never make a chat match (level 4). Edit this list to change which words count as filler.
const fillerWords = {
  'a', 'an', 'the', 'and', 'or', 'but', 'nor', 'so', 'if', 'then', 'than', 'not', 'no',
  'is', 'am', 'are', 'was', 'were', 'be', 'been', 'being', 'do', 'does', 'did', 'has', 'have', 'had',
  'of', 'to', 'in', 'on', 'at', 'by', 'for', 'with', 'from', 'as', 'into', 'about', 'up', 'out',
  'it', 'its', 'this', 'that', 'these', 'those', 'there', 'here',
  'i', 'me', 'my', 'we', 'us', 'our', 'you', 'your', 'he', 'him', 'his', 'she', 'her', 'they', 'them', 'their',
  // What is left of "it's", "don't", "I'll", "we're", "I've", "I'd", "I'm" once the apostrophe splits them.
  's', 't', 'll', 're', 've', 'd', 'm',
};

/// What the user typed, split into words. Each word is kept as a "term": the word itself, or for a last word still
/// being typed, the word with "*" after it, which matches any word starting with it ("pro*": "problem").
class SearchQuery {
  SearchQuery._(this.words)
      : distinct = words.toSet(),
        // A word still being typed counts as filler when it is a filler word itself ("harin is").
        nonFiller = words.where((w) => !fillerWords.contains(_bare(w))).toSet() {
    keyWords = nonFiller.isNotEmpty ? nonFiller : distinct;
  }

  factory SearchQuery.parse(String text) {
    final words = _Text(text).words;
    // No space (or other separator) after the last word yet: it is still being typed.
    if (words.isNotEmpty && _endsInWord.hasMatch(text)) words.last = '${words.last}*';
    return SearchQuery._(words);
  }

  /// The terms in the order typed.
  final List<String> words;
  final Set<String> distinct;
  final Set<String> nonFiller;

  /// The words that are highlighted and that make a message a match on their own: the non-filler words, or all
  /// the words when every one of them is filler.
  late final Set<String> keyWords;

  bool get isEmpty => words.isEmpty;
}

final _endsInWord = RegExp(r'[\p{L}\p{M}\p{N}]$', unicode: true);

/// A term without its "*".
String _bare(String term) => term.endsWith('*') ? term.substring(0, term.length - 1) : term;

/// Whether the text's [word] is [term]: the same word, or for a term ending in "*", a word that starts with it.
bool _isTerm(String word, String term) =>
    term.endsWith('*') ? word.startsWith(term.substring(0, term.length - 1)) : word == term;

/// A start and end position in a text (end not included).
typedef Span = ({int start, int end});

/// One chat in the results: what the sidebar shows for it, and where its best match is.
class ChatHit {
  const ChatHit({
    required this.chatId,
    required this.title,
    required this.updatedAt,
    required this.level,
    required this.inTitle,
    required this.score,
    required this.titleSpans,
    this.messageIndex,
    this.messageRole,
    this.messageSpan,
    this.snippet = '',
    this.snippetSpans = const [],
    this.snippetPending = false,
  });

  final String chatId;
  final String title;
  final DateTime updatedAt;

  /// 1-4, as described at the top of this file.
  final int level;
  final bool inTitle;

  /// Lower is better: the distance between the words (level 2), or minus the number of words found (level 4).
  final int score;

  /// The matching words in the chat's title.
  final List<Span> titleSpans;

  /// The message that matches best (shown under the title and jumped to), or null when only the title matches.
  final int? messageIndex;
  final Role? messageRole;

  /// Where that message's match starts and ends.
  final Span? messageSpan;

  /// One line of that message, starting a few words before the match ("…" in front when cut), and the words in
  /// it to show in bold.
  final String snippet;
  final List<Span> snippetSpans;

  /// The best message was found from the word index, and its line is not read yet ([withLineFrom] fills it in).
  final bool snippetPending;

  /// This hit with the line under the title taken from message [messageIndex] (its [messageText] and [role]).
  ChatHit withLineFrom(String messageText, Role role, SearchQuery query) {
    final t = _Text(messageText);
    final match = _matchPlace(t, query);
    if (match == null) return this;
    final (line, spans) = _snippet(messageText, match.span, _highlights(t, query));
    return ChatHit(
      chatId: chatId,
      title: title,
      updatedAt: updatedAt,
      level: level,
      inTitle: inTitle,
      score: score,
      titleSpans: titleSpans,
      messageIndex: messageIndex,
      messageRole: role,
      messageSpan: match.span,
      snippet: line,
      snippetSpans: spans,
    );
  }
}

/// The chats that match [query], best first (all chats and messages in memory; the app searches its database
/// with [ChatMatcher] directly, which gives the same results).
List<ChatHit> searchChats(List<Chat> chats, SearchQuery query) {
  if (query.isEmpty) return const [];
  final matcher = ChatMatcher(query);
  for (final chat in chats) {
    matcher.addChat(chat.id, chat.title, chat.updatedAt);
    for (var i = 0; i < chat.messages.length; i++) {
      matcher.addMessage(chat.id, i, chat.messages[i].role, chat.messages[i].text);
    }
  }
  return matcher.results();
}

/// The messages of [chat] that match [query], in the chat's order.
List<int> matchingMessages(Chat chat, SearchQuery query) => [
      for (var i = 0; i < chat.messages.length; i++)
        if (_matchPlace(_textOf(chat.messages[i]), query) != null) i,
    ];

/// Where [message] matches [query] best (null when it does not match).
Span? bestMatch(ChatMessage message, SearchQuery query) => _matchPlace(_textOf(message), query)?.span;

/// The parts of [message] to highlight: every exact run of the typed words, and every key word.
List<Span> highlightsIn(ChatMessage message, SearchQuery query) => _highlights(_textOf(message), query);

/// The words of [text] as the search sees them (lower case, no accents), one space between them: what the
/// database's word index is given, so it splits text into words exactly as this file does.
String searchWords(String text) => _Text(text).words.join(' ');

/// Ranks chats for one search. Give it every chat's title ([addChat]) and the messages that may match
/// ([addMessage], in each chat's order); the chat's best message and the words found are kept, the texts are not.
/// Words a chat holds in messages that were not given can be added with [addFound], and a best message known
/// from the word index alone with [addMessageFromIndex].
class ChatMatcher {
  ChatMatcher(this.query);

  final SearchQuery query;
  final _chats = <String, _ChatState>{};

  void addChat(String id, String title, DateTime updatedAt) {
    final t = _Text(title);
    _chats[id] = _ChatState(title, updatedAt, t, _matchPlace(t, query))..found.addAll(query.distinct.where(t.has));
  }

  /// [index] is the message's place in its chat; messages of one chat must come in that order.
  void addMessage(String chatId, int index, Role role, String text) {
    final chat = _chats[chatId];
    if (chat == null) return;
    final t = _Text(text);
    chat.found.addAll(query.distinct.where(t.has));
    final m = _matchPlace(t, query);
    // Only a better match replaces the best one, so on a tie the earliest message stays.
    if (m != null && (chat.best == null || m.isBetterThan(chat.best!))) {
      chat.best = m;
      chat.bestIndex = index;
      chat.bestRole = role;
      final (line, spans) = _snippet(text, m.span, _highlights(t, query));
      chat
        ..snippet = line
        ..snippetSpans = spans
        ..snippetPending = false;
    }
  }

  /// Message [index] matches at [level] / [score] (known from the word index, the same as [addMessage] would find);
  /// its text is read later, only if its line is shown.
  void addMessageFromIndex(String chatId, int index, int level, int score) {
    final chat = _chats[chatId];
    if (chat == null) return;
    final m = _Match(level, score, (start: 0, end: 0));
    if (chat.best == null || m.isBetterThan(chat.best!)) {
      chat
        ..best = m
        ..bestIndex = index
        ..bestRole = null
        ..snippet = ''
        ..snippetSpans = const []
        ..snippetPending = true;
    }
  }

  /// The chat holds the term [word] in a message that was not given.
  void addFound(String chatId, String word) => _chats[chatId]?.found.add(word);

  /// A message holds the words exactly as typed (no other message can be a better match).
  bool hasExactMessage(String chatId) => _chats[chatId]?.best?.level == 1;

  /// A message holds all the words (level 1 or 2).
  bool hasStrongMessage(String chatId) => (_chats[chatId]?.best?.level ?? 9) <= 2;

  /// The best message so far holds every key word (no message with only some words can do better).
  bool hasAllKeyWords(String chatId) => (_chats[chatId]?.best?.score ?? 0) <= -query.keyWords.length;

  /// The typed words not found yet in the chat's title or the messages given.
  Iterable<String> missingWords(String chatId) => query.distinct.where((w) => !_chats[chatId]!.found.contains(w));

  /// The chats whose level still depends on words not found yet: every key word found (without one, no other word
  /// can lift a chat), but not every word, and neither the title nor a message holds them all.
  Iterable<String> chatsToCheck() => [
        for (final MapEntry(key: id, value: c) in _chats.entries)
          if (query.keyWords.every(c.found.contains) &&
              c.found.length < query.distinct.length &&
              (c.titleMatch?.level ?? 9) > 2 &&
              (c.best?.level ?? 9) > 2)
            id,
      ];

  /// The chats that match, best first.
  List<ChatHit> results() {
    final hits = <ChatHit>[];
    for (final MapEntry(key: id, value: chat) in _chats.entries) {
      final hit = chat.hit(id, query);
      if (hit != null) hits.add(hit);
    }
    return hits..sort(_compareHits);
  }
}

class _ChatState {
  _ChatState(this.title, this.updatedAt, this.titleText, this.titleMatch);

  final String title;
  final DateTime updatedAt;
  final _Text titleText;
  final _Match? titleMatch;
  final found = <String>{};
  _Match? best;
  int? bestIndex;
  Role? bestRole;
  String snippet = '';
  List<Span> snippetSpans = const [];
  bool snippetPending = false;

  ChatHit? hit(String id, SearchQuery q) {
    int level;
    bool inTitle;
    int score;
    final strongTitle = titleMatch != null && titleMatch!.level <= 2 ? titleMatch : null;
    final strongMessage = best != null && best!.level <= 2 ? best : null;
    if (strongTitle != null && (strongMessage == null || strongTitle.level <= strongMessage.level)) {
      (level, inTitle, score) = (strongTitle.level, true, strongTitle.score);
    } else if (strongMessage != null) {
      (level, inTitle, score) = (strongMessage.level, false, strongMessage.score);
    } else if (q.distinct.every(found.contains)) {
      (level, inTitle, score) = (3, q.keyWords.any(titleText.has), 0);
    } else {
      final count = q.nonFiller.where(found.contains).length;
      if (count == 0) return null;
      (level, inTitle, score) = (4, q.nonFiller.any(titleText.has), -count);
    }
    return ChatHit(
      chatId: id,
      title: title,
      updatedAt: updatedAt,
      level: level,
      inTitle: inTitle,
      score: score,
      titleSpans: _highlights(titleText, q),
      messageIndex: bestIndex,
      messageRole: bestRole,
      messageSpan: snippetPending ? null : best?.span,
      snippet: snippet,
      snippetSpans: snippetSpans,
      snippetPending: snippetPending,
    );
  }
}

/// One line of [text] around [match]: from the start when the match is near it, else from a few words before it.
(String, List<Span>) _snippet(String text, Span match, List<Span> marks) {
  // Line breaks become spaces (one character for one, so the positions stay right).
  final flat = text.replaceAll(RegExp(r'\s'), ' ');
  var from = 0;
  if (match.start > 25) {
    final space = flat.indexOf(' ', match.start - 15);
    from = space >= 0 && space < match.start ? space + 1 : match.start;
  }
  final to = (from + 200).clamp(0, flat.length);
  final prefix = from > 0 ? '…' : '';
  final shift = prefix.length - from;
  return (
    '$prefix${flat.substring(from, to)}',
    [
      for (final m in marks)
        if (m.end > from && m.start < to) (start: (m.start.clamp(from, to)) + shift, end: (m.end.clamp(from, to)) + shift),
    ],
  );
}

int _compareHits(ChatHit a, ChatHit b) {
  int byTitle() => (a.inTitle ? 0 : 1) - (b.inTitle ? 0 : 1);
  var c = a.level - b.level;
  if (c == 0) {
    // Level 4: more words found beats a title match.
    c = a.level == 4 ? a.score - b.score : byTitle();
    if (c == 0) c = a.level == 4 ? byTitle() : a.score - b.score;
  }
  if (c == 0) c = b.updatedAt.compareTo(a.updatedAt);
  if (c == 0) c = b.chatId.compareTo(a.chatId);
  return c;
}

/// How one text (a title or a message) matches: level 1 (exact run), 2 (all words) or 4 (some key words).
class _Match {
  const _Match(this.level, this.score, this.span);

  final int level;
  final int score;
  final Span span;

  bool isBetterThan(_Match other) => level != other.level ? level < other.level : score < other.score;
}

_Match? _matchPlace(_Text t, SearchQuery q) {
  if (!q.distinct.any(t.has)) return null;
  final w = t.words;
  final n = q.words.length;

  // 1. The words exactly as typed.
  for (var i = 0; i + n <= w.length; i++) {
    var same = true;
    for (var j = 0; j < n && same; j++) {
      same = _isTerm(w[i + j], q.words[j]);
    }
    if (same) return _Match(1, 0, (start: t.starts[i], end: t.ends[i + n - 1]));
  }

  // 2. All the words: the shortest stretch of the text that holds them all. (A word can be two terms at once:
  // "pro" is both "pro" and "pr*".)
  if (q.distinct.every(t.has)) {
    final terms = [for (final word in w) q.distinct.where((term) => _isTerm(word, term)).toList()];
    final counts = <String, int>{};
    var have = 0;
    var bestLo = 0, bestHi = w.length - 1;
    var lo = 0;
    for (var hi = 0; hi < w.length; hi++) {
      if (terms[hi].isEmpty) continue;
      for (final term in terms[hi]) {
        if ((counts[term] = (counts[term] ?? 0) + 1) == 1) have++;
      }
      while (have == q.distinct.length) {
        if (terms[lo].isNotEmpty) {
          if (hi - lo < bestHi - bestLo) (bestLo, bestHi) = (lo, hi);
          for (final term in terms[lo]) {
            if ((counts[term] = counts[term]! - 1) == 0) have--;
          }
        }
        lo++;
      }
    }
    return _Match(2, bestHi - bestLo, (start: t.starts[bestLo], end: t.ends[bestHi]));
  }

  // 4. Some of the key words.
  final found = q.keyWords.where(t.has).length;
  if (found == 0 || q.nonFiller.isEmpty) return null;
  final first = w.indexWhere((word) => q.keyWords.any((term) => _isTerm(word, term)));
  return _Match(4, -found, (start: t.starts[first], end: t.ends[first]));
}

List<Span> _highlights(_Text t, SearchQuery q) {
  if (q.isEmpty) return const [];
  final w = t.words;
  final n = q.words.length;
  final spans = <Span>[];
  for (var i = 0; i < w.length; i++) {
    var run = i + n <= w.length;
    for (var j = 0; j < n && run; j++) {
      run = _isTerm(w[i + j], q.words[j]);
    }
    if (run) {
      spans.add((start: t.starts[i], end: t.ends[i + n - 1]));
    } else if (q.keyWords.any((term) => _isTerm(w[i], term))) {
      spans.add((start: t.starts[i], end: t.ends[i]));
    }
  }
  // Join spans that overlap (a run of words and a word inside it).
  final joined = <Span>[];
  for (final s in spans) {
    if (joined.isNotEmpty && s.start <= joined.last.end) {
      if (s.end > joined.last.end) joined.last = (start: joined.last.start, end: s.end);
    } else {
      joined.add(s);
    }
  }
  return joined;
}

// ---------------------------------------------------------------------------------------------------------------
// The open chat's messages are split into words once and kept while the messages are (for its highlights and the
// "1 of 4" bar): messages never change after they are written (a reply being written is a new message object for
// every piece).

final _messageTexts = Expando<_Text>();

_Text _textOf(ChatMessage m) => _messageTexts[m] ??= _Text(m.text);

/// A text split into normalized words, with where each word starts and ends in the original text.
class _Text {
  _Text(String text) {
    for (final m in _wordPattern.allMatches(text)) {
      final word = _normalize(m[0]!);
      if (word.isEmpty) continue;
      words.add(word);
      starts.add(m.start);
      ends.add(m.end);
    }
    set = words.toSet();
  }

  final words = <String>[];
  final starts = <int>[];
  final ends = <int>[];
  late final Set<String> set;

  /// Whether the text holds [term] (a word, or a word starting with a term ending in "*").
  bool has(String term) => term.endsWith('*') ? words.any((w) => _isTerm(w, term)) : set.contains(term);
}

/// Letters (with any accent marks written after them) and digits; everything else separates words.
final _wordPattern = RegExp(r'[\p{L}\p{M}\p{N}]+', unicode: true);
final _markPattern = RegExp(r'\p{M}', unicode: true);

String _normalize(String word) {
  final lower = word.toLowerCase();
  if (!lower.codeUnits.any((u) => u > 127)) return lower;
  final out = StringBuffer();
  for (final r in lower.runes) {
    final ch = String.fromCharCode(r);
    out.write(_plain[ch] ?? ch);
  }
  return out.toString().replaceAll(_markPattern, '');
}

/// Accented letters and the plain letter they are searched as.
final Map<String, String> _plain = {
  for (final (accented, plain) in const [
    ('àáâãäåāăą', 'a'),
    ('çćĉċč', 'c'),
    ('ďđ', 'd'),
    ('èéêëēĕėęě', 'e'),
    ('ĝğġģ', 'g'),
    ('ĥħ', 'h'),
    ('ìíîïĩīĭįı', 'i'),
    ('ĵ', 'j'),
    ('ķ', 'k'),
    ('ĺļľŀł', 'l'),
    ('ñńņňŉ', 'n'),
    ('òóôõöøōŏő', 'o'),
    ('ŕŗř', 'r'),
    ('śŝşšș', 's'),
    ('ţťŧț', 't'),
    ('ùúûüũūŭůűų', 'u'),
    ('ŵ', 'w'),
    ('ýÿŷ', 'y'),
    ('źżž', 'z'),
  ])
    for (final ch in accented.split('')) ch: plain,
};
