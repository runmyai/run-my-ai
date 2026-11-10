import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../search/chat_search.dart';
import '../state/archive_view.dart';
import '../state/chats.dart';
import '../state/folds.dart';
import '../state/prefs.dart';
import '../state/search.dart';
import '../state/section.dart';
import '../state/today.dart';
import '../theme.dart';
import 'buttons.dart';
import 'chat_list.dart';
import 'clicky.dart';
import 'look.dart';
import 'marked_text.dart';
import 'title_bar.dart';

/// The left side: the full sidebar, or a narrow bar of icons when the user hides it.
class Sidebar extends ConsumerWidget {
  const Sidebar({super.key});

  static const width = 260.0;

  /// Wider on a Mac, so Apple's three buttons fit inside it.
  static double get railWidth => isMacLook ? 76.0 : 60.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final hidden = ref.watch(prefsProvider.select((p) => p.sidebarHidden));
    return Container(
      width: hidden ? railWidth : width,
      decoration: BoxDecoration(
        color: c.sidebar,
        border: Border(right: BorderSide(color: c.border)),
      ),
      child: c.decorated
          ? Stack(
              children: [
                // Low in the sidebar, behind the list: a soft wave (Dark 2), or the logo's slashes and a fine grain
                // (Dark 3). Drawn once.
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: c.slashes ? Slashes(c.sidebar, c.isLight) : _Wave(c.sidebar, c.isLight),
                    ),
                  ),
                ),
                if (c.slashes && !c.isLight) const Positioned.fill(child: Grain()),
                hidden ? const _Rail() : const _Full(),
              ],
            )
          : hidden
          ? const _Rail()
          : const _Full(),
    );
  }
}

class _Full extends ConsumerWidget {
  const _Full();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(sectionProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;

    // The logo is part of the window's top row; on a Mac it moves just below Apple's three buttons.
    final logo = IgnorePointer(child: _Logo(dark: dark));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WindowDragArea(
          child: SizedBox(
            height: titleBarHeight,
            child: Padding(
              padding: EdgeInsets.fromLTRB(isMacLook ? macButtonsWidth : 18, 0, 12, 0),
              child: TitleRowFade(
                child: Row(
                  children: [
                    if (!isMacLook) logo,
                    const Spacer(),
                    _IconAction(
                      key: const Key('sidebar-toggle'),
                      icon: Icons.view_sidebar_outlined,
                      tooltip: 'Hide sidebar',
                      onTap: ref.read(prefsProvider.notifier).toggleSidebar,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: _FullBody(section: section, logo: isMacLook ? logo : null),
          ),
        ),
      ],
    );
  }
}

class _FullBody extends ConsumerWidget {
  const _FullBody({required this.section, this.logo});

  final Section section;

  /// Only set on a Mac, where the logo sits below the window's top row.
  final Widget? logo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final select = ref.read(sectionProvider.notifier).select;
    final searching = ref.watch(searchProvider.select((s) => s.open));
    final hasQuery = ref.watch(searchProvider.select((s) => s.open && s.text.trim().isNotEmpty));
    final kind = ref.watch(chatsProvider.select((s) => s.kind));
    final archivedCount = ref.watch(chatsProvider.select((s) => s.shownArchived.length));
    final archiveOpen = archivedCount > 0 && ref.watch(archiveViewProvider).contains(kind);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (logo != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 0, 12),
            child: Align(alignment: Alignment.centerLeft, child: logo),
          ),
        _SectionSwitch(section: section, onSelect: select),
        const SizedBox(height: 12),
        searching
            ? const _SearchBox()
            : Row(
                children: [
                  Expanded(
                    child: _Row(
                      key: const Key('new-chat'),
                      icon: Icons.add,
                      label: 'New chat',
                      onTap: () => newChat(ref),
                    ),
                  ),
                  const SizedBox(width: 4),
                  _IconAction(
                    key: const Key('search'),
                    icon: Icons.search,
                    tooltip: 'Search',
                    onTap: ref.read(searchProvider.notifier).open,
                  ),
                ],
              ),
        const SizedBox(height: 6),
        Expanded(
          child: hasQuery
              ? _SearchResults(showSelection: section.kind != null)
              : ChatList(showSelection: section.kind != null),
        ),
        const SizedBox(height: 6),
        // The archived chats of this section (only when there are some): shown in place of the list.
        if (archivedCount > 0)
          _Row(
            key: const Key('archived'),
            icon: Icons.archive_outlined,
            label: 'Archived',
            selected: archiveOpen,
            onTap: () => ref.read(archiveViewProvider.notifier).toggle(kind),
          ),
        _Row(
          key: const Key('store'),
          icon: Icons.storefront_outlined,
          label: 'Store',
          selected: section == Section.store,
          onTap: () => select(Section.store),
        ),
        _Row(
          key: const Key('engine'),
          icon: Icons.memory_outlined,
          label: 'Engine',
          selected: section == Section.engine,
          onTap: () => select(Section.engine),
        ),
        _Row(
          icon: Icons.settings_outlined,
          label: 'Settings',
          selected: section == Section.settings,
          onTap: () => select(Section.settings),
        ),
      ],
    );
  }
}

