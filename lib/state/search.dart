import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../search/chat_search.dart';
import 'chats.dart';
import 'providers.dart';

class SearchState {
  const SearchState({this.open = false, this.text = ''});

  /// Whether the search box is shown (in place of New chat).
  final bool open;
  final String text;
}

/// The search box in the sidebar.
class SearchNotifier extends Notifier<SearchState> {
  @override
  SearchState build() => const SearchState();

  void open() => state = SearchState(open: true, text: state.text);

  void setText(String text) => state = SearchState(open: true, text: text);

  /// Closes the box, forgets the text and takes the highlights off the open chat.
  void close() {
    state = const SearchState();
    ref.read(findProvider.notifier).close();
  }
}

final searchProvider = NotifierProvider<SearchNotifier, SearchState>(SearchNotifier.new);

/// The search's results, and whether a newer search is still running.
class SearchResults {
  const SearchResults({this.hits = const [], this.pending = false, this.slow = false});

  /// The matching chats, best first.
  final List<ChatHit> hits;

  /// A search for the latest text has not finished; [hits] are still the ones before it.
  final bool pending;

  /// ... and it has been running for a while (the sidebar then says "Searching…").
  final bool slow;
}

/// Searches the chats database on its worker each time the text changes (and when chats change while the box is
/// open). The old results stay until the new ones arrive; a newer search stops the older one.
class SearchResultsNotifier extends Notifier<SearchResults> {
  int _latest = 0;
  Timer? _slow;

  @override
  SearchResults build() {
    ref.listen(searchProvider, (_, _) => _run());
    // Renamed, deleted or new chats change the results, and so does a reply once it is saved.
    ref.listen(chatsProvider.select((s) => s.chats), (_, _) => _run());
    // Chat and Code each search their own chats.
    ref.listen(chatsProvider.select((s) => s.kind), (_, _) => _run());
    ref.listen(chatsProvider.select((s) => s.replyingId), (_, id) {
      if (id == null) _run();
    });
    ref.onDispose(() => _slow?.cancel());
    // The first search (the text was typed before anything asked for results); until it answers, the sidebar
    // shows nothing rather than "No chats match.".
    Future.microtask(_run);
    final search = ref.read(searchProvider);
    return SearchResults(pending: search.open && !SearchQuery.parse(search.text).isEmpty);
  }

  Future<void> _run() async {
    final search = ref.read(searchProvider);
    final serial = ++_latest;
    _slow?.cancel();
    if (!search.open || SearchQuery.parse(search.text).isEmpty) {
      state = const SearchResults();
      return;
    }
    state = SearchResults(hits: state.hits, pending: true);
    _slow = Timer(const Duration(milliseconds: 300), () {
      if (serial == _latest) state = SearchResults(hits: state.hits, pending: true, slow: true);
    });
    final hits = await ref.read(chatStoreProvider).search(search.text, ref.read(chatsProvider).kind);
    if (!ref.mounted || serial != _latest || hits == null) return;
    _slow?.cancel();
    _filling = false;
    state = SearchResults(hits: hits);
  }

  bool _filling = false;

  /// The list reached result [index], whose line under the title is not read yet: reads the lines of the next
  /// results (one batch at a time).
  Future<void> needLines(int index) async {
    if (_filling || state.pending) return;
    final serial = _latest;
    final hits = state.hits;
    final batch = hits.skip(index).take(50).toList();
    if (batch.every((h) => !h.snippetPending)) return;
    _filling = true;
    final filled = await ref.read(chatStoreProvider).fillLines(ref.read(searchProvider).text, batch);
    _filling = false;
    if (!ref.mounted || serial != _latest || !identical(hits, state.hits)) return;
    state = SearchResults(hits: [...hits.take(index), ...filled, ...hits.skip(index + filled.length)]);
  }
}

final searchResultsProvider = NotifierProvider<SearchResultsNotifier, SearchResults>(SearchResultsNotifier.new);

/// A chat opened from the search results: its matches are highlighted and the "1 of 4" bar steps through them.
class FindState {
  const FindState({required this.chatId, required this.query, required this.messageIndex});

  final String chatId;
  final SearchQuery query;

  /// The match on screen now (an index into the messages shown).
  final int messageIndex;
}

class FindNotifier extends Notifier<FindState?> {
  @override
  FindState? build() {
    // Opening another chat (not from the results) ends it.
    ref.listen(chatsProvider.select((s) => s.openId), (_, openId) {
      if (state != null && openId != state!.chatId) state = null;
    });
    return null;
  }

  void show({required String chatId, required SearchQuery query, required int messageIndex}) =>
      state = FindState(chatId: chatId, query: query, messageIndex: messageIndex);

  /// Opens the chat of a search result on the version that holds message [node] (the result's message number: it may
  /// be in a version other than the one the chat was left on) and shows its matches there.
  Future<void> showHit({required String chatId, required SearchQuery query, required int node}) async {
    final index = await ref.read(chatsProvider.notifier).openAt(chatId, node);
    if (!ref.mounted) return;
    state = index == null ? null : FindState(chatId: chatId, query: query, messageIndex: index);
  }

  /// Moves to the next match ([step] 1) or the one before ([step] -1), going round at the ends.
  void move(int step) {
    final find = state;
    final chat = ref.read(chatsProvider).open;
    if (find == null || chat == null || chat.id != find.chatId) return;
    final matches = matchingMessages(chat, find.query);
    if (matches.isEmpty) return;
    final at = matches.indexOf(find.messageIndex);
    final next = at < 0 ? 0 : (at + step) % matches.length;
    state = FindState(chatId: find.chatId, query: find.query, messageIndex: matches[next]);
  }

  void close() => state = null;
}

final findProvider = NotifierProvider<FindNotifier, FindState?>(FindNotifier.new);
