import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/archive_view.dart';
import '../state/chats.dart';
import '../state/delete_guard.dart';
import '../state/folds.dart';
import '../state/providers.dart';
import '../state/section.dart';
import '../state/today.dart';
import '../theme.dart';
import 'buttons.dart';
import 'menu_panel.dart';

/// Saved chats: the pinned ones first, in the user's order, then all of them (the pinned ones too) under the day they
/// were last used (Today, Yesterday, 28 Oct, ...). Pinned is a shortcut: the chat also stays under its day, and
/// deleting or renaming it in either place does it to the chat. Under Pinned and under each day, the chats can be
/// dragged into another order, when there are at least two. Each chat has a menu (the "⋯" button on hover, or a
/// right-click): Rename, Pin / Unpin, Delete.
class ChatList extends ConsumerStatefulWidget {
  const ChatList({super.key, required this.showSelection});

  final bool showSelection;

  @override
  ConsumerState<ChatList> createState() => _ChatListState();
}

/// A group of the list: Pinned, or one day. [fold]: its key for folding ("pinned" or the day, "2026-10-30");
/// [folded]: it is folded, so [chats] holds only the open chat if it is in it.
typedef ChatGroup = ({String key, String heading, List<ChatInfo> chats, String fold, bool folded});
typedef _Group = ChatGroup;

/// The list's groups, as shown: Pinned, then the other chats by day (a pinned chat is only under Pinned). A folded
/// group holds only the open chat, if it is in it.
List<ChatGroup> chatGroups(ChatsState state, DateTime today, Set<String> folds) {
  final pinned = state.shownPins;
  final all = <({String key, String heading, List<ChatInfo> chats, String fold})>[
    if (pinned.isNotEmpty) (key: 'pinned', heading: 'Pinned', chats: pinned, fold: 'pinned'),
  ];
  final pinnedIds = {for (final c in pinned) c.id};
  for (final chat in state.shown) {
    if (pinnedIds.contains(chat.id)) continue;
    final l = dayLabel(chat.updatedAt, today);
    if (all.isEmpty || all.last.heading != l || all.last.key == 'pinned') {
      all.add((key: 'day-$l', heading: l, chats: [], fold: dayKey(chat.updatedAt)));
    }
    all.last.chats.add(chat);
  }
  return [
    for (final g in all)
      (
        key: g.key,
        heading: g.heading,
        chats: folds.contains(g.fold) ? [for (final c in g.chats) if (c.id == state.openId) c] : g.chats,
        fold: g.fold,
        folded: folds.contains(g.fold),
      ),
  ];
}

/// The chats the list shows, top to bottom (a pinned chat once, under Pinned); the archived
/// ones instead when [archive].
List<String> listOrder(ChatsState state, DateTime today, Set<String> folds, {required bool archive}) => archive
    ? [for (final c in state.shownArchived) c.id]
    : [for (final g in chatGroups(state, today, folds)) for (final c in g.chats) c.id];

/// The sidebar's chat rows that are built (on screen, or nearly), so the keyboard shortcuts can find the open chat's
/// row: to scroll to it, open its menu or rename it. [occurrence]: which of a chat's rows (each chat now has one,
/// so 0).
class SidebarRows {
  static final _rows = <({String id, int occurrence, BuildContext context, _ChatRowState? row})>[];

  static void _add(String id, int occurrence, BuildContext context, _ChatRowState? row) =>
      _rows.add((id: id, occurrence: occurrence, context: context, row: row));

  static void _remove(BuildContext context) => _rows.removeWhere((r) => r.context == context);

  /// A chat's menu is open (its keys are the menu's).
  static bool get menuOpen => _rows.any((r) => r.row?._menuOpen ?? false);

  /// A chat is being renamed.
  static bool get renaming => _rows.any((r) => r.row?._editing ?? false);

  static ({String id, int occurrence, BuildContext context, _ChatRowState? row})? _find(String id, int occurrence) =>
      _rows.where((r) => r.id == id && r.occurrence == occurrence && r.context.mounted).lastOrNull;

  /// The list around a row: the outermost scrolling one (each group is a list of its own that does not scroll).
  static ScrollableState? _listAround(BuildContext row) {
    var list = Scrollable.maybeOf(row);
    while (list != null) {
      final outer = Scrollable.maybeOf(list.context);
      if (outer == null) break;
      list = outer;
    }
    return list;
  }

