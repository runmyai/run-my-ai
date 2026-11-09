import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../search/chat_search.dart';
import '../../state/chats.dart';
import '../../state/drafts.dart';
import '../../state/library.dart';
import '../../state/motion.dart';
import '../../state/search.dart';
import '../../theme.dart';
import '../folded_text.dart';
import '../follow.dart';
import '../live_reply.dart';
import '../look.dart';
import '../marked_text.dart';

/// The Chat section: the conversation and the message box (the model picker sits in the window's top row).
/// A chat opened from the search results shows its matches highlighted and a bar to step through them.
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  static const contentWidth = 720.0;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> with TickerProviderStateMixin {
  final _scroll = ScrollController();

  /// One key per message of the open chat (by its index), so a message can be found on screen.
  final _keys = <int, GlobalKey>{};
  String? _keysChat;

  /// Counts the moves, so an older move still in progress stops when a newer one starts.
  int _jump = 0;

  /// The slide to a match or to the end (the "↓" button), while it runs.
  Ticker? _slider;

  /// Keeps the page at the end of the reply being written while the user is at the bottom (lib/ui/follow.dart).
  late final _follow = ReplyFollower(scroll: _scroll, vsync: this, held: () => _slider?.isActive ?? false);

  /// Long sent messages opened to their full length (by index; they fold again when the chat is opened again), and
  /// the keys of their arrows.
  final _open = <int>{};
  final _arrows = <int, GlobalKey>{};

  /// Keeps an arrow where it was clicked while its message folds.
  Ticker? _holder;

  /// The conversation is scrolled away from its top (a very light shadow lies under the window's top row).
  final _scrolled = ValueNotifier(false);

  /// How far down from the top of the view to hide: to the bottom of a line that is partly under the top row, so
  /// only whole lines show (0 when no line is cut).
  final _cover = ValueNotifier(0.0);

  /// The page is moving (scrolled or following); still again a moment after the last move. Moving, the text goes
  /// under the top row with a soft edge; still, a line left cut there fades out, so only whole lines show.
  final _moving = ValueNotifier(false);
  Timer? _still;

  /// A chat just opened is hidden for the few frames it takes to put it at its end.
  bool _opening = false;

  /// The bookmark being read: the last one at or above a third of the way down the view (null: above the first).
  final _bookmarkHere = ValueNotifier<int?>(null);

  /// A bookmark just jumped to: it lights up for a moment.
  int? _flashing;
  Timer? _flashOff;

  /// The chat page on screen (one at most), for Alt+Shift+↑ / ↓.
  static _ChatPageState? _shown;

  /// Room above the first message, and below the last. (Each message has room under it for its buttons, which is
  /// also the gap between messages.)
  static const _room = 26.0;
  static const _bottomRoom = 30.0;

  @override
  void initState() {
    super.initState();
    _shown = this;
    // Opened from the results while another section was showing: jump once the chat is on screen.
    final find = ref.read(findProvider);
    if (find != null && find.chatId == ref.read(chatsProvider).openId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(find.messageIndex, find.query));
    }
  }

  @override
  void dispose() {
    if (_shown == this) _shown = null;
    _bookmarkHere.dispose();
    _flashOff?.cancel();
    _slider?.dispose();
    _holder?.dispose();
    _scrolled.dispose();
    _cover.dispose();
    _still?.cancel();
    _moving.dispose();
    _follow.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _jumpTo(double offset) => _follow.jumpTo(offset);

  /// Finds a line of text cut by the top of the view (the top row's lower edge) and sets [_cover] to hide it to its
  /// bottom, so only whole lines show. Only the messages at the top edge are looked at, and in them only the text
  /// at that height, so it stays light while scrolling.
  void _updateCover() {
    if (!mounted) return;
    final view = _view();
    if (view == null) {
      _cover.value = 0;
      return;
    }
    final edge = view.localToGlobal(Offset.zero).dy;
    var cover = 0.0;
    bool across(RenderBox b) {
      if (!b.attached || !b.hasSize) return false;
      final top = b.localToGlobal(Offset.zero).dy;
      return top < edge && top + b.size.height > edge;
    }

    void visit(RenderObject o) {
      if (o is RenderParagraph || o is RenderEditable) {
        final r = o as RenderBox;
        if (!across(r)) return;
        final local = r.globalToLocal(Offset(r.localToGlobal(Offset.zero).dx + 1, edge));
        final List<TextBox> boxes;
        if (o is RenderEditable) {
          final at = o.getPositionForPoint(r.localToGlobal(local)).offset;
          final n = o.plainText.length;
          if (n == 0) return;
          final from = at.clamp(0, n - 1);
          boxes = o.getBoxesForSelection(TextSelection(baseOffset: from, extentOffset: from + 1));
        } else {
          final p = o as RenderParagraph;
          final at = p.getPositionForOffset(local).offset;
          final n = p.text.toPlainText(includeSemanticsLabels: false).length;
          if (n == 0) return;
          final from = at.clamp(0, n - 1);
          boxes = p.getBoxesForSelection(TextSelection(baseOffset: from, extentOffset: from + 1));
        }
        for (final b in boxes) {
          // The letters of this line are cut by the edge: hide down to their bottom.
          if (b.top < local.dy && b.bottom > local.dy) {
            cover = max(cover, r.localToGlobal(Offset(0, b.bottom)).dy - edge);
          }
        }
        return;
      }
      o.visitChildren(visit);
    }

    for (final key in _keys.values) {
      final box = key.currentContext?.findRenderObject();
      if (box is RenderBox && across(box)) visit(box);
    }
    // A bubble whose text is all hidden: its leftover lower edge is hidden too.
    void bubbles(RenderObject o) {
      if (o is RenderDecoratedBox && across(o)) {
        double? textBottom;
        void text(RenderObject t) {
          if (t is RenderParagraph || t is RenderEditable) {
            final r = t as RenderBox;
            if (r.attached && r.hasSize) {
              textBottom = max(textBottom ?? double.negativeInfinity, r.localToGlobal(Offset(0, r.size.height)).dy);
            }
            return;
          }
          t.visitChildren(text);
        }

        text(o);
        // (The text's box ends a few pixels below its last line's letters.)
        if (textBottom != null && textBottom! <= edge + cover + 8) {
          cover = max(cover, o.localToGlobal(Offset(0, o.size.height)).dy - edge);
        }
        return;
      }
      o.visitChildren(bubbles);
    }

    for (final key in _keys.values) {
      final box = key.currentContext?.findRenderObject();
      if (box is RenderBox && across(box)) bubbles(box);
    }
    _cover.value = cover;
  }

  /// The conversation's box on screen.
  RenderBox? _view() {
    final view = _scroll.hasClients ? _scroll.position.context.notificationContext?.findRenderObject() : null;
    return view is RenderBox && view.attached ? view : null;
  }

  /// Message [index]'s box, while it is built.
  RenderBox? _box(int index) {
    final box = _keys[index]?.currentContext?.findRenderObject();
    return box is RenderBox && box.attached ? box : null;
  }

  /// The open chat's bookmarks (the places of the messages marked as one), in order.
  List<int> _bookmarks() {
    final chat = ref.read(chatsProvider).open;
    if (chat == null) return const [];
    return [
      for (var i = 0; i < chat.messages.length; i++)
        if (chat.messages[i].bookmark) i,
    ];
  }

  /// Finds the bookmark being read (see [_bookmarkHere]).
  void _updateBookmark() {
    final view = _view();
    final bookmarks = _bookmarks();
    if (view == null || bookmarks.isEmpty) {
      _bookmarkHere.value = null;
      return;
    }
    final line = view.localToGlobal(Offset.zero).dy + view.size.height * 0.35;
    int? reached;
    for (final e in _keys.entries) {
      final box = _box(e.key);
      if (box != null && box.localToGlobal(Offset.zero).dy <= line && (reached == null || e.key > reached)) {
        reached = e.key;
      }
    }
    _bookmarkHere.value = reached == null ? null : bookmarks.where((c) => c <= reached!).lastOrNull;
  }

  /// Slides to bookmark [index], and lights it up for a moment.
  Future<void> _toBookmark(int index) async {
    await _skid(index, SearchQuery.parse(''));
    if (!mounted) return;
    setState(() => _flashing = index);
    _flashOff?.cancel();
    _flashOff = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _flashing = null);
    });
  }

  /// Alt+Shift+↓ ([step] 1): the next bookmark below the one being read (the first, above it). Alt+Shift+↑ (-1): the
  /// start of the bookmark being read when it is above the view, else the one before.
  void _stepBookmark(int step) {
    final bookmarks = _bookmarks();
    if (bookmarks.isEmpty) return;
    _updateBookmark();
    final here = _bookmarkHere.value;
    int? to;
    if (step > 0) {
      to = bookmarks.where((c) => here == null || c > here).firstOrNull;
    } else if (here != null) {
      final box = _box(here);
      final view = _view();
      final above =
          box == null || view == null || box.localToGlobal(Offset.zero).dy < view.localToGlobal(Offset.zero).dy - 4;
      to = above ? here : bookmarks.where((c) => c < here).lastOrNull;
    }
    if (to != null) _toBookmark(to);
  }

  /// A chat just opened: to its end (the list knows its full length only once the last messages are built, so it
  /// jumps until it stays there), then shown.
  Future<void> _toEnd(String chatId) async {
    final jump = _jump;
    for (var frames = 0; frames < 20; frames++) {
      if (!mounted || _keysChat != chatId) return;
      // Something else moved the page (a search match): it decides where the chat shows.
      if (jump != _jump || ref.read(findProvider)?.chatId == chatId) break;
      if (_scroll.hasClients) {
        final p = _scroll.position;
        if (p.pixels == p.maxScrollExtent) break;
        _jumpTo(p.maxScrollExtent);
      }
      await WidgetsBinding.instance.endOfFrame;
    }
    if (mounted && _opening && _keysChat == chatId) setState(() => _opening = false);
  }

  /// The "↓" button: slides to the end and follows the reply again.
  void _toNewest() {
    _slide(++_jump, () => _scroll.position.maxScrollExtent);
    _follow.resume();
  }

  /// Slides the page to [target] (asked again every frame, as it can change while the page moves): it skips most
  /// of a long way at once, then slides the last stretch in and brakes to a stop, so the messages in between are
  /// never scrolled past. A wheel, touchpad or click on the conversation stops it.
  void _slide(int jump, double Function() target) {
    _slider?.dispose();
    _slider = null;
    if (!_scroll.hasClients) return;
    double place() {
      final p = _scroll.position;
      return target().clamp(p.minScrollExtent, p.maxScrollExtent).toDouble();
    }

    const stretch = 160.0;
    final from = _scroll.position.pixels;
    final to = place();
    final start = (from - to).abs() <= stretch ? from : to + (from > to ? stretch : -stretch);
    _jumpTo(start);
    const duration = 250;
    _slider = createTicker((elapsed) {
      if (!mounted || jump != _jump || !_scroll.hasClients) return _slider?.stop();
      final t = min(1.0, elapsed.inMilliseconds / duration);
      _jumpTo(start + (place() - start) * Curves.easeOutQuart.transform(t));
      if (t == 1) _slider?.stop();
    })..start();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final chat = ref.watch(chatsProvider.select((s) => s.open));
    // An opened chat whose messages are still on their way from the database (a moment): an empty page.
    final loading = ref.watch(chatsProvider.select((s) => s.openId != null && s.open == null));
    final messages = chat?.messages ?? const <ChatMessage>[];
    final replying = ref.watch(chatsProvider.select((s) => s.replyingId != null && s.replyingId == s.openId));
    final motion = ref.watch(motionProvider);
    final found = ref.watch(findProvider);
    final find = found != null && found.chatId == chat?.id ? found : null;
    final matches = find == null ? const <int>[] : matchingMessages(chat!, find.query);

    if (chat?.id != _keysChat) {
      _keys.clear();
      _open.clear();
      _arrows.clear();
      _keysChat = chat?.id;
      _follow.reset();
      _slider?.stop();
      // A chat opened (not from the search results, which jump to the match): at its end.
      if (chat != null && find == null && messages.isNotEmpty) {
        _opening = true;
        final id = chat.id;
        WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd(id));
      } else {
        _opening = false;
      }
    }

    // Jump to the match each time one is chosen (a result clicked, even the same one again, or the bar's arrows).
    ref.listen(findProvider, (before, now) {
      // Stepping to the next or previous match in the same chat skids in; a chat just opened jumps.
      final step = before != null && now != null && before.chatId == now.chatId;
      if (now != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => step ? _skid(now.messageIndex, now.query) : _reveal(now.messageIndex, now.query),
        );
      }
    });
    // A message sent: followed if the user is at the bottom (asked before the page grows with it).
    ref.listen(chatsProvider.select((s) => s.replyingId), (_, id) {
      if (id != null && id == ref.read(chatsProvider).openId) _follow.sent();
    });
    // While a reply is written, the page follows its end if the user is at the bottom; otherwise it stays put.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _follow.replying = replying;
      _follow.changed();
      _updateCover();
      _updateBookmark();
    });

    final mark = TextStyle(fontWeight: FontWeight.w600, backgroundColor: c.text.withValues(alpha: 0.12));
    final markHere = TextStyle(fontWeight: FontWeight.w600, backgroundColor: c.text.withValues(alpha: 0.28));

    Widget message(int index) {
      final message = messages[index];
      final last = index == messages.length - 1;
      final live = last && replying;
      return Center(
        key: _keys.putIfAbsent(index, GlobalKey.new),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: ChatPage.contentWidth),
            child: _MessageWithActions(
              message: message,
              index: index,
              // (The reply being written gets its buttons once it is done.)
              actions: !live,
              // A reply's bookmark button bookmarks the message it answers (the one jumped to).
              bookmarked: _answers(messages, index)?.bookmark,
              onBookmark: () => ref.read(chatsProvider.notifier).toggleBookmark(index - 1),
              child: _Message(
                message,
                marks: find != null && matches.contains(index) ? highlightsIn(message, find.query) : const [],
                markStyle: find?.messageIndex == index ? markHere : mark,
                lastReply: last && message.role == Role.assistant,
                live: live,
                motion: motion,
                open: _open.contains(index),
                onToggle: () => _toggle(index),
                arrowKey: _arrows.putIfAbsent(index, GlobalKey.new),
                flash: _flashing == index,
              ),
            ),
          ),
        ),
      );
    }

    // A wheel, touchpad or click on the conversation stops a slide: the user takes over.
    void handsOn() => _slider?.stop();
    return Column(
      children: [
        Expanded(
          child: Listener(
            onPointerDown: (_) => handsOn(),
            onPointerSignal: (_) => handsOn(),
            onPointerPanZoomStart: (_) => handsOn(),
            child: loading
                ? const SizedBox.shrink()
                : messages.isEmpty
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      // Dark 3: the logo, large and barely there, behind it.
                      if (c.slashes)
                        IgnorePointer(
                          child: Opacity(
                            opacity: c.isLight ? 0.05 : 0.035,
                            child: Image.asset(
                              c.isLight ? 'assets/logo/mark-light.png' : 'assets/logo/mark-dark.png',
                              width: 420,
                            ),
                          ),
                        ),
                      Text(
                        'Start a new chat',
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w500, color: c.text),
                      ),
                    ],
                  )
                : Stack(
                    children: [
                      NotificationListener<Notification>(
                        onNotification: (n) {
                          final m = switch (n) {
                            ScrollUpdateNotification(:final metrics, depth: 0) => metrics,
                            ScrollMetricsNotification(:final metrics, depth: 0) => metrics,
                            _ => null,
                          };
                          if (m != null) {
                            _scrolled.value = m.pixels > m.minScrollExtent + 1;
                            if (n is ScrollUpdateNotification && (n.scrollDelta ?? 0) != 0) {
                              _moving.value = true;
                              _still?.cancel();
                              _still = Timer(const Duration(milliseconds: 150), () {
                                if (!mounted) return;
                                _updateCover();
                                _moving.value = false;
                              });
                            }
                            _updateCover();
                            _updateBookmark();
                          }
                          return _follow.handle(n);
                        },
                        child: Opacity(
                          opacity: _opening ? 0 : 1,
                          child: _follow.scrollbar(
                            context,
                            // Keyed by chat, so every chat starts afresh.
                            ListView.builder(
                              key: ValueKey(chat!.id),
                              controller: _scroll,
                              physics: _follow.physics,
                              // Below: room for the new line of a reply being written, where it shows until
                              // the page has moved up by it.
                              padding: const EdgeInsets.only(top: _room, bottom: _bottomRoom),
                              itemCount: messages.length,
                              itemBuilder: (context, i) => message(i),
                            ),
                          ),
                        ),
                      ),
                      // At the top row: moving, a soft edge; still, a line left cut there is hidden whole.
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        child: IgnorePointer(
                          child: ListenableBuilder(
                            listenable: Listenable.merge([_cover, _moving]),
                            builder: (context, _) =>
                                _TopCover(cover: _cover.value, moving: _moving.value, color: c.page),
                          ),
                        ),
                      ),
                      // Scrolled: a very light, short shadow just under the top row.
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        height: 4,
                        child: IgnorePointer(
                          child: ValueListenableBuilder<bool>(
                            valueListenable: _scrolled,
                            builder: (context, scrolled, _) => AnimatedOpacity(
                              key: const Key('top-shadow'),
                              opacity: scrolled ? 1 : 0,
                              duration: const Duration(milliseconds: 150),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      c.shadow.withValues(alpha: c.shadow.a * 0.1),
                                      c.shadow.withValues(alpha: 0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // "↓": there is text below that the page is not following.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 8,
                        child: Center(
                          child: ValueListenableBuilder<bool>(
                            valueListenable: _follow.below,
                            builder: (context, below, _) => IgnorePointer(
                              ignoring: !below,
                              child: AnimatedOpacity(
                                opacity: below ? 1 : 0,
                                duration: const Duration(milliseconds: 150),
                                child: _RoundButton(
                                  key: const Key('jump-newest'),
                                  tooltip: 'Jump to newest',
                                  icon: Icons.arrow_downward,
                                  fill: c.inputFill,
                                  iconColor: c.text,
                                  border: c.inputBorder,
                                  onTap: _toNewest,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // The bookmarks: dashes at the right edge, a card with their names on hover.
                      if (messages.any((m) => m.bookmark))
                        Positioned(
                          // (Clear of the scroll bar.)
                          right: 16,
                          top: 12,
                          bottom: 12,
                          child: Center(
                            child: ValueListenableBuilder<int?>(
                              valueListenable: _bookmarkHere,
                              builder: (context, here, _) => _BookmarkRail(
                                bookmarks: [
                                  for (var i = 0; i < messages.length; i++)
                                    if (messages[i].bookmark) (index: i, title: messages[i].text),
                                ],
                                here: here,
                                onJump: _toBookmark,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: ChatPage.contentWidth),
              child: const _MessageBox(),
            ),
          ),
        ),
      ],
    );
  }

  /// Opens a long sent message, or folds it. Folding a message whose top is above the view keeps its arrow where it
  /// was clicked (the page moves with the folding), so the reader stays at the same place.
  void _toggle(int index) {
    if (!_open.contains(index)) return setState(() => _open.add(index));
    double? arrowY() {
      final box = _arrows[index]?.currentContext?.findRenderObject();
      return box is RenderBox && box.attached ? box.localToGlobal(Offset.zero).dy : null;
    }

    final view = _view();
    final top = _box(index)?.localToGlobal(Offset.zero).dy;
    final at = arrowY();
    setState(() => _open.remove(index));
    if (view == null || top == null || at == null || top >= view.localToGlobal(Offset.zero).dy) return;
    _holder?.dispose();
    _holder = createTicker((elapsed) {
      final now = arrowY();
      if (!mounted || now == null || !_scroll.hasClients || elapsed > const Duration(milliseconds: 400)) {
        return _holder?.stop();
      }
      final p = _scroll.position;
      if ((now - at).abs() > 0.1) _jumpTo((p.pixels + now - at).clamp(p.minScrollExtent, p.maxScrollExtent));
    })..start();
  }

  /// Scrolls until message [index] is built, then puts the line with its match about a third of the way down.
  Future<void> _reveal(int index, SearchQuery query) async {
    final jump = ++_jump;
    _slider?.stop();
    _follow.stop();
    // A chat just opened from the results: wait (up to about 2 s) for its messages to arrive and show.
    for (var frames = 0; frames < 120 && _keys.isEmpty; frames++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || jump != _jump) return;
    }
    if (_opening) setState(() => _opening = false);
    for (var tries = 0; tries < 40; tries++) {
      if (!mounted || jump != _jump || !_scroll.hasClients) return;
      if (await _openFor(index, query)) continue;
      if (_exactOffset(index, query) case final to?) {
        _jumpTo(to);
        _follow.changed();
        return;
      }
      // Not built yet: jump to where it probably is, and look again.
      final to = _guessOffset(index);
      if (to == null || to == _scroll.position.pixels) return;
      _jumpTo(to);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  /// Skids to the line with match [index] (the bar's arrows), see [_slide]; a match nearby slides in from where
  /// the list is.
  Future<void> _skid(int index, SearchQuery query) async {
    final jump = ++_jump;
    _slider?.stop();
    _follow.stop();
    if (!_scroll.hasClients) return;
    final from = _scroll.position.pixels;
    // Its exact place, once the message is built: until then, jump to where it probably is and look again.
    var exact = _exactOffset(index, query);
    for (var tries = 0; exact == null && tries < 40; tries++) {
      final guess = _guessOffset(index);
      if (guess == null || guess == _scroll.position.pixels) return;
      _jumpTo(guess);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || jump != _jump || !_scroll.hasClients) return;
      exact = _exactOffset(index, query);
    }
    if (exact == null) return;
    if (await _openFor(index, query)) {
      if (!mounted || jump != _jump || !_scroll.hasClients) return;
      exact = _exactOffset(index, query) ?? exact;
    }
    // The slide starts from where the list was, not from the guesses on the way.
    _jumpTo(from);
    final last = exact;
    _slide(jump, () => _exactOffset(index, query) ?? last);
  }

  /// A match in the folded part of a long sent message: opens it, and waits until it has grown, so the match's
  /// place can be found. False when there was nothing to open (or the message is not built yet).
  Future<bool> _openFor(int index, SearchQuery query) async {
    final chat = ref.read(chatsProvider).open;
    final item = _box(index);
    if (item == null || chat == null || index >= chat.messages.length || _open.contains(index)) return false;
    if (chat.messages[index].role != Role.user) return false;
    final match = bestMatch(chat.messages[index], query);
    RenderEditable? text;
    void visit(RenderObject o) {
      if (text != null) return;
      if (o is RenderEditable) {
        text = o;
      } else {
        o.visitChildren(visit);
      }
    }

    visit(item);
    if (text == null || match == null) return false;
    final bottom = text!.getLocalRectForCaret(TextPosition(offset: match.end)).bottom;
    if (bottom <= text!.preferredLineHeight * FoldedText.lines + 0.5) return false;
    setState(() => _open.add(index));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return true;
  }

  /// Where the list must be scrolled to put message [index]'s match a third of the way down; null while that
  /// message is not built.
  double? _exactOffset(int index, SearchQuery query) {
    final item = _box(index);
    final chat = ref.read(chatsProvider).open;
    if (item == null || chat == null || index >= chat.messages.length) return null;
    final match = bestMatch(chat.messages[index], query);
    // The message's text, to find where the matching line is inside a long message.
    RenderEditable? text;
    void visit(RenderObject o) {
      if (text != null) return;
      if (o is RenderEditable) {
        text = o;
      } else {
        o.visitChildren(visit);
      }
    }

    visit(item);
    final view = _view();
    if (view == null) return null;
    // Where the matching line is on screen now, and how far the page must move to put it a third of the way down.
    final line = text != null && match != null
        ? text!.localToGlobal(text!.getLocalRectForCaret(TextPosition(offset: match.start)).topLeft).dy
        : item.localToGlobal(Offset.zero).dy;
    final want = view.localToGlobal(Offset.zero).dy + view.size.height * 0.35;
    final position = _scroll.position;
    return (position.pixels + line - want).clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
  }

  /// Where message [index] probably is, from the heights of the messages that are built; null when none is.
  double? _guessOffset(int index) {
    final built = [
      for (final e in _keys.entries)
        if (e.value.currentContext?.findRenderObject() case final RenderBox box when box.attached)
          (e.key, box.size.height),
    ];
    if (built.isEmpty) return null;
    final lowest = built.map((b) => b.$1).reduce(min);
    final highest = built.map((b) => b.$1).reduce(max);
    final average = built.map((b) => b.$2).reduce((a, b) => a + b) / built.length;
    final position = _scroll.position;
    // A smaller offset shows older messages.
    final distance = index < lowest ? -(lowest - index) * average : (index > highest ? (index - highest) * average : 0);
    return (position.pixels + distance).clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
  }
}

/// The edge under the window's top row. While the page moves, the text goes under it naturally, softened by a
/// short fade so letters are not sharply cut. A moment after it stops, a line left partly under it (and a bubble
/// whose text is all under it) fades out over a tenth of a second ([cover] tall), so at rest only whole lines show.
class _TopCover extends StatelessWidget {
  const _TopCover({required this.cover, required this.moving, required this.color});

  final double cover;
  final bool moving;
  final Color color;

  static const _fade = Duration(milliseconds: 100);

  Widget _gradient(double height) => Container(
    height: height,
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color, color.withValues(alpha: 0)],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Stack(
      key: const Key('top-cover'),
      children: [
        const SizedBox(width: double.infinity),
        AnimatedOpacity(opacity: moving ? 1 : 0, duration: _fade, child: _gradient(10)),
        if (cover > 0)
          AnimatedOpacity(
            opacity: moving ? 0 : 1,
            duration: _fade,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(height: cover, color: color),
                _gradient(3),
              ],
            ),
          ),
      ],
    );
  }
}

/// "2 of 4" with buttons to step through the matches and one to take the highlights off; it sits in the window's
/// top row while the open chat came from the search results.
class FindBar extends ConsumerWidget {
  const FindBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final state = ref.watch(findProvider);
    final chat = ref.watch(chatsProvider.select((s) => s.open));
    if (state == null || chat == null || state.chatId != chat.id) return const SizedBox.shrink();
    final matches = matchingMessages(chat, state.query);
    if (matches.isEmpty) return const SizedBox.shrink();
    final at = matches.indexOf(state.messageIndex) + 1;
    final of = matches.length;
    final find = ref.read(findProvider.notifier);
    Widget button(String key, IconData icon, String tooltip, VoidCallback onTap) => Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        key: Key(key),
        borderRadius: BorderRadius.circular(6),
        hoverColor: c.selected,
        onTap: onTap,
        child: SizedBox(width: 28, height: 28, child: Icon(icon, size: 18, color: c.textSecondary)),
      ),
    );

    return Material(
      color: c.inputFill,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.inputBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 2, 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$at of $of',
              key: const Key('find-count'),
              style: TextStyle(fontSize: 13, color: c.textSecondary),
            ),
            const SizedBox(width: 8),
            button('find-previous', Icons.keyboard_arrow_up, 'Previous match', () => find.move(-1)),
            button('find-next', Icons.keyboard_arrow_down, 'Next match', () => find.move(1)),
            button('find-close', Icons.close, 'Hide matches', find.close),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(
    this.message, {
    this.marks = const [],
    this.markStyle,
    this.lastReply = false,
    this.live = false,
    this.motion = smoothMotion,
    this.open = false,
    this.onToggle,
    this.arrowKey,
    this.flash = false,
  });

  final ChatMessage message;

  /// A bookmark just jumped to: its bubble lights up.
  final bool flash;

  /// A long sent message: opened to its full length, the arrow's action and key (lib/ui/folded_text.dart).
  final bool open;
  final VoidCallback? onToggle;
  final Key? arrowKey;

  /// The chat's last message is the AI's reply: it is shown with [LiveReply] (which shows it as usual once done).
  final bool lastReply;

  /// That reply is still being written.
  final bool live;

  /// How it moves while written.
  final Motion motion;

  /// Search matches to highlight.
  final List<Span> marks;
  final TextStyle? markStyle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style = TextStyle(fontSize: 15, height: 1.6, color: c.text);
    final text = marks.isEmpty
        ? SelectableText(message.text, style: style)
        : SelectableText.rich(TextSpan(style: style, children: markedSpans(message.text, marks, markStyle!)));
    if (message.role == Role.assistant) {
      return Align(
        alignment: Alignment.centerLeft,
        child: lastReply ? LiveReply(text: message.text, live: live, style: style, done: text, motion: motion) : text,
      );
    }
    final bubble = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: ChatPage.contentWidth * 0.75),
      // A bookmark just jumped to lights up for a moment.
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: flash ? Color.alphaBlend(c.text.withValues(alpha: 0.10), c.selected) : c.selected),
        duration: const Duration(milliseconds: 250),
        builder: (context, fill, child) => LookBox(
          fill: fill!,
          radius: 16,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: child!,
        ),
        child: FoldedText(
          text: text,
          plain: message.text,
          style: style,
          open: open,
          onToggle: onToggle ?? () {},
          arrowKey: arrowKey,
        ),
      ),
    );
    return Align(
      alignment: Alignment.centerRight,
      // Bookmarked: a small bookmark just right of it, in the margin, so the message stays where it is.
      child: !message.bookmark
          ? bubble
          : Stack(
              clipBehavior: Clip.none,
              children: [
                bubble,
                Positioned(
                  key: const Key('bookmark-mark'),
                  right: -20,
                  top: 12,
                  child: Icon(Icons.bookmark_rounded, size: 14, color: c.textMuted),
                ),
              ],
            ),
    );
  }
}

