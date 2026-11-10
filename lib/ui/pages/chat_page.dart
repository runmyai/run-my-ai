import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/reply_stats.dart';
import '../../search/chat_search.dart';
import '../../state/benchmark.dart';
import '../../state/chats.dart';
import '../../state/drafts.dart';
import '../../state/library.dart';
import '../../state/motion.dart';
import '../../state/prefs.dart';
import '../../state/queue.dart';
import '../../state/search.dart';
import '../../state/section.dart';
import '../../theme.dart';
import '../buttons.dart';
import '../folded_text.dart';
import '../follow.dart';
import '../live_reply.dart';
import '../look.dart';
import '../marked_text.dart';
import '../menu_panel.dart';
import '../reply_card.dart';
import '../thinking_block.dart';
import '../thinking_toggle.dart';

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
    // Where the reply being written sits in this chat (empty when none is written here).
    final replyingPath = ref.watch(chatsProvider
        .select((s) => s.replyingId != null && s.replyingId == s.openId ? s.replyingPath : const <ReplyPlace>[]));
    // The reply is on screen when the chat shows its version; the user may have flipped to another meanwhile.
    final writingShown = replyingPath.isNotEmpty && messages.lastOrNull?.node == replyingPath.last.node;
    final loadingModel = ref.watch(chatsProvider.select((s) => s.loadingModel));
    final model = ref.watch(shownModelProvider);
    // Why Edit and Regenerate cannot be pressed now, in the words of the Send button's tooltip.
    final benchmarking = ref.watch(benchmarkProvider.select((s) => s.running));
    final blocked = ref.watch(chatsProvider.select((s) => _sendBlock(s, benchmarking))) ??
        (model == null ? 'Download a model from the Store to start chatting.' : null);
    final editedNode = ref.watch(chatsProvider.select((s) => s.editing?.chatId == s.openId ? s.editing?.node : null));
    final latestReply = messages.lastIndexWhere((m) => m.role == Role.assistant);
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
      _follow.replying = writingShown;
      _follow.changed();
      _updateCover();
      _updateBookmark();
    });

    final mark = TextStyle(fontWeight: FontWeight.w600, backgroundColor: c.text.withValues(alpha: 0.12));
    final markHere = TextStyle(fontWeight: FontWeight.w600, backgroundColor: c.text.withValues(alpha: 0.28));

    Widget message(int index) {
      final message = messages[index];
      final last = index == messages.length - 1;
      final live = last && writingShown;
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
              // The latest reply keeps its buttons on show; the others show them under the pointer.
              always: index == latestReply,
              // A reply's bookmark button bookmarks the message it answers (the one jumped to).
              bookmarked: _answers(messages, index)?.bookmark,
              onBookmark: () => ref.read(chatsProvider.notifier).toggleBookmark(index - 1),
              blocked: blocked,
              // The arrows work while a reply is written too; the version being written is marked on them.
              writing: writingLabel(messages, replyingPath, index),
              onFlip: (step) => ref.read(chatsProvider.notifier).flip(index, step),
              onEdit: message.role == Role.user && message.node != null
                  ? () => ref.read(chatsProvider.notifier).beginEdit(index, model?.file)
                  : null,
              onRegenerate: _answers(messages, index) != null
                  ? () => ref.read(chatsProvider.notifier).regenerate(index, model!.file)
                  : null,
              child: _Message(
                message,
                chatId: chat!.id,
                index: index,
                marks: find != null && matches.contains(index) ? highlightsIn(message, find.query) : const [],
                markStyle: find?.messageIndex == index ? markHere : mark,
                lastReply: last && message.role == Role.assistant,
                live: live,
                loading: live ? loadingModel : null,
                motion: motion,
                open: _open.contains(index),
                onToggle: () => _toggle(index),
                arrowKey: _arrows.putIfAbsent(index, GlobalKey.new),
                flash: _flashing == index,
                editing: message.node != null && message.node == editedNode,
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
                                child: AppIconButton(
                                  key: const Key('jump-newest'),
                                  tooltip: 'Jump to newest',
                                  icon: Icons.arrow_downward,
                                  look: IconButtonLook.outlined,
                                  round: true,
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
    Widget button(String key, IconData icon, String tooltip, VoidCallback onTap) => AppIconButton(
      key: Key(key),
      icon: icon,
      tooltip: tooltip,
      onTap: onTap,
      size: 28,
      radius: 6,
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
    required this.chatId,
    required this.index,
    this.marks = const [],
    this.markStyle,
    this.lastReply = false,
    this.live = false,
    this.loading,
    this.motion = smoothMotion,
    this.open = false,
    this.onToggle,
    this.arrowKey,
    this.flash = false,
    this.editing = false,
  });

  final ChatMessage message;

  /// The chat the message is in and its place there (what its thinking block is remembered by).
  final String chatId;
  final int index;

  /// A bookmark just jumped to: its bubble lights up.
  final bool flash;

  /// A sent message being edited in the message box: its bubble is outlined.
  final bool editing;

  /// A long sent message: opened to its full length, the arrow's action and key (lib/ui/folded_text.dart).
  final bool open;
  final VoidCallback? onToggle;
  final Key? arrowKey;

  /// The chat's last message is the AI's reply: it is shown with [LiveReply] (which shows it as usual once done).
  final bool lastReply;

  /// That reply is still being written.
  final bool live;

  /// The model being loaded for it, if one is.
  final String? loading;

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading != null)
              Text('Loading $loading…', key: const Key('model-loading'), style: TextStyle(fontSize: 13, color: c.textMuted)),
            if (message.thinking.isNotEmpty)
              ThinkingBlock(
                chatId: chatId,
                // (By the message's number, so each version of a reply has its own block.)
                index: message.node ?? index,
                text: message.thinking,
                thinking: live && message.text.isEmpty,
                millis: message.thinkingMillis,
              ),
            // A reply that was stopped while it thought has no answer to show.
            if (message.stopped && message.text.isEmpty && !live)
              Text('Stopped', key: const Key('reply-stopped'), style: TextStyle(fontSize: 13, color: c.textMuted))
            else if (lastReply)
              // (By the message's number: another version of the reply is another view, not a continuation.)
              LiveReply(
                  key: ValueKey(message.node),
                  text: message.text,
                  live: live,
                  style: style,
                  done: text,
                  motion: motion)
            else
              text,
            if (lastReply) _ReplySpeedLine(node: message.node),
          ],
        ),
      );
    }
    final bubble = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: ChatPage.contentWidth * 0.75),
      // A bookmark just jumped to lights up for a moment.
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(
            end: flash || editing ? Color.alphaBlend(c.text.withValues(alpha: 0.10), c.selected) : c.selected),
        duration: const Duration(milliseconds: 250),
        builder: (context, fill, child) => LookBox(
          key: editing ? const Key('editing-bubble') : null,
          fill: fill!,
          edge: editing ? c.text.withValues(alpha: 0.55) : null,
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

/// Under the chat's last reply: its speed right now while it is written, then its average.
class _ReplySpeedLine extends ConsumerWidget {
  const _ReplySpeedLine({this.node});

  /// The reply it is under: the speed shows only there, not under another version of the reply.
  final int? node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speed = ref.watch(chatsProvider.select((s) {
      final shown = s.speed;
      return shown != null && shown.chatId == s.openId && (shown.node == null || shown.node == node) ? shown : null;
    }));
    if (speed == null) return const SizedBox.shrink();
    final highlighted = ref.watch(prefsProvider.select((p) => p.speedHighlighted));
    final c = context.colors;
    final color = !highlighted
        ? c.text
        : Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF5AA9FF)
        : const Color(0xFF1F6FEB);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      // The number counts quickly to each new value instead of jumping.
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: speed.tokensPerSecond),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        builder: (context, value, _) => Text(
          speed.done ? 'Avg ${value.toStringAsFixed(1)} tokens/s' : '${value.round()} tokens/s',
          key: const Key('reply-speed'),
          style: TextStyle(
            fontSize: 13,
            fontWeight: highlighted ? FontWeight.w700 : FontWeight.w400,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
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

/// Why nothing can be sent now: a benchmark is running, or a reply is being written (in any chat); null when
/// something can. The words of the Send button's tooltip ([hereToo] false: not for the reply of the open chat, whose
/// Send button is the Stop button).
String? _sendBlock(ChatsState chats, bool benchmarking, {bool hereToo = true}) {
  if (benchmarking) return 'A benchmark is running.';
  final id = chats.replyingId;
  if (id == null || (!hereToo && id == chats.openId)) return null;
  return '"${chats.byId(id)?.title}" is generating a response. Stop it to send.';
}

/// A message with the room under it (the gap before the next one) where its buttons show: Copy (the icon turns into
/// a tick for a moment), Edit on a sent message, Regenerate on a reply, and for a reply Bookmark (bookmarks the
/// message it answers, or takes the bookmark off). They show while the pointer is on the message, and always under
/// the latest reply ([always]). A message with more than one version also shows `‹ 1/2 ›`, always, which flips
/// between the versions.
class _MessageWithActions extends StatefulWidget {
  const _MessageWithActions({
    required this.message,
    required this.index,
    required this.actions,
    required this.bookmarked,
    required this.onBookmark,
    required this.child,
    this.always = false,
    this.blocked,
    this.writing,
    this.onFlip,
    this.onEdit,
    this.onRegenerate,
  });

  final ChatMessage message;
  final int index;
  final bool actions;
  final bool always;

  /// A reply: whether the message it answers is bookmarked (null: no bookmark button, as for a sent message).
  final bool? bookmarked;
  final VoidCallback onBookmark;

  /// Why Edit and Regenerate cannot be pressed now (shown as their tooltip); null when they can.
  final String? blocked;

  /// What the arrows say about the reply being written (see [writingLabel]); null: nothing.
  final String? writing;

  /// Shows the version [step] places on (-1: the one before).
  final void Function(int step)? onFlip;

  /// Edit, for a sent message; Regenerate, for a reply that answers one; null: no such button.
  final VoidCallback? onEdit;
  final VoidCallback? onRegenerate;
  final Widget child;

  /// The room under each message.
  static const room = 20.0;

  @override
  State<_MessageWithActions> createState() => _MessageWithActionsState();
}

class _MessageWithActionsState extends State<_MessageWithActions> {
  bool _hovered = false;
  bool _copied = false;

  /// The reply's card is open: the buttons stay, or the card would go with them.
  bool _cardOpen = false;
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
    required VoidCallback? onTap,
    double size = 26,
  }) {
    return AppIconButton(
      key: key,
      icon: icon,
      tooltip: tooltip,
      onTap: onTap,
      size: size,
      height: _MessageWithActions.room,
      iconSize: 15,
      radius: 5,
      muted: true,
      tooltipWait: const Duration(milliseconds: 500),
    );
  }

  /// The "⋯" button of a reply: a small card with how the reply went and what wrote it.
  Widget _statsButton(BuildContext context, ReplyStats stats) {
    final c = context.colors;
    return MenuAnchor(
      style: bareMenuStyle,
      clipBehavior: Clip.none,
      onOpen: () => setState(() => _cardOpen = true),
      onClose: () {
        if (mounted) setState(() => _cardOpen = false);
      },
      builder: (context, controller, _) => _button(
        context,
        key: Key('more-${widget.index}'),
        icon: Icons.more_horiz_rounded,
        tooltip: 'Details of this reply',
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
      ),
      menuChildren: [
        MenuPanel(
          color: c.inputFill,
          border: c.inputBorder,
          elevation: 2,
          shadowColor: Theme.of(context).shadowColor,
          padding: EdgeInsets.zero,
          children: [ReplyStatsCard(stats: stats)],
        ),
      ],
    );
  }

  /// `‹ 1/2 ›`, with "writing" (or "2 writing") beside it while a reply is being written under one of the versions
  /// (on the side away from the edge the row is at, so the arrows do not move when it comes and goes).
  Widget _versions(BuildContext context, {required bool mine}) {
    final m = widget.message;
    final i = widget.index;
    final flip = widget.onFlip;
    final writing = widget.writing == null
        ? null
        : Padding(
            padding: EdgeInsets.only(left: mine ? 0 : 6, right: mine ? 6 : 0),
            child: Text(
              widget.writing!,
              key: Key('version-writing-$i'),
              style: TextStyle(fontSize: 12, color: context.colors.textMuted),
            ),
          );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mine && writing != null) writing,
        _button(
          context,
          key: Key('version-prev-$i'),
          icon: Icons.chevron_left_rounded,
          tooltip: 'Previous version',
          onTap: flip == null || m.version == 0 ? null : () => flip(-1),
          size: 22,
        ),
        Text(
          '${m.version + 1}/${m.versions}',
          key: Key('version-$i'),
          style: TextStyle(fontSize: 12, color: context.colors.textMuted, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
        _button(
          context,
          key: Key('version-next-$i'),
          icon: Icons.chevron_right_rounded,
          tooltip: 'Next version',
          onTap: flip == null || m.version >= m.versions - 1 ? null : () => flip(1),
          size: 22,
        ),
        if (!mine && writing != null) writing,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final mine = widget.message.role == Role.user;
    final shown = widget.actions && (_hovered || _copied || _cardOpen || widget.always);
    // (Also on the reply being written, whose other buttons wait until it is done.)
    final versions = widget.message.versions > 1;
    final i = widget.index;
    final blocked = widget.blocked;
    // (A sent message is at the right edge, so its versions go at the right end of the row and the buttons grow to
    // their left: the arrows stay where they are when the pointer arrives.)
    final buttons = [
      _button(
        context,
        key: Key('copy-$i'),
        icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
        tooltip: _copied ? 'Copied' : 'Copy',
        onTap: _copy,
      ),
      if (widget.onEdit != null)
        _button(
          context,
          key: Key('edit-$i'),
          icon: Icons.edit_outlined,
          tooltip: blocked ?? 'Edit',
          onTap: blocked == null ? widget.onEdit : null,
        ),
      if (widget.onRegenerate != null)
        _button(
          context,
          key: Key('regenerate-$i'),
          icon: Icons.refresh_rounded,
          tooltip: blocked ?? 'Regenerate',
          onTap: blocked == null ? widget.onRegenerate : null,
        ),
      if (widget.bookmarked case final on?)
        _button(
          context,
          key: Key('bookmark-$i'),
          icon: on ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
          tooltip: on ? 'Remove bookmark' : 'Bookmark',
          onTap: widget.onBookmark,
        ),
      if (widget.message.stats case final stats? when !stats.isEmpty) _statsButton(context, stats),
    ];
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          widget.child,
          SizedBox(
            height: _MessageWithActions.room,
            child: shown || versions
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (versions && !mine) _versions(context, mine: false),
                      if (shown) ...buttons,
                      if (versions && mine) _versions(context, mine: true),
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
                        hoverColor: c.rowHover,
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

  /// The box holds the text of the message being edited, not a draft: what is typed is not kept as the draft, which
  /// is still there when the editing ends.
  var _editing = false;

  @override
  void initState() {
    super.initState();
    _shown = this;
    final chats = ref.read(chatsProvider);
    _load(draftKey(chats.openId, chats.kind));
    if (chats.editing != null && chats.editing!.chatId == chats.openId) _loadEdit();
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

  /// Every change of the text (or the cursor) is kept as the draft (while a message is edited, as the text of the
  /// edit).
  void _typed() {
    if (_editing) {
      ref.read(chatsProvider.notifier).editText = _text.text;
      return;
    }
    ref.read(draftsProvider.notifier).set(_draft, _text.text);
    _cursors[_draft] = _text.selection;
  }

  /// Puts the text of the message being edited in the box, the cursor at its end.
  void _loadEdit() {
    _editing = true;
    final text = ref.read(chatsProvider.notifier).editText ?? '';
    _text.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  /// The editing is over (sent or cancelled): the draft that was in the box comes back.
  void _endEdit() {
    _editing = false;
    final chats = ref.read(chatsProvider);
    _load(draftKey(chats.openId, chats.kind));
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
    final model = ref.read(shownModelProvider);
    final chats = ref.read(chatsProvider);
    final text = _text.text;
    if (model == null || chats.replyingId != null || ref.read(benchmarkProvider).running) return;
    if (chats.editing != null && chats.editing!.chatId == chats.openId) {
      // The new version of the message being edited (the box returns to its draft once it is sent).
      if (text.trim().isNotEmpty) ref.read(chatsProvider.notifier).sendEdit(text, model.file);
      _focus.requestFocus();
      return;
    }
    if (text.trim().isEmpty) {
      // An empty box and a queue on hold: Enter starts the queue again.
      if (ref.read(queueProvider)[chats.openId]?.hold != null) ref.read(chatsProvider.notifier).sendQueued(model.file);
      return;
    }
    // (An opened chat whose messages are still on their way cannot take a message yet: the text stays.)
    if (chats.openId != null && chats.open == null) return;
    // Emptied first, so the draft it came from (a new chat's, which becomes this chat) is gone too.
    _text.clear();
    ref.read(chatsProvider.notifier).send(text, model.file);
    _focus.requestFocus();
  }

  /// Ctrl+Enter: during this chat's reply, the message waits for its turn; otherwise it is sent as with Enter.
  void _sendOrQueue() {
    final chats = ref.read(chatsProvider);
    final id = chats.openId;
    if (id == null || chats.replyingId != id || chats.editing != null) return _send();
    final text = _text.text.trim();
    if (text.isEmpty) return;
    _text.clear();
    ref.read(queueProvider.notifier).add(id, text);
    _focus.requestFocus();
  }

  /// A waiting message clicked: it comes back to the box to be changed (after anything already typed there).
  void _editQueued(String chatId, QueuedMessage message) {
    ref.read(queueProvider.notifier).remove(chatId, message.id);
    final typed = _text.text;
    _text.text = typed.trim().isEmpty ? message.text : '$typed\n${message.text}';
    _text.selection = TextSelection.collapsed(offset: _text.text.length);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Opening another chat (or a new one) puts the cursor back in the box, with that chat's draft.
    ref.listen(chatsProvider.select((s) => s.openId), (_, _) => _focus.requestFocus());
    ref.listen(chatsProvider.select((s) => draftKey(s.openId, s.kind)), (_, key) => _load(key));
    // A message to edit comes into the box; when the editing ends, the draft comes back.
    ref.listen(chatsProvider.select((s) => s.editing), (before, now) {
      if (now != null && (before == null || before.node != now.node || before.chatId != now.chatId)) {
        _loadEdit();
        _focus.requestFocus();
      } else if (now == null && before != null && _editing) {
        _endEdit();
      }
    });
    final model = ref.watch(shownModelProvider);
    final chats = ref.watch(chatsProvider);
    final replyingHere = chats.replyingId != null && chats.replyingId == chats.openId;
    final replyingElsewhere = chats.replyingId != null && !replyingHere;

    final benchmarking = ref.watch(benchmarkProvider.select((s) => s.running));
    // Why Send cannot be pressed now: the engine is busy with something else.
    final String? busy = _sendBlock(chats, benchmarking, hereToo: false);
    final String? hint = model == null
        ? 'Download a model from the Store to start chatting.'
        : benchmarking
        ? 'A benchmark is running.'
        : replyingElsewhere
        ? 'Wait for the reply in "${chats.byId(chats.replyingId)?.title}" to finish.'
        : null;

    final failure = chats.replyingId == null && chats.failure?.chatId == chats.openId ? chats.failure : null;
    final canThink = model != null && model.model.thinking != ModelThinking.none;
    final queue = ref.watch(queueProvider)[chats.openId];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (failure != null) _EngineFailureCard(failure),
        if (chats.openId != null && queue != null)
          _QueueRows(
            chatId: chats.openId!,
            queue: queue,
            canSend: model != null && chats.replyingId == null && !benchmarking,
            onSendNext: () => ref.read(chatsProvider.notifier).sendQueued(model!.file),
            onEdit: (message) => _editQueued(chats.openId!, message),
          ),
        if (canThink)
          Align(
            alignment: Alignment.centerLeft,
            child: ThinkingToggle(canChoose: model.model.thinking == ModelThinking.optional),
          ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  hint,
                  key: const Key('box-hint'),
                  style: TextStyle(fontSize: 13, color: c.textMuted),
                ),
                if (benchmarking) ...[
                  const SizedBox(width: 6),
                  AppButton(
                    key: const Key('to-benchmark'),
                    label: 'Open it',
                    dense: true,
                    onTap: () {
                      ref.read(engineTabProvider.notifier).show(benchmark: true);
                      ref.read(sectionProvider.notifier).select(Section.engine);
                    },
                  ),
                ],
              ],
            ),
          ),
        if (chats.editing != null && chats.editing!.chatId == chats.openId)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Editing message · ', key: const Key('editing-note'), style: TextStyle(fontSize: 13, color: c.textMuted)),
                AppButton(
                  key: const Key('edit-cancel'),
                  label: 'Cancel',
                  dense: true,
                  onTap: () => ref.read(chatsProvider.notifier).cancelEdit(),
                ),
              ],
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
                    const SingleActivator(LogicalKeyboardKey.enter, control: true): _sendOrQueue,
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
                  ? AppIconButton(
                      key: const Key('stop'),
                      tooltip: 'Stop',
                      icon: Icons.stop_rounded,
                      look: IconButtonLook.outlined,
                      round: true,
                      onTap: () => ref.read(chatsProvider.notifier).stop(),
                    )
                  : AppIconButton(
                      key: const Key('send'),
                      tooltip: busy ?? 'Send',
                      icon: Icons.arrow_upward,
                      look: IconButtonLook.main,
                      round: true,
                      onTap: busy == null && hint == null ? _send : null,
                    ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The messages waiting for their turn, one line each: X removes one, a click brings it back to the box, dragging
/// changes the order. On hold, a small line says so and offers Send next.
class _QueueRows extends ConsumerWidget {
  const _QueueRows({
    required this.chatId,
    required this.queue,
    required this.canSend,
    required this.onSendNext,
    required this.onEdit,
  });

  final String chatId;
  final ChatQueue queue;
  final bool canSend;
  final VoidCallback onSendNext;
  final void Function(QueuedMessage) onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final notifier = ref.read(queueProvider.notifier);
    final messages = queue.messages;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (queue.hold != null)
            Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text('On hold', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                ),
                const Spacer(),
                AppButton(
                  key: const Key('queue-send-next'),
                  label: 'Send next',
                  dense: true,
                  onTap: canSend ? onSendNext : null,
                ),
              ],
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 172),
            child: ReorderableList(
              shrinkWrap: true,
              itemCount: messages.length,
              onReorderItem: (from, to) => notifier.move(chatId, from, to),
              proxyDecorator: (child, _, _) => Material(type: MaterialType.transparency, child: child),
              itemBuilder: (context, i) => ReorderableDragStartListener(
                key: ValueKey(messages[i].id),
                index: i,
                enabled: messages.length > 1,
                child: _QueueRow(
                  message: messages[i],
                  onTap: () => onEdit(messages[i]),
                  onRemove: () => notifier.remove(chatId, messages[i].id),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({required this.message, required this.onTap, required this.onRemove});

  final QueuedMessage message;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: Key('queued-${message.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          decoration: BoxDecoration(
            color: c.inputFill,
            border: Border.all(color: c.inputBorder),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  message.text.replaceAll('\n', ' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, color: c.textSecondary),
                ),
              ),
              const SizedBox(width: 6),
              AppIconButton(
                key: Key('queued-remove-${message.id}'),
                tooltip: 'Remove',
                icon: Icons.close,
                round: true,
                muted: true,
                size: 24,
                iconSize: 14,
                tooltipWait: const Duration(milliseconds: 1500),
                onTap: onRemove,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The engine could not write the reply: what happened, its last lines of output, and Try again.
class _EngineFailureCard extends ConsumerWidget {
  const _EngineFailureCard(this.failure);

  final ReplyFailure failure;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    // (Writing the reply again starts the engine, which a benchmark has.)
    final benchmarking = ref.watch(benchmarkProvider.select((s) => s.running));
    return Container(
      key: const Key('engine-failure'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
      decoration: BoxDecoration(
        color: c.inputFill,
        border: Border.all(color: c.inputBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: SelectableText(failure.message, style: TextStyle(fontSize: 14, height: 1.4, color: c.text))),
              AppButton(
                key: const Key('engine-try-again'),
                label: 'Try again',
                onTap: benchmarking ? null : () => ref.read(chatsProvider.notifier).retry(),
              ),
            ],
          ),
          if (failure.log.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 130),
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(
                  failure.log.join('\n'),
                  style: TextStyle(fontSize: 12, height: 1.4, color: c.textMuted, fontFamily: 'monospace'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