  /// Scrolls the sidebar to the chat's row ([order]: what the sidebar shows, see [listOrder]), as little as it takes
  /// ([down]: the row comes in at the bottom). A row far off is not built yet: the list moves towards it a screen at
  /// a time until it is. Gives the row, or null when it is not in the sidebar.
  static Future<({void Function() menu, void Function() rename})?> reveal(String id, List<String> order,
      {int occurrence = 0, bool down = true}) async {
    int at(String id, int occurrence) {
      var seen = 0;
      for (var i = 0; i < order.length; i++) {
        if (order[i] == id && seen++ == occurrence) return i;
      }
      return -1;
    }

    final target = at(id, occurrence);
    if (target < 0) return null;
    for (var tries = 0; tries < 200; tries++) {
      final row = _find(id, occurrence);
      if (row != null) {
        await Scrollable.ensureVisible(row.context,
            alignmentPolicy:
                down ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd : ScrollPositionAlignmentPolicy.keepVisibleAtStart);
        final state = row.row;
        if (state == null || !state.mounted) return (menu: () {}, rename: () {});
        return (menu: state._openMenu, rename: state._startRename);
      }
      final built = [for (final r in _rows) if (r.context.mounted) r];
      if (built.isEmpty) return null;
      final places = [for (final r in built) at(r.id, r.occurrence)]..removeWhere((i) => i < 0);
      if (places.isEmpty) return null;
      final list = _listAround(built.first.context);
      if (list == null) return null;
      final p = list.position;
      final step = target > places.reduce(math.max) ? 1 : (target < places.reduce(math.min) ? -1 : 0);
      if (step == 0) return null;
      final to = clampDouble(p.pixels + step * p.viewportDimension * 0.8, p.minScrollExtent, p.maxScrollExtent);
      if (to == p.pixels) return null;
      p.jumpTo(to);
      await SchedulerBinding.instance.endOfFrame;
    }
    return null;
  }
}

/// Puts a row that is not a [ChatRow] (a search result) in [SidebarRows] while it is built.
class SidebarRowMark extends StatefulWidget {
  const SidebarRowMark({super.key, required this.id, required this.child});

  final String id;
  final Widget child;

  @override
  State<SidebarRowMark> createState() => _SidebarRowMarkState();
}

class _SidebarRowMarkState extends State<SidebarRowMark> {
  @override
  void initState() {
    super.initState();
    SidebarRows._add(widget.id, 0, context, null);
  }

  @override
  void didUpdateWidget(SidebarRowMark old) {
    super.didUpdateWidget(old);
    if (old.id == widget.id) return;
    SidebarRows._remove(context);
    SidebarRows._add(widget.id, 0, context, null);
  }