/// The sent message that the reply at [index] answers (the one before it); null when [index] is not such a reply.
ChatMessage? _answers(List<ChatMessage> messages, int index) =>
    messages[index].role == Role.assistant && index > 0 && messages[index - 1].role == Role.user
    ? messages[index - 1]
    : null;

/// Moves to the next bookmark of the open chat ([step] 1) or back (-1), when a chat page is on screen.
void stepBookmark(int step) => _ChatPageState._shown?._stepBookmark(step);

/// A message with the room under it (the gap before the next one) where its buttons show while the pointer is on
/// it: Copy (the icon turns into a tick for a moment), and for a reply Bookmark (bookmarks the message it answers,
/// or takes the bookmark off).
class _MessageWithActions extends StatefulWidget {
  const _MessageWithActions({
    required this.message,
    required this.index,
    required this.actions,
    required this.bookmarked,
    required this.onBookmark,
    required this.child,
  });

  final ChatMessage message;
  final int index;
  final bool actions;

  /// A reply: whether the message it answers is bookmarked (null: no bookmark button, as for a sent message).
  final bool? bookmarked;
  final VoidCallback onBookmark;
  final Widget child;

  /// The room under each message.
  static const room = 20.0;

  @override
  State<_MessageWithActions> createState() => _MessageWithActionsState();
}