/// The hidden sidebar: one icon per action, the chat list left out.
class _Rail extends ConsumerWidget {
  const _Rail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(sectionProvider);

    final toggle = _IconAction(
      key: const Key('sidebar-toggle'),
      icon: Icons.view_sidebar_outlined,
      tooltip: 'Show sidebar',
      onTap: ref.read(prefsProvider.notifier).toggleSidebar,
    );

    return Column(
      children: [
        // Part of the window's top row; on a Mac it holds Apple's three buttons and the toggle moves below.
        WindowDragArea(
          child: SizedBox(
            height: titleBarHeight,
            width: double.infinity,
            child: isMacLook ? null : Center(child: toggle),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
            child: _RailBody(section: section, toggle: isMacLook ? toggle : null),
          ),
        ),
      ],
    );
  }
}

class _RailBody extends ConsumerWidget {
  const _RailBody({required this.section, this.toggle});

  final Section section;

  /// Only set on a Mac, where the toggle sits below the window's top row.
  final Widget? toggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final select = ref.read(sectionProvider.notifier).select;
    return Column(
      children: [
        ?toggle,
        if (toggle != null) const SizedBox(height: 10),
        _IconAction(key: const Key('new-chat'), icon: Icons.add, tooltip: 'New chat', onTap: () => newChat(ref)),
        const Spacer(),
        _IconAction(
          key: const Key('store'),
          icon: Icons.storefront_outlined,
          tooltip: 'Store',
          selected: section == Section.store,
          onTap: () => select(Section.store),
        ),
        _IconAction(
          key: const Key('engine'),
          icon: Icons.memory_outlined,
          tooltip: 'Engine',
          selected: section == Section.engine,
          onTap: () => select(Section.engine),
        ),
        _IconAction(
          icon: Icons.settings_outlined,
          tooltip: 'Settings',
          selected: section == Section.settings,
          onTap: () => select(Section.settings),
        ),
      ],
    );
  }
}

/// A new chat in the section whose chats are shown (Chat or Code).
void newChat(WidgetRef ref) {
  ref.read(sectionProvider.notifier).select(Section.of(ref.read(chatsProvider).kind));
  ref.read(chatsProvider.notifier).newChat();
}

/// A square icon button with a tooltip.
class _IconAction extends StatelessWidget {
  const _IconAction({super.key, required this.icon, required this.tooltip, required this.onTap, this.selected = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return AppIconButton(
      icon: icon,
      tooltip: tooltip,
      onTap: onTap,
      size: 36,
      chosen: selected,
      color: context.colors.sideText,
    );
  }
}

/// The search box that takes New chat's place; Esc or the × closes it.
class _SearchBox extends ConsumerStatefulWidget {
  const _SearchBox();