  @override
  void dispose() {
    SidebarRows._remove(context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ChatListState extends ConsumerState<ChatList> {
  // What the list showed last time, to see which rows came and went: rows that come open (grow from nothing and
  // fade in), rows that go close, the same way. Not when the whole list changes (Chat / Code switched, the day
  // changed), and not the first time.
  List<_Group>? _before;
  ChatKind? _beforeKind;
  DateTime? _beforeToday;

  /// Rows ("group|chat id") and whole groups (group key) that open when they are first built.
  final _opening = <String>{};

  /// Rows that close, by group, with the place they had; and whole groups that close, with theirs.
  final _closing = <String, List<({int at, ChatInfo chat})>>{};
  final _closingGroups = <String, ({int at, _Group group})>{};

  void _compare(List<_Group> groups, ChatKind kind, DateTime today) {
    final before = _before;
    if (before == null || kind != _beforeKind || today != _beforeToday) {
      _opening.clear();
      _closing.clear();
      _closingGroups.clear();
    } else {
      final old = {for (final g in before) g.key: g};
      final now = {for (final g in groups) g.key: g};
      for (final g in groups) {
        final was = old[g.key];
        if (was == null) {
          _opening.add(g.key);
          continue;
        }
        final wasIds = {for (final c in was.chats) c.id};
        final ids = {for (final c in g.chats) c.id};
        for (final c in g.chats) {
          if (!wasIds.contains(c.id)) _opening.add('${g.key}|${c.id}');
        }
        for (var i = 0; i < was.chats.length; i++) {
          if (!ids.contains(was.chats[i].id)) (_closing[g.key] ??= []).add((at: i, chat: was.chats[i]));
        }
      }
      for (var i = 0; i < before.length; i++) {
        if (!now.containsKey(before[i].key)) _closingGroups[before[i].key] = (at: i, group: before[i]);
      }
      // Built in this frame (the rows on screen); rows built later, when scrolled to, just appear.
      if (_opening.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _opening.clear());
    }
    _before = groups;
    _beforeKind = kind;
    _beforeToday = today;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = ref.watch(chatsProvider);
    final today = ref.watch(todayProvider);
    final chats = state.shown;
    final notifier = ref.read(chatsProvider.notifier);
    final pinnedIds = state.pinned.toSet();

    // The groups: Pinned, then the chats by day, in the order shown. A folded group shows only the open chat, if
    // it is in it (its rows close and open like any rows that go and come).
    final folds = ref.watch(foldsProvider)[state.kind]!;
    final groups = chatGroups(state, today, folds);
    _compare(groups, state.kind, today);

    // The archived chats, shown in place of the list when the sidebar's Archived row is chosen.
    final archived = state.shownArchived;
    final inArchive = archived.isNotEmpty && ref.watch(archiveViewProvider).contains(state.kind);
    if (inArchive) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          key: const Key('archive-back'),
          borderRadius: BorderRadius.circular(6),
          hoverColor: c.rowHover,
          highlightColor: c.rowPressed,
          onTap: () => ref.read(archiveViewProvider.notifier).close(state.kind),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 8, 6),
            child: Row(children: [
              Icon(Icons.arrow_back, size: 16, color: c.sideMuted),
              const SizedBox(width: 6),
              Text('Archived', style: TextStyle(fontSize: 12, color: c.sideMuted)),
            ]),
          ),
        ),
        // One plain list, the last active first; built only as far as it is on screen.
        Expanded(
          child: ListView.builder(
            itemCount: archived.length,
            itemBuilder: (context, i) => ChatRow(
              key: ValueKey(archived[i].id),
              chat: archived[i],
              pinned: false,
              selected: widget.showSelection && archived[i].id == state.openId,
              replying: archived[i].id == state.replyingId,
            ),
          ),
        ),
      ]);
    }

    final note = UnreadableNote(ref.watch(chatStoreProvider).unreadable);
    if (chats.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
            child: Text(state.kind == ChatKind.code ? 'Your code chats will show here.' : 'Your chats will show here.',
                style: TextStyle(fontSize: 13, color: c.sideMuted)),
          ),
          note,
        ]),
      );
    }

    // A heading: a click folds its group or opens it; the arrow shows which (down: open).
    final shownFolds = [for (final g in groups) g.fold];
    Widget label(_Group g) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: InkWell(
            key: Key('heading-${g.heading}'),
            borderRadius: BorderRadius.circular(6),
            hoverColor: c.rowHover,
            highlightColor: c.rowPressed,
            onTap: () => ref.read(foldsProvider.notifier).toggle(state.kind, g.fold, shownFolds),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: Row(children: [
                Text(g.heading, style: TextStyle(fontSize: 12, color: c.sideMuted)),
                const SizedBox(width: 2),
                AnimatedRotation(
                  turns: g.folded ? -0.25 : 0,
                  duration: _rowMotion,
                  child: Icon(Icons.keyboard_arrow_down, size: 14, color: c.sideMuted),
                ),
              ]),
            ),
          ),
        );
    // The lifted row; drawn [_liftShift] higher than the list places it (see [_BoundedDrag]), less and less as it
    // settles into its place when dropped.
    Widget lifted(Widget child, int _, Animation<double> animation) => AnimatedBuilder(
          animation: Listenable.merge([animation, _liftShift]),
          builder: (context, child) =>
              Transform.translate(offset: Offset(0, -_liftShift.value * animation.value), child: child),
          child: Material(
            color: c.sidebar,
            elevation: 3,
            shadowColor: Colors.black26,
            borderRadius: BorderRadius.circular(8),
            child: child,
          ),
        );
    ChatRow chatRow(ChatInfo chat, {required bool inPinned}) => ChatRow(
          chat: chat,
          pinned: pinnedIds.contains(chat.id),
          pinMark: !inPinned && pinnedIds.contains(chat.id),
          selected: widget.showSelection && chat.id == state.openId,
          replying: chat.id == state.replyingId,
        );

    // One group: its heading and its chats, which can be reordered among themselves when there are at least two
    // (and none is closing). [leaving]: the whole group is closing.
    Widget group(_Group g, {bool leaving = false}) {
      final inPinned = g.key == 'pinned';
      final ids = [for (final chat in g.chats) chat.id];
      final items = <Object>[...g.chats];
      for (final gone in leaving ? const <({int at, ChatInfo chat})>[] : _closing[g.key] ?? const []) {
        items.insert(math.min(gone.at, items.length), gone);
      }
      final canDrag = !leaving && g.chats.length > 1 && items.length == g.chats.length;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          label(g),
          ReorderableList(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            onReorderItem: inPinned ? notifier.movePin : (from, to) => notifier.moveInDay(ids, from, to),
            proxyDecorator: lifted,
            itemBuilder: (context, j) => switch (items[j]) {
              final ChatInfo chat => ChatDragHandle(
                  key: ValueKey(chat.id),
                  index: j,
                  enabled: canDrag,
                  child: _Opening(open: _opening.contains('${g.key}|${chat.id}'), child: chatRow(chat, inPinned: inPinned)),
                ),
              final ({int at, ChatInfo chat}) gone => KeyedSubtree(
                  key: ValueKey('closing-${gone.chat.id}'),
                  child: _Closing(
                    onDone: () => setState(() => _closing[g.key]?.remove(gone)),
                    child: chatRow(gone.chat, inPinned: inPinned),
                  ),
                ),
              _ => const SizedBox.shrink(),
            },
          ),
        ],
      );
    }

    // The groups to show: today's, and those closing at the places they had.
    final shown = <(_Group, bool)>[for (final g in groups) (g, false)];
    for (final gone in _closingGroups.values.toList()..sort((a, b) => a.at - b.at)) {
      shown.insert(math.min(gone.at, shown.length), (gone.group, true));
    }
    Widget shownGroup((_Group, bool) entry) {
      final (g, leaving) = entry;
      if (leaving) {
        return _Closing(
          key: ValueKey('closing-${g.key}'),
          onDone: () => setState(() => _closingGroups.remove(g.key)),
          child: group(g, leaving: true),
        );
      }
      return KeyedSubtree(key: ValueKey(g.key), child: _Opening(open: _opening.contains(g.key), child: group(g)));
    }

    final pinnedShown = shown.where((e) => e.$1.key == 'pinned').toList();
    final days = shown.where((e) => e.$1.key != 'pinned').toList();
    final place = {for (var i = 0; i < days.length; i++) (days[i].$2 ? 'closing-${days[i].$1.key}' : days[i].$1.key): i};

    return CustomScrollView(slivers: [
      for (final p in pinnedShown) SliverToBoxAdapter(child: shownGroup(p)),
      // One day at a time, built only when on screen; each day's chats are one list that can be reordered.
      SliverList.builder(
        itemCount: days.length,
        itemBuilder: (context, i) => shownGroup(days[i]),
        // Keeps each day's rows (and their state: hover, renaming) with that day when the list changes.
        findChildIndexCallback: (key) => key is ValueKey<String> ? place[key.value] : null,
      ),
      SliverToBoxAdapter(child: note),
    ]);
  }
}

