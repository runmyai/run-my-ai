// The search's matching and ranking rules (lib/search/chat_search.dart).
// Run: flutter test test/chat_search_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/search/chat_search.dart';

var _clock = DateTime(2026, 10, 1);

/// A chat with [messages] (user, AI, user, ...); each new chat is one minute newer than the one before.
Chat chat(String id, List<String> messages, {String? title}) {
  _clock = _clock.add(const Duration(minutes: 1));
  return Chat(
    id: id,
    title: title ?? 'Chat $id',
    createdAt: _clock,
    updatedAt: _clock,
    messages: [for (var i = 0; i < messages.length; i++) ChatMessage(i.isEven ? Role.user : Role.assistant, messages[i])],
  );
}

List<String> ids(List<Chat> chats, String text) => [for (final h in searchChats(chats, SearchQuery.parse(text))) h.chatId];

void main() {
  test('exact words first, then close together, then spread out, then some words; filler alone never matches', () {
    final chats = [
      chat('some', ['Harin went home']),
      chat('spread', ['Where did Harin go?', 'He is at home']),
      chat('far', ['Harin went home and the dog is fine']),
      chat('reversed', ['Is it Harin?']),
      chat('exact', ['I think Harin is here']),
      chat('filler', ['This is it']),
    ];
    expect(ids(chats, 'Harin is'), ['exact', 'reversed', 'far', 'spread', 'some']);
  });

  test('a title match beats a message match in the same level; then the newest chat comes first', () {
    final chats = [
      chat('title', ['hello'], title: 'Harin is cool'),
      chat('old', ['Harin is cool']),
      chat('new', ['Harin is cool']),
    ];
    expect(ids(chats, 'harin is'), ['title', 'new', 'old']);
  });

  test('with only some words found, more words first, then a title match', () {
    final chats = [
      chat('two', ['apple and banana']),
      chat('one-title', ['nothing'], title: 'apple'),
      chat('one', ['apple pie']),
    ];
    expect(ids(chats, 'apple banana cherry'), ['two', 'one-title', 'one']);
  });

  test('upper / lower case and accents are ignored; a word followed by a space matches only whole', () {
    final chats = [chat('cafe', ['We met at the Café Rouge']), chat('name', ['HARIN said hi'])];
    expect(ids(chats, 'cafe'), ['cafe']);
    expect(ids(chats, 'CAFÉ rouge'), ['cafe']);
    expect(ids(chats, 'harin'), ['name']);
    expect(ids(chats, 'har '), isEmpty);
    expect(ids(chats, 'caf '), isEmpty);
    expect(ids(chats, 'met caf rouge'), ['cafe'], reason: 'only the last word can be a beginning');
  });

  test('the last word, with no space after it yet, matches the words starting with it', () {
    final chats = [
      chat('problem', ['No problem at all']),
      chat('progress', ['No progress today']),
      chat('pro', ['He is a pro']),
      chat('other', ['Nothing here']),
    ];
    // "No pro…" as typed in two chats (newest first); the third has only a word starting with "pro".
    expect(ids(chats, 'No pro'), ['progress', 'problem', 'pro']);
    expect(ids(chats, 'No pro '), ['pro'], reason: '"pro" followed by a space is only the whole word');
    expect(ids(chats, 'pro '), ['pro']);
    expect(ids(chats, 'pro'), ['pro', 'progress', 'problem']);
    expect(ids(chats, 'No problem'), ['problem']);
    expect(ids(chats, 'har'), isEmpty);
    // A last word that is a filler word itself still counts as filler: no chat matches on "is" alone.
    expect(ids(chats, 'nothing is'), ['other']);
  });

  test('a word started is highlighted whole (here both "No problem" and "no progress" match as typed)', () {
    const m = ChatMessage(Role.user, 'No problem, no progress.');
    expect(highlightsIn(m, SearchQuery.parse('no pro')), [(start: 0, end: 10), (start: 12, end: 23)]);
  });

  test("an apostrophe splits a word the same way in the chat and in the search", () {
    final chats = [chat('a', ["That is Harin's book"])];
    expect(ids(chats, "harin's book"), ['a']);
    expect(ids(chats, 'harin'), ['a']);
  });

  test('only filler words: the chat must hold them in a message or across it', () {
    final chats = [chat('both', ['this is it', 'the end']), chat('one', ['it is'])];
    expect(ids(chats, 'is the'), ['both']);
  });

  test('the best message is the one shown under the title and jumped to', () {
    final c = chat('a', ['Harin', 'nothing here', 'Harin is here', 'is Harin']);
    final hit = searchChats([c], SearchQuery.parse('Harin is')).single;
    expect(hit.messageIndex, 2);
    expect(hit.messageSpan, (start: 0, end: 8));
    expect(matchingMessages(c, SearchQuery.parse('Harin is')), [0, 2, 3]);
  });

  test('highlights: every exact run, and every non-filler word', () {
    const m = ChatMessage(Role.user, 'Harin is here, and Harin left.');
    expect(highlightsIn(m, SearchQuery.parse('harin is')), [(start: 0, end: 8), (start: 19, end: 24)]);
  });

  test('a chat whose title alone matches has no line under it', () {
    final hit = searchChats([chat('a', ['hello'], title: 'Trip planning')], SearchQuery.parse('trip')).single;
    expect(hit.messageIndex, isNull);
    expect(hit.titleSpans, [(start: 0, end: 4)]);
  });
}