  @override
  ConsumerState<_SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends ConsumerState<_SearchBox> {
  late final _text = TextEditingController(text: ref.read(searchProvider).text);
  final _focus = FocusNode(debugLabel: 'search box');

  /// The search box on screen (one at most).
  static _SearchBoxState? _shown;

  @override
  void initState() {
    super.initState();
    _shown = this;
  }

  @override
  void dispose() {
    if (_shown == this) _shown = null;
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final close = ref.read(searchProvider.notifier).close;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: c.inputFill,
          border: Border.all(color: c.inputBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const SizedBox(width: 8),
            Icon(Icons.search, size: 18, color: c.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const Key('search-box'),
                controller: _text,
                focusNode: _focus,
                autofocus: true,
                onChanged: ref.read(searchProvider.notifier).setText,
                style: TextStyle(fontSize: 14, color: c.text),
                cursorColor: c.text,
                decoration: InputDecoration(
                  hintText: 'Search chats',
                  hintStyle: TextStyle(color: c.textMuted),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            AppIconButton(
              key: const Key('search-close'),
              icon: Icons.close,
              tooltip: 'Close search',
              onTap: close,
              size: 30,
              iconSize: 16,
              radius: 6,
            ),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }
}

/// Puts the cursor in the search box (if it is on screen), its text chosen, so typing replaces it.
void focusSearchBox() {
  final box = _SearchBoxState._shown;
  if (box == null || !box.mounted) return;
  box._text.selection = TextSelection(baseOffset: 0, extentOffset: box._text.text.length);
  box._focus.requestFocus();
}

/// The search results' order: the chats that are not archived, then the archived ones (each part best first).
List<ChatHit> shownHits(List<ChatHit> hits, Set<String> archived) => [
  for (final h in hits)
    if (!archived.contains(h.chatId)) h,
  for (final h in hits)
    if (archived.contains(h.chatId)) h,
];

/// What the sidebar lists, top to bottom: the search results while there is a search, else the chats (or the
/// archived ones), as [listOrder] gives them. Each with how to open it as a click does.
List<({String id, void Function() open})> sidebarOrder(WidgetRef ref) {
  final search = ref.read(searchProvider);
  final chats = ref.read(chatsProvider);
  if (search.open && search.text.trim().isNotEmpty) {
    final archived = {
      for (final c in chats.chats)
        if (c.archived) c.id,
    };
    return [
      for (final hit in shownHits(ref.read(searchResultsProvider).hits, archived))
        (id: hit.chatId, open: () => openHit(ref, hit)),
    ];
  }
  final archive = chats.shownArchived.isNotEmpty && ref.read(archiveViewProvider).contains(chats.kind);
  final order = listOrder(chats, ref.read(todayProvider), ref.read(foldsProvider)[chats.kind]!, archive: archive);
  return [
    for (final id in order)
      (
        id: id,
        open: () {
          // The section first: coming back to it may open its chat from before, which this one then replaces.
          ref.read(sectionProvider.notifier).select(Section.of(chats.byId(id)?.kind ?? chats.kind));
          ref.read(chatsProvider.notifier).open(id);
        },
      ),
  ];
}

/// Opens a search result as a click does: the chat, at its best matching message (highlighted).
void openHit(WidgetRef ref, ChatHit hit) {
  final chats = ref.read(chatsProvider);
  ref.read(sectionProvider.notifier).select(Section.of(chats.byId(hit.chatId)?.kind ?? chats.kind));
  final find = ref.read(findProvider.notifier);
  final node = hit.messageIndex;
  if (node == null) {
    ref.read(chatsProvider.notifier).open(hit.chatId);
    find.close();
  } else {
    unawaited(find.showHit(chatId: hit.chatId, query: SearchQuery.parse(ref.read(searchProvider).text), node: node));
  }
}

/// The chats that match the search, best first: the title, and under it the best matching line. While a newer
/// search runs, the last results stay; "Searching…" shows only if it takes a while.
class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.showSelection});

  final bool showSelection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final results = ref.watch(searchResultsProvider);
    final hits = results.hits;
    Widget note(String text, Key key) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
      child: Text(
        text,
        key: key,
        style: TextStyle(fontSize: 13, color: c.sideMuted),
      ),
    );
    if (hits.isEmpty) {
      if (results.slow) return note('Searching…', const Key('searching'));
      if (results.pending) return const SizedBox.shrink();
      return note('No chats match.', const Key('no-results'));
    }
    final openId = ref.watch(chatsProvider.select((s) => s.openId));
    final top = results.slow ? note('Searching…', const Key('searching')) : const SizedBox(height: 6);
    // Archived chats come after all the others, under their own heading (each part in the search's order).
    final archived = ref.watch(
      chatsProvider.select(
        (s) => {
          for (final c in s.chats)
            if (c.archived) c.id,
        },
      ),
    );
    final shown = shownHits(hits, archived);
    final firstArchived = shown.indexWhere((h) => archived.contains(h.chatId));
    // Built lazily: only the rows on screen exist.
    return ListView.builder(
      itemCount: hits.length + 1 + (firstArchived < 0 ? 0 : 1),
      itemBuilder: (context, row) {
        if (row == 0) return top;
        var at = row - 1;
        if (firstArchived >= 0 && at >= firstArchived) {
          if (at == firstArchived) {
            return Padding(
              key: const Key('archived-results'),
              padding: const EdgeInsets.fromLTRB(8, 14, 8, 4),
              child: Text('Archived', style: TextStyle(fontSize: 12, color: c.sideMuted)),
            );
          }
          at--;
        }
        final hit = shown[at];
        final i = hits.indexOf(hit);
        // A line not read yet (further down than the first results): ask for this and the next ones.
        if (hit.snippetPending) Future.microtask(() => ref.read(searchResultsProvider.notifier).needLines(i));
        return SidebarRowMark(
          key: ValueKey(hit.chatId),
          id: hit.chatId,
          child: _HitRow(hit: hit, selected: showSelection && hit.chatId == openId),
        );
      },
    );
  }
}