const _rowMotion = Duration(milliseconds: 150);

/// A quiet line at the end of the list when chat files could not be read ("1 chat file could not be read"); hovering
/// it names the files. Nothing when there are none.
class UnreadableNote extends StatelessWidget {
  const UnreadableNote(this.files, {super.key});

  final List<String> files;

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const SizedBox.shrink();
    final text = files.length == 1 ? '1 chat file could not be read' : '${files.length} chat files could not be read';
    return Tooltip(
      message: files.join('\n'),
      triggerMode: TooltipTriggerMode.tap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: Text(text, key: const Key('unreadable-note'), style: TextStyle(fontSize: 11, color: context.colors.sideMuted)),
      ),
    );
  }
}

/// A row or group that grows from nothing and fades in when [open] as it is first built; otherwise just [child].
class _Opening extends StatefulWidget {
  const _Opening({required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  State<_Opening> createState() => _OpeningState();
}

class _OpeningState extends State<_Opening> with SingleTickerProviderStateMixin {
  // Only rows that open get an animation (a long day builds many rows at once).
  late final AnimationController? _grow =
      widget.open ? (AnimationController(vsync: this, duration: _rowMotion)..forward()) : null;

  @override
  void dispose() {
    _grow?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final grow = _grow;
    if (grow == null) return widget.child;
    final curve = CurvedAnimation(parent: grow, curve: Curves.easeOutCubic);
    return SizeTransition(sizeFactor: curve, alignment: AlignmentDirectional.topStart, child: FadeTransition(opacity: curve, child: widget.child));
  }
}

/// A row or group that was removed: it shrinks to nothing and fades out, then [onDone]. It cannot be clicked.
class _Closing extends StatefulWidget {
  const _Closing({super.key, required this.onDone, required this.child});

  final VoidCallback onDone;
  final Widget child;

  @override
  State<_Closing> createState() => _ClosingState();
}

class _ClosingState extends State<_Closing> with SingleTickerProviderStateMixin {
  late final _shrink = AnimationController(vsync: this, duration: _rowMotion, value: 1)
    ..reverse().whenComplete(() {
      if (mounted) widget.onDone();
    });

  @override
  void dispose() {
    _shrink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _shrink, curve: Curves.easeOutCubic);
    return IgnorePointer(
      child: SizeTransition(sizeFactor: curve, alignment: AlignmentDirectional.topStart, child: FadeTransition(opacity: curve, child: widget.child)),
    );
  }
}

/// Pressing a chat and moving the pointer drags it within its group (Pinned, or one day), when [enabled]. The
/// dragged chat stays inside its group and inside the visible part of the list: it never goes past a heading or
/// over Store and Settings. Held against the top or bottom of the list while its group goes on beyond it, it
/// scrolls the list, faster the further the pointer is pushed.
class ChatDragHandle extends StatelessWidget {
  const ChatDragHandle({super.key, required this.index, required this.enabled, required this.child});

  final int index;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(onPointerDown: enabled ? (e) => _start(context, e) : null, child: child);