class _MessageWithActionsState extends State<_MessageWithActions> {
  bool _hovered = false;
  bool _copied = false;
  Timer? _copiedOff;

  @override
  void dispose() {
    _copiedOff?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.message.text));
    setState(() => _copied = true);
    _copiedOff?.cancel();
    _copiedOff = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Widget _button(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final c = context.colors;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(5),
        hoverColor: c.selected,
        onTap: onTap,
        child: SizedBox(
          width: 26,
          height: _MessageWithActions.room,
          child: Icon(icon, size: 15, color: c.textMuted),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mine = widget.message.role == Role.user;
    final shown = widget.actions && (_hovered || _copied);
    final i = widget.index;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          widget.child,
          SizedBox(
            height: _MessageWithActions.room,
            child: shown
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _button(
                        context,
                        key: Key('copy-$i'),
                        icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
                        tooltip: _copied ? 'Copied' : 'Copy',
                        onTap: _copy,
                      ),
                      if (widget.bookmarked case final on?)
                        _button(
                          context,
                          key: Key('bookmark-$i'),
                          icon: on ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                          tooltip: on ? 'Remove bookmark' : 'Bookmark',
                          onTap: widget.onBookmark,
                        ),
                    ],
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

/// The open chat's bookmarks at the right edge: a dash for each (the one being read darker and longer). With the
/// pointer on them, a card opens beside them with each bookmark's name (its message's first line); a click slides
/// to it.
class _BookmarkRail extends StatefulWidget {
  const _BookmarkRail({required this.bookmarks, required this.here, required this.onJump});

  final List<({int index, String title})> bookmarks;
  final int? here;
  final void Function(int index) onJump;

  @override
  State<_BookmarkRail> createState() => _BookmarkRailState();
}

class _BookmarkRailState extends State<_BookmarkRail> {
  bool _open = false;
  Timer? _close;

  @override
  void dispose() {
    _close?.cancel();
    super.dispose();
  }

  void _show(bool open) {
    _close?.cancel();
    if (open) {
      setState(() => _open = true);
    } else {
      // A moment's grace, so the pointer can cross between the dashes and the card.
      _close = Timer(const Duration(milliseconds: 150), () {
        if (mounted) setState(() => _open = false);
      });
    }
  }

  static String _name(String text) {
    final line = text.trim().split('\n').first.trim();
    return line.isEmpty ? '…' : line;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = widget.bookmarks.length;
    return LayoutBuilder(
      builder: (context, box) {
        // Each dash's room: less when there are many, so they all fit.
        final slot = (box.maxHeight * 0.6 / n).clamp(4.0, 12.0);
        final dashes = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Column(
            key: const Key('bookmark-rail'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final ch in widget.bookmarks)
                SizedBox(
                  height: slot,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: ch.index == widget.here ? 16 : 10,
                      height: 2.5,
                      decoration: BoxDecoration(
                        color: ch.index == widget.here ? c.text : c.textMuted.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
        final card = Material(
          key: const Key('bookmark-card'),
          color: c.inputFill,
          elevation: 2,
          shadowColor: c.shadow,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: c.inputBorder),
            borderRadius: BorderRadius.circular(10),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 280, maxHeight: box.maxHeight),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: IntrinsicWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final ch in widget.bookmarks)
                      InkWell(
                        key: Key('bookmark-row-${ch.index}'),
                        hoverColor: c.selected,
                        onTap: () {
                          setState(() => _open = false);
                          widget.onJump(ch.index);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                          child: Text(
                            _name(ch.title),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              color: ch.index == widget.here ? c.text : c.textSecondary,
                              fontWeight: ch.index == widget.here ? FontWeight.w600 : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        return MouseRegion(
          onEnter: (_) => _show(true),
          onExit: (_) => _show(false),
          child: Row(mainAxisSize: MainAxisSize.min, children: [if (_open) card, dashes]),
        );
      },
    );
  }
}

class _MessageBox extends ConsumerStatefulWidget {
  const _MessageBox();

  @override
  ConsumerState<_MessageBox> createState() => _MessageBoxState();
}

/// Puts the cursor in the message box (if it is on screen).
void focusMessageBox() => _MessageBoxState._shown?._focus.requestFocus();

/// Types [text] into the message box where its cursor is (replacing any chosen text) and puts the cursor there;
/// false when the box is not on screen.
bool typeIntoMessageBox(String text) {
  final box = _MessageBoxState._shown;
  if (box == null || !box.mounted) return false;
  final value = box._text.value;
  final at = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);
  box._text.value = TextEditingValue(
    text: value.text.replaceRange(at.start, at.end, text),
    selection: TextSelection.collapsed(offset: at.start + text.length),
  );
  box._focus.requestFocus();
  return true;
}

class _MessageBoxState extends ConsumerState<_MessageBox> {
  final _text = TextEditingController();
  final _focus = FocusNode(debugLabel: 'message box');

  /// The message box on screen (one at most).
  static _MessageBoxState? _shown;

  /// Whose draft the box holds (see [draftKey]), and where the cursor was in each draft (while the app runs).
  late String _draft;
  static final _cursors = <String, TextSelection>{};

  @override
  void initState() {
    super.initState();
    _shown = this;
    final chats = ref.read(chatsProvider);
    _load(draftKey(chats.openId, chats.kind));
    _text.addListener(_typed);
  }

  @override
  void dispose() {
    if (_shown == this) _shown = null;
    _text.removeListener(_typed);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Every change of the text (or the cursor) is kept as the draft.
  void _typed() {
    ref.read(draftsProvider.notifier).set(_draft, _text.text);
    _cursors[_draft] = _text.selection;
  }

  /// Puts draft [key] in the box, the cursor where it was left (else at the end).
  void _load(String key) {
    _draft = key;
    final text = ref.read(draftsProvider)[key] ?? '';
    final cursor = _cursors[key];
    _text.value = TextEditingValue(
      text: text,
      selection: cursor != null && cursor.end <= text.length ? cursor : TextSelection.collapsed(offset: text.length),
    );
  }

  void _send() {
    final model = ref.read(pickedModelProvider);
    final chats = ref.read(chatsProvider);
    final text = _text.text;
    if (model == null || chats.replyingId != null || text.trim().isEmpty) return;
    // (An opened chat whose messages are still on their way cannot take a message yet: the text stays.)
    if (chats.openId != null && chats.open == null) return;
    // Emptied first, so the draft it came from (a new chat's, which becomes this chat) is gone too.
    _text.clear();
    ref.read(chatsProvider.notifier).send(text, model.file);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Opening another chat (or a new one) puts the cursor back in the box, with that chat's draft.
    ref.listen(chatsProvider.select((s) => s.openId), (_, _) => _focus.requestFocus());
    ref.listen(chatsProvider.select((s) => draftKey(s.openId, s.kind)), (_, key) => _load(key));
    final model = ref.watch(pickedModelProvider);
    final chats = ref.watch(chatsProvider);
    final replyingHere = chats.replyingId != null && chats.replyingId == chats.openId;
    final replyingElsewhere = chats.replyingId != null && !replyingHere;

    final String? hint = model == null
        ? 'Download a model from the Store to start chatting.'
        : replyingElsewhere
        ? 'Wait for the reply in "${chats.byId(chats.replyingId)?.title}" to finish.'
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              hint,
              key: const Key('box-hint'),
              style: TextStyle(fontSize: 13, color: c.textMuted),
            ),
          ),
        LookBox(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
          fill: c.inputFill,
          edge: c.inputBorder,
          radius: 16,
          // It floats a little above the page.
          shadows: [
            BoxShadow(
              color: c.shadow.withValues(alpha: c.shadow.a * 0.6),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
            BoxShadow(
              color: c.shadow.withValues(alpha: c.shadow.a * 0.35),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ],
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                // Enter sends; Shift+Enter starts a new line.
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.enter): _send,
                    // Ctrl+Enter does nothing here (kept for later; it would start a new line otherwise).
                    const SingleActivator(LogicalKeyboardKey.enter, control: true): () {},
                  },
                  child: TextField(
                    controller: _text,
                    focusNode: _focus,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 8,
                    style: TextStyle(fontSize: 15, color: c.text),
                    cursorColor: c.text,
                    decoration: InputDecoration(
                      hintText: 'Type a message',
                      hintStyle: TextStyle(color: c.textMuted),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              replyingHere
                  ? _RoundButton(
                      key: const Key('stop'),
                      tooltip: 'Stop',
                      icon: Icons.stop_rounded,
                      fill: Colors.transparent,
                      iconColor: c.text,
                      border: c.inputBorder,
                      onTap: () => ref.read(chatsProvider.notifier).stop(),
                    )
                  : _RoundButton(
                      key: const Key('send'),
                      tooltip: 'Send',
                      icon: Icons.arrow_upward,
                      fill: hint == null ? c.text : c.switchTrack,
                      iconColor: hint == null ? c.page : c.textMuted,
                      onTap: _send,
                    ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.fill,
    required this.iconColor,
    required this.onTap,
    this.border,
  });

  final String tooltip;
  final IconData icon;
  final Color fill;
  final Color iconColor;
  final Color? border;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: fill,
        shape: CircleBorder(side: border == null ? BorderSide.none : BorderSide(color: border!)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 34, height: 34, child: Icon(icon, size: 18, color: iconColor)),
        ),
      ),
    );
  }
}