class _HitRow extends ConsumerWidget {
  const _HitRow({required this.hit, required this.selected});

  final ChatHit hit;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final titleStyle = TextStyle(fontSize: 14, color: selected ? c.text : c.sideText);
    final lineStyle = TextStyle(fontSize: 12.5, color: c.sideMuted);

    return Material(
      color: selected ? c.rowSelected : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: Key('hit-${hit.chatId}'),
        borderRadius: BorderRadius.circular(8),
        hoverColor: selected ? c.rowSelected : c.rowHover,
        highlightColor: c.rowPressed,
        onTap: () => openHit(ref, hit),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CutTitle(
                TextSpan(
                  style: titleStyle,
                  children: markedSpans(
                    hit.title,
                    hit.titleSpans,
                    TextStyle(color: c.text, fontWeight: FontWeight.w600),
                  ),
                ),
                full: hit.title,
              ),
              if (hit.messageIndex != null) ...[
                const SizedBox(height: 2),
                Text.rich(
                  TextSpan(
                    style: lineStyle,
                    children: [
                      // While its line is being read, the row keeps its height (no jump when it arrives).
                      TextSpan(text: hit.snippetPending ? ' ' : (hit.messageRole == Role.user ? 'You: ' : 'AI: ')),
                      ...markedSpans(
                        hit.snippet,
                        hit.snippetSpans,
                        TextStyle(color: c.sideText, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The Chat / Code switch at the top of the sidebar. The white pill slides to the section chosen (and fades out
/// while Store or Settings is shown).
class _SectionSwitch extends StatelessWidget {
  const _SectionSwitch({required this.section, required this.onSelect});

  final Section section;
  final void Function(Section) onSelect;

  static const _slide = Duration(milliseconds: 150);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget half(Section s, String label) {
      final on = section == s;
      return Expanded(
        child: Clicky(
          key: Key('section-${s.name}'),
          radius: 6,
          selected: on,
          onTap: () => onSelect(s),
          child: Container(
            height: 30,
            alignment: Alignment.center,
            color: Colors.transparent,
            child: AnimatedDefaultTextStyle(
              duration: _slide,
              style: TextStyle(fontSize: 13, color: on ? c.text : c.sideText),
              child: Text(label),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: c.switchTrack, borderRadius: BorderRadius.circular(8)),
      child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedAlign(
              key: const Key('section-pill'),
              duration: _slide,
              curve: Curves.easeOutCubic,
              alignment: section == Section.code ? Alignment.centerRight : Alignment.centerLeft,
              child: AnimatedOpacity(
                duration: _slide,
                opacity: section.kind == null ? 0 : 1,
                child: FractionallySizedBox(
                  widthFactor: 0.5,
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: c.switchOn, borderRadius: BorderRadius.circular(6)),
                  ),
                ),
              ),
            ),
          ),
          Row(children: [half(Section.chat, 'Chat'), half(Section.code, 'Code')]),
        ],
      ),
    );
  }
}

/// One clickable line in the sidebar.
class _Row extends StatelessWidget {
  const _Row({super.key, required this.label, required this.onTap, this.icon, this.selected = false});

  final IconData? icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: selected ? c.rowSelected : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        hoverColor: selected ? c.rowSelected : c.rowHover,
        highlightColor: c.rowPressed,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: selected ? c.text : c.sideText),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: selected ? c.text : c.sideText),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The logo: the mark and the name side by side, cut from the logo lockup (assets/logo/README.txt). The name is as
/// in a 30 px tall lockup and the mark 15 % bigger than there, standing on the same bottom line.
class _Logo extends StatelessWidget {
  const _Logo({required this.dark});

  final bool dark;

  // Where the two parts are in the lockup (1280 x 256 pixels): the mark 223 x 148 with its bottom at 181, the name
  // 933 x 189 from 33 down (its "y" goes below the line), 57 between them.
  static const _k = 30 / 256;
  static const _markScale = 1.15;

  @override
  Widget build(BuildContext context) {
    const markW = 223 * _k * _markScale, markH = 148 * _k * _markScale, markTop = 181 * _k - markH;
    const nameW = 933 * _k, nameH = 189 * _k, nameTop = 33 * _k, gap = 57 * _k;
    final top = min(markTop, nameTop);
    final theme = dark ? 'dark' : 'light';
    Widget part(String name, double width, double height) =>
        Image.asset('assets/logo/$name-$theme.png', width: width, height: height, filterQuality: FilterQuality.medium);
    return SizedBox(
      width: markW + gap + nameW,
      height: max(181 * _k, nameTop + nameH) - top,
      child: Stack(
        children: [
          Positioned(left: 0, top: markTop - top, child: part('mark', markW, markH)),
          Positioned(left: markW + gap, top: nameTop - top, child: part('name', nameW, nameH)),
        ],
      ),
    );
  }
}

/// A soft, silky wave low in the sidebar (Dark 2): a few broad ribbons a shade or two lighter than the sidebar's
/// black, each fading out, with a faint light line along the top of the brightest. Greys only.
class _Wave extends CustomPainter {
  _Wave(this.base, this.shaded);

  final Color base;
  final bool shaded;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // (On a light sidebar the ribbons are shades darker instead.)
    Color shade(double t, double alpha) =>
        Color.lerp(base, shaded ? Colors.black : Colors.white, t)!.withValues(alpha: alpha);
    // Each ribbon: where it rises from the left and falls to at the right (as parts of the height), how light.
    for (final (top, end, light) in [(0.70, 0.86, 0.045), (0.76, 0.80, 0.07), (0.84, 0.74, 0.05)]) {
      final path = Path()
        ..moveTo(0, h * top)
        ..cubicTo(w * 0.35, h * (top - 0.05), w * 0.65, h * (end + 0.07), w, h * end)
        ..lineTo(w, h)
        ..lineTo(0, h)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [shade(light, 0.9), shade(light * 0.3, 0.0)],
          ).createShader(Rect.fromLTWH(0, h * (top - 0.05), w, h * (1 - top + 0.05))),
      );
    }
    final line = Path()
      ..moveTo(0, h * 0.76)
      ..cubicTo(w * 0.35, h * 0.71, w * 0.65, h * 0.87, w, h * 0.80);
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(colors: [shade(0.10, 0.0), shade(0.14, 0.8), shade(0.10, 0.0)])
            .createShader(Rect.fromLTWH(0, 0, w, h)),
    );
  }

  @override
  bool shouldRepaint(_Wave old) => old.base != base || old.shaded != shaded;
}