  void _start(BuildContext context, PointerDownEvent event) {
    final list = SliverReorderableList.maybeOf(context);
    // The group's own list (it never scrolls), and the chat list around it, which does.
    final groupList = Scrollable.maybeOf(context);
    final outer = groupList == null ? null : Scrollable.maybeOf(groupList.context);
    if (list == null || groupList == null || outer == null) return;
    list.startItemDragReorder(
      index: index,
      event: event,
      recognizer: _BoundedRecognizer(
        debugOwner: this,
        wrap: (drag, start) => _BoundedDrag(drag, start, row: context.findRenderObject()! as RenderBox, group: groupList, outer: outer),
      ),
    );
  }
}

/// How much higher the dragged row is drawn than where the list was told it is (one drag at a time).
final _liftShift = ValueNotifier<double>(0);

/// Starts a drag at once (like the list's own handle), and hands the list a [_BoundedDrag] around its drag.
class _BoundedRecognizer extends ImmediateMultiDragGestureRecognizer {
  _BoundedRecognizer({super.debugOwner, required this.wrap});

  final Drag Function(Drag drag, Offset start) wrap;

  @override
  set onStart(GestureMultiDragStartCallback? start) => super.onStart = start == null
      ? null
      : (position) {
          final drag = start(position);
          return drag == null ? null : wrap(drag, position);
        };
}

/// Passes the pointer's moves on to the list's drag, held so the dragged row stays inside its group and inside
/// the visible list; and scrolls the list while the pointer is pushed past its top or bottom.
class _BoundedDrag extends Drag {
  _BoundedDrag(this._drag, Offset start, {required RenderBox row, required this.group, required this.outer})
      : _pointer = start,
        _sent = start.dy,
        _grab = row.globalToLocal(start).dy,
        _height = row.size.height {
    _liftShift.value = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) => _scrollIfPushed());
  }

  final Drag _drag;
  final ScrollableState group;
  final ScrollableState outer;

  /// Where the pointer really is, and where the list was last told it is (both global).
  Offset _pointer;
  double _sent;

  /// Where in the row it was grabbed, and the row's height.
  final double _grab;
  final double _height;
  Timer? _timer;

  static Rect _rect(ScrollableState s) {
    final box = s.context.findRenderObject()! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  void update(DragUpdateDetails details) {
    _pointer += Offset(0, details.delta.dy);
    _send();
  }

  /// Tells the list the pointer's place, held inside the group and the visible list. [scrolled]: how far the
  /// list was just scrolled, before its rows were laid out again (they will be [scrolled] higher).
  void _send({double scrolled = 0}) {
    final g = _rect(group).shift(Offset(0, -scrolled)), v = _rect(outer);
    var top = math.max(g.top, v.top), bottom = math.min(g.bottom, v.bottom);
    // The group nearly scrolled out of sight: the row still needs its own height of room.
    if (bottom - top < _height) {
      if (top > v.top) {
        bottom = top + _height;
      } else {
        top = bottom - _height;
      }
    }
    final lowest = math.max(top + _grab, bottom - _height + _grab);
    var y = clampDouble(_pointer.dy, top + _grab, lowest);
    // Held at the end of its group, the row covers the group's last place; the list only puts it after the last
    // chat once it is past that chat's middle. So the list is told it is half a row further down, and the row is
    // drawn that much higher, where it is held.
    final atEnd = _pointer.dy >= lowest && g.bottom <= v.bottom + 0.5;
    _liftShift.value = atEnd ? _height / 2 + 1 : 0;
    y += _liftShift.value;
    final dy = y - _sent;
    _sent = y;
    _drag.update(DragUpdateDetails(globalPosition: Offset(_pointer.dx, y), delta: Offset(0, dy)));
  }

  /// A scroll step whose frame has not been drawn yet: the rows' places are not known until it is.
  bool _waitingForFrame = false;

  void _scrollIfPushed() {
    if (_waitingForFrame) return;
    final g = _rect(group), v = _rect(outer);
    final rowTop = _pointer.dy - _grab;
    double push = 0;
    if (rowTop < v.top && g.top < v.top - 0.5) {
      push = rowTop - v.top;
    } else if (rowTop + _height > v.bottom && g.bottom > v.bottom + 0.5) {
      push = rowTop + _height - v.bottom;
    }
    if (push == 0) return;
    final position = outer.position;
    final step = push.sign * math.min(2 + push.abs() / 3, 20);
    final to = clampDouble(position.pixels + step, position.minScrollExtent, position.maxScrollExtent);
    if (to == position.pixels) return;
    final scrolled = to - position.pixels;
    position.jumpTo(to);
    // At once, so the dragged row does not show past its group for a frame; and again once the rows have moved,
    // so the list sees which row the dragged one is over now.
    _send(scrolled: scrolled);
    _waitingForFrame = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _waitingForFrame = false;
      if (_timer != null) _send();
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void end(DragEndDetails details) {
    _stop();
    _drag.end(details);
  }

  @override
  void cancel() {
    _stop();
    _liftShift.value = 0;
    _drag.cancel();
  }
}

/// One chat in the list: click to open it; the "⋯" button (shown on hover) or a right-click opens its menu.
class ChatRow extends ConsumerStatefulWidget {
  const ChatRow({
    super.key,
    required this.chat,
    required this.pinned,
    required this.selected,
    required this.replying,
    this.pinMark = false,
  });

  final ChatInfo chat;

  /// The chat is pinned (its menu says Unpin).
  final bool pinned;
  final bool selected;

  /// A small pin after the title: the row under its day of a chat that is also under Pinned.
  final bool pinMark;

  /// Its reply is being written (a dot shows).
  final bool replying;

  @override
  ConsumerState<ChatRow> createState() => _ChatRowState();
}

class _ChatRowState extends ConsumerState<ChatRow> {
  final _menu = MenuController();
  bool _hovered = false;
  bool _menuOpen = false;

  /// Renaming: the title is a text box.
  bool _editing = false;
  final _name = TextEditingController();
  final _nameFocus = FocusNode();

  /// The open menu takes the keys (R, P, D), and gives the focus back to where it was when it closes.
  final _menuFocus = FocusNode(debugLabel: 'chat menu');
  FocusNode? _focusBefore;

  @override
  void initState() {
    super.initState();
    SidebarRows._add(widget.chat.id, _occurrence, context, this);
    // Clicking somewhere else while renaming saves the new name, like Enter.
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) _endRename(save: true);
    });
  }

  /// Which of the chat's rows this is (see [SidebarRows]): the one under its day of a pinned chat is the second.
  int get _occurrence => widget.pinMark ? 1 : 0;

  @override
  void didUpdateWidget(ChatRow old) {
    super.didUpdateWidget(old);
    if (old.chat.id == widget.chat.id && old.pinMark == widget.pinMark) return;
    SidebarRows._remove(context);
    SidebarRows._add(widget.chat.id, _occurrence, context, this);
  }

  @override
  void dispose() {
    SidebarRows._remove(context);
    _name.dispose();
    _nameFocus.dispose();
    _menuFocus.dispose();
    super.dispose();
  }

  void _open() {
    // The section first: coming back to it may open its chat from before, which this one then replaces.
    ref.read(sectionProvider.notifier).select(Section.of(widget.chat.kind));
    ref.read(chatsProvider.notifier).open(widget.chat.id);
  }

  void _startRename() {
    _name.text = widget.chat.title;
    _name.selection = TextSelection(baseOffset: 0, extentOffset: _name.text.length);
    setState(() => _editing = true);
    // After the menu has closed (it gives the focus back to where it was).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _nameFocus.requestFocus();
    });
  }

  void _endRename({required bool save}) {
    if (!_editing) return;
    if (save) ref.read(chatsProvider.notifier).rename(widget.chat.id, _name.text);
    setState(() => _editing = false);
  }

  /// Opens the menu just below the "⋯" button (a right-click opens it at the pointer instead).
  void _toggleMenuFromButton() {
    if (_menu.isOpen) return _menu.close();
    final size = context.size!;
    _menu.open(position: Offset(size.width - 30, size.height + 2));
  }

  /// Opens the menu below the "⋯" button (the keyboard shortcut).
  void _openMenu() {
    if (!mounted || _editing || _menu.isOpen) return;
    _toggleMenuFromButton();
  }

  void _togglePin() {
    final chats = ref.read(chatsProvider.notifier);
    widget.pinned ? chats.unpin(widget.chat.id) : chats.pin(widget.chat.id);
  }

  void _toggleArchive() {
    final chats = ref.read(chatsProvider.notifier);
    widget.chat.archived ? chats.unarchive(widget.chat.id) : chats.archive(widget.chat.id);
  }

  Future<void> _delete() async {
    final guard = ref.read(deleteGuardProvider);
    if (guard.asks && !await _confirmDelete(context, widget.chat.title)) return;
    if (!mounted) return;
    guard.deleted();
    ref.read(chatsProvider.notifier).delete(widget.chat.id);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (_editing) return _renameBox(c);

    final showMenuButton = _hovered || _menuOpen;
    final row = Material(
      color: widget.selected || _menuOpen ? c.rowSelected : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        hoverColor: widget.selected || _menuOpen ? c.rowSelected : c.rowHover,
        highlightColor: c.rowPressed,
        onTap: _open,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
          child: Row(children: [
            Expanded(
              child: CutTitle(
                TextSpan(
                  text: widget.chat.title,
                  style: TextStyle(fontSize: 14, color: widget.selected ? c.text : c.sideText),
                ),
                full: widget.chat.title,
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 26,
              height: 18,
              child: showMenuButton
                  ? Tooltip(
                      message: 'More',
                      waitDuration: const Duration(milliseconds: 600),
                      child: InkWell(
                        key: Key('chat-menu-${widget.chat.id}'),
                        borderRadius: BorderRadius.circular(4),
                        hoverColor: c.rowPressed,
                        onTap: _toggleMenuFromButton,
                        child: Icon(Icons.more_horiz, size: 18, color: c.textSecondary),
                      ),
                    )
                  // A dot while this chat's reply is being written.
                  : widget.replying
                      ? Center(
                          child: Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(color: c.text, shape: BoxShape.circle),
                          ),
                        )
                      : widget.pinMark
                          ? Icon(Icons.push_pin_outlined,
                              key: Key('pin-mark-${widget.chat.id}'), size: 13, color: c.sideMuted)
                          : null,
            ),
          ]),
        ),
      ),
    );

    final itemStyle = MenuItemButton.styleFrom(
      foregroundColor: c.text,
      iconColor: c.textSecondary,
      iconSize: 16,
      textStyle: const TextStyle(fontSize: 13.5),
      minimumSize: const Size(168, 34),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ).copyWith(overlayColor: WidgetStatePropertyAll(c.rowHover));

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTapUp: (d) => _menu.open(position: d.localPosition),
        child: MenuAnchor(
          controller: _menu,
          onOpen: () {
            _focusBefore = FocusManager.instance.primaryFocus;
            setState(() => _menuOpen = true);
            // The menu takes the keys (once it is on screen).
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _menuOpen) _menuFocus.requestFocus();
            });
          },
          onClose: () {
            if (!mounted) return;
            setState(() => _menuOpen = false);
            // Back to where the focus was (the message box), unless what was chosen took it (renaming, the delete
            // box): checked after the frame, once that has happened.
            final before = _focusBefore;
            _focusBefore = null;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (before == null || before.context == null) return;
              if (mounted && (_editing || !(ModalRoute.of(context)?.isCurrent ?? true))) return;
              before.requestFocus();
            });
          },
          style: bareMenuStyle,
          clipBehavior: Clip.none,
          menuChildren: [
            // R, P and D do what clicking Rename, Pin / Unpin and Delete does (shown at the right of each).
            Focus(
              focusNode: _menuFocus,
              autofocus: true,
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                final action = switch (event.logicalKey) {
                  LogicalKeyboardKey.keyR => _startRename,
                  LogicalKeyboardKey.keyP when !widget.chat.archived => _togglePin,
                  LogicalKeyboardKey.keyA => _toggleArchive,
                  LogicalKeyboardKey.keyD => _delete,
                  _ => null,
                };
                if (action == null) return KeyEventResult.ignored;
                _menu.close();
                action();
                return KeyEventResult.handled;
              },
              child: MenuPanel(color: c.inputFill, border: c.inputBorder, children: [
                MenuItemButton(
                  key: const Key('menu-rename'),
                  style: itemStyle,
                  leadingIcon: const Icon(Icons.edit_outlined),
                  trailingIcon: _letter('R', c),
                  onPressed: _startRename,
                  child: const Text('Rename'),
                ),
                // (An archived chat is not pinned: archiving unpins it.)
                if (!widget.chat.archived)
                  MenuItemButton(
                    key: const Key('menu-pin'),
                    style: itemStyle,
                    leadingIcon: widget.pinned ? const PinOffIcon() : const Icon(Icons.push_pin_outlined),
                    trailingIcon: _letter('P', c),
                    onPressed: _togglePin,
                    child: Text(widget.pinned ? 'Unpin' : 'Pin'),
                  ),
                MenuItemButton(
                  key: const Key('menu-archive'),
                  style: itemStyle,
                  leadingIcon: Icon(widget.chat.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
                  trailingIcon: _letter('A', c),
                  onPressed: _toggleArchive,
                  child: Text(widget.chat.archived ? 'Unarchive' : 'Archive'),
                ),
                MenuItemButton(
                  key: const Key('menu-delete'),
                  style: itemStyle.copyWith(
                    foregroundColor: WidgetStatePropertyAll(c.danger),
                    iconColor: WidgetStatePropertyAll(c.danger),
                  ),
                  leadingIcon: const Icon(Icons.delete_outline),
                  trailingIcon: _letter('D', c),
                  onPressed: _delete,
                  child: const Text('Delete'),
                ),
              ]),
            ),
          ],
          child: row,
        ),
      ),
    );
  }

  /// A menu item's key, at its right.
  Widget _letter(String letter, AppColors c) =>
      Padding(padding: const EdgeInsets.only(left: 16), child: Text(letter, style: TextStyle(fontSize: 12.5, color: c.textMuted)));

  /// The title as a text box: Enter (or clicking elsewhere) saves, Esc cancels.
  Widget _renameBox(AppColors c) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): () => _endRename(save: true),
        const SingleActivator(LogicalKeyboardKey.escape): () => _endRename(save: false),
      },
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: c.inputFill,
          border: Border.all(color: c.inputBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.centerLeft,
        child: TextField(
          key: const Key('rename-box'),
          controller: _name,
          focusNode: _nameFocus,
          autofocus: true,
          onSubmitted: (_) => _endRename(save: true),
          style: TextStyle(fontSize: 14, color: c.text),
          cursorColor: c.text,
          decoration: const InputDecoration(border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero),
        ),
      ),
    );
  }
}

/// Where a cut title's card goes: just past the sidebar's right edge, level with the chat's row, kept inside the
/// window. (A title ends 46 before that edge: the row's menu button and paddings.)
Offset _rightOfRow(TooltipPositionContext p) {
  const edge = 8.0;
  final x = p.target.dx + p.targetSize.width / 2 + 46 + edge;
  final y = p.target.dy - p.tooltipSize.height / 2;
  return Offset(
    x.clamp(edge, math.max(edge, p.overlaySize.width - p.tooltipSize.width - edge)),
    y.clamp(edge, math.max(edge, p.overlaySize.height - p.tooltipSize.height - edge)),
  );
}

/// A title on one line, cut with "…" when it does not fit; then, held under the pointer a moment, a card to the right
/// of the chat shows all of it.
class CutTitle extends StatelessWidget {
  const CutTitle(this.text, {super.key, required this.full});

  final InlineSpan text;

  /// The whole title, for the card.
  final String full;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final title = Text.rich(text, maxLines: 1, overflow: TextOverflow.ellipsis);
      final painter = TextPainter(
        text: TextSpan(style: DefaultTextStyle.of(context).style, children: [text]),
        maxLines: 1,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: box.maxWidth);
      final cut = painter.didExceedMaxLines;
      painter.dispose();
      if (!cut) return title;
      final c = context.colors;
      return Tooltip(
        message: full,
        waitDuration: const Duration(milliseconds: 500),
        positionDelegate: _rightOfRow,
        constraints: const BoxConstraints(maxWidth: 380),
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        textStyle: TextStyle(fontSize: 13, height: 1.35, color: c.text),
        decoration: BoxDecoration(
          color: c.inputFill,
          border: Border.all(color: c.inputBorder),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [BoxShadow(color: c.shadow.withValues(alpha: c.shadow.a * 0.5), blurRadius: 10, offset: const Offset(0, 2))],
        ),
        child: title,
      );
    });
  }
}

/// "Delete this chat?" with Cancel and Delete; true when the user chose Delete. Delete is chosen when it opens, so
/// Enter deletes; ← chooses Cancel (then Enter cancels), → Delete again; Esc cancels.
Future<bool> _confirmDelete(BuildContext context, String title) async {
  final ok = await showDialog<bool>(context: context, builder: (context) => _DeleteBox(title: title));
  return ok ?? false;
}

class _DeleteBox extends StatefulWidget {
  const _DeleteBox({required this.title});

  final String title;

  @override
  State<_DeleteBox> createState() => _DeleteBoxState();
}

class _DeleteBoxState extends State<_DeleteBox> {
  final _cancel = FocusNode(debugLabel: 'cancel delete');
  final _delete = FocusNode(debugLabel: 'delete');

  @override
  void dispose() {
    _cancel.dispose();
    _delete.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): _cancel.requestFocus,
        const SingleActivator(LogicalKeyboardKey.arrowRight): _delete.requestFocus,
      },
      child: AlertDialog(
        backgroundColor: c.page,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        constraints: const BoxConstraints(maxWidth: 400),
        title: Text('Delete this chat?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: c.text)),
        content: Text(
          '"${widget.title}" will be deleted. This can\'t be undone.',
          style: TextStyle(fontSize: 14, height: 1.5, color: c.textSecondary),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        actions: [
          // The ring shows which one Enter chooses.
          AppButton(
            key: const Key('delete-cancel'),
            label: 'Cancel',
            focusNode: _cancel,
            ringAlways: true,
            onTap: () => Navigator.pop(context, false),
          ),
          MainButton(
            key: const Key('delete-confirm'),
            label: 'Delete',
            danger: true,
            focusNode: _delete,
            autofocus: true,
            ringAlways: true,
            onTap: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
  }
}

/// "Unpin": the outlined pin with a line across it, in the size and color of the icons around it.
class PinOffIcon extends StatelessWidget {
  const PinOffIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final size = theme.size ?? 24;
    final color = theme.color ?? DefaultTextStyle.of(context).style.color ?? Colors.black;
    return SizedBox.square(
      key: const Key('unpin-icon'),
      dimension: size,
      child: Stack(children: [
        Icon(Icons.push_pin_outlined, size: size, color: color),
        CustomPaint(size: Size.square(size), painter: _Slash(color)),
      ]),
    );
  }
}

class _Slash extends CustomPainter {
  _Slash(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    canvas.drawLine(
      Offset(s * 0.12, s * 0.12),
      Offset(s * 0.88, s * 0.88),
      Paint()
        ..color = color
        ..strokeWidth = s * 0.09
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_Slash old) => old.color != color;
}
