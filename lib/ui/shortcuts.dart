import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/chats.dart';
import '../state/prefs.dart';
import '../state/search.dart';
import '../state/section.dart';
import '../theme.dart';
import 'buttons.dart';
import 'chat_list.dart';
import 'pages/chat_page.dart';
import 'sidebar.dart';

/// On a Mac the shortcuts use Cmd where other systems use Ctrl.
final bool _mac = Platform.isMacOS;

SingleActivator _cmd(LogicalKeyboardKey key, {bool shift = false}) =>
    SingleActivator(key, control: !_mac, meta: _mac, shift: shift);

/// The app's keyboard shortcuts (the list is in [ShortcutsSheet], Ctrl+/), and typing anywhere going into the
/// message box. Put around the whole window. Keys a menu, a dialog, renaming or the search box use themselves (Esc
/// closes them, letters are typed there) are theirs first.
class AppShortcuts extends ConsumerStatefulWidget {
  const AppShortcuts({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppShortcuts> createState() => _AppShortcutsState();
}

class _AppShortcutsState extends ConsumerState<AppShortcuts> {
  final _scope = FocusScopeNode(debugLabel: 'app');

  /// The row Alt+↑ / Alt+↓ last went to (a pinned chat has two), while that chat is still the open one.
  ({String id, int occurrence})? _at;

  bool _sheetOpen = false;

  /// Where the user was before Settings (Ctrl+, there goes back to it).
  Section _beforeSettings = Section.chat;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_keepKeys);
    WidgetsBinding.instance.addPostFrameCallback((_) => _keepKeys());
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_keepKeys);
    _scope.dispose();
    super.dispose();
  }

  /// When nothing in the window has the keys (no message box on Store or Settings, a click on nothing), the window
  /// takes them, so the shortcuts still work. Not while a dialog has them.
  void _keepKeys() {
    bool lost() {
      final primary = FocusManager.instance.primaryFocus;
      return mounted && (primary == null || _scope.ancestors.contains(primary));
    }

    if (!lost()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (lost()) _scope.requestFocus();
    });
  }

  bool get _sidebarHidden => ref.read(prefsProvider).sidebarHidden;

  /// Something in a menu (a chat's ⋯ menu, the model picker) has the keys.
  static bool _inMenu() =>
      SidebarRows.menuOpen ||
      FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<MenuAnchor>() != null;

  static int _nth(List<String> ids, String id, int occurrence) {
    var seen = 0;
    for (var i = 0; i < ids.length; i++) {
      if (ids[i] == id && seen++ == occurrence) return i;
    }
    return -1;
  }

  /// Ctrl+,: Settings; in Settings, back to where the user was before (however Settings was opened).
  void _settings() {
    if (_inMenu()) return;
    final section = ref.read(sectionProvider.notifier);
    ref.read(sectionProvider) == Section.settings ? section.select(_beforeSettings) : section.select(Section.settings);
  }

  void _newChat() {
    if (_inMenu()) return;
    newChat(ref);
    WidgetsBinding.instance.addPostFrameCallback((_) => focusMessageBox());
  }

  /// Alt+↓ ([step] 1) / Alt+↑ (-1): the chat below / above the open one in the sidebar (the search results while
  /// searching, the archived chats in Archived), opened as a click does. With no chat open (or one the sidebar does
  /// not show), Alt+↓ opens the first. At either end nothing happens.
  Future<void> _step(int step) async {
    if (_inMenu()) return;
    final order = sidebarOrder(ref);
    final ids = [for (final e in order) e.id];
    final open = ref.read(chatsProvider).openId;
    var at = -1;
    if (open != null) {
      at = _nth(ids, open, _at?.id == open ? _at!.occurrence : 0);
      if (at < 0) at = _nth(ids, open, 0);
    }
    if (at < 0 && step < 0) return;
    var to = at + step;
    // A pinned chat's other row is the same chat: past it.
    while (to >= 0 && to < ids.length && ids[to] == open) {
      to += step;
    }
    if (to < 0 || to >= ids.length) return;
    final id = ids[to];
    final occurrence = ids.sublist(0, to).where((x) => x == id).length;
    _at = (id: id, occurrence: occurrence);
    order[to].open();
    if (_sidebarHidden) return;
    // Its row in sight (once the list has changed: the chat left may have been in a folded group).
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted) return;
    await SidebarRows.reveal(id, [for (final e in sidebarOrder(ref)) e.id], occurrence: occurrence, down: step > 0);
  }

  /// Ctrl+. (the open chat's menu, [menu]) and F2 (renaming it): on its row in the sidebar, shown first if hidden.
  /// Not while searching (the results have no menu) or with no chat open.
  Future<void> _onRow({required bool menu}) async {
    final id = ref.read(chatsProvider).openId;
    final search = ref.read(searchProvider);
    if (id == null || ref.read(sectionProvider).kind == null || _inMenu() || SidebarRows.renaming) return;
    if (search.open && search.text.trim().isNotEmpty) return;
    if (_sidebarHidden) {
      ref.read(prefsProvider.notifier).toggleSidebar();
      await SchedulerBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    final ids = [for (final e in sidebarOrder(ref)) e.id];
    final occurrence = _at?.id == id ? _at!.occurrence : 0;
    final row =
        await SidebarRows.reveal(id, ids, occurrence: occurrence) ??
        (occurrence == 0 ? null : await SidebarRows.reveal(id, ids));
    if (row == null || !mounted) return;
    menu ? row.menu() : row.rename();
  }

  /// Ctrl+K: the search box (the sidebar shown first if hidden), its text chosen; pressed again, the search closes
  /// (as with its ✕) and the cursor goes back to the message box.
  Future<void> _search() async {
    if (_inMenu()) return;
    if (ref.read(searchProvider).open) {
      ref.read(searchProvider.notifier).close();
      await SchedulerBinding.instance.endOfFrame;
      if (mounted) focusMessageBox();
      return;
    }
    if (_sidebarHidden) ref.read(prefsProvider.notifier).toggleSidebar();
    ref.read(searchProvider.notifier).open();
    await SchedulerBinding.instance.endOfFrame;
    if (mounted) focusSearchBox();
  }

  /// Esc, when nothing that closes with it has the keys: closes the search, else the open chat's match highlights,
  /// else cancels the editing of a message, else stops the reply being written in the open chat. One at a time.
  void _escape() {
    if (_inMenu()) return;
    if (ref.read(searchProvider).open) return ref.read(searchProvider.notifier).close();
    final chats = ref.read(chatsProvider);
    final inChat = ref.read(sectionProvider).kind != null;
    final find = ref.read(findProvider);
    if (inChat && find != null && find.chatId == chats.openId) return ref.read(findProvider.notifier).close();
    if (inChat && chats.editing != null) return ref.read(chatsProvider.notifier).cancelEdit();
    if (inChat && chats.replyingId != null && chats.replyingId == chats.openId) ref.read(chatsProvider.notifier).stop();
  }

  Future<void> _sheet() async {
    if (_sheetOpen || _inMenu()) return;
    _sheetOpen = true;
    await showDialog<void>(context: context, builder: (_) => const ShortcutsSheet());
    _sheetOpen = false;
  }

  /// A letter, number or sign typed while no text box has the cursor goes into the message box (if it is on
  /// screen), and the cursor with it. Not with Ctrl, Alt or Cmd held; not in a menu; and a Space while a button has
  /// the keys presses the button.
  KeyEventResult _typed(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final text = event.character;
    if (text == null || text.isEmpty || text.runes.any((r) => r < 0x20 || r == 0x7f)) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) return KeyEventResult.ignored;
    final focused = FocusManager.instance.primaryFocus;
    final editable = focused?.context?.findAncestorWidgetOfExactType<EditableText>();
    if (editable != null && !editable.readOnly) return KeyEventResult.ignored;
    if (_inMenu()) return KeyEventResult.ignored;
    if (text == ' ' && editable == null && focused != _scope) return KeyEventResult.ignored;
    return typeIntoMessageBox(text) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sectionProvider, (before, now) {
      if (now == Section.settings && before != null && before != Section.settings) _beforeSettings = before;
    });
    final prefs = ref.read(prefsProvider.notifier);
    return CallbackShortcuts(
      bindings: {
        _cmd(LogicalKeyboardKey.keyN): _newChat,
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () => _step(-1),
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true, shift: true): () {
          if (!_inMenu()) stepBookmark(-1);
        },
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true, shift: true): () {
          if (!_inMenu()) stepBookmark(1);
        },
        _cmd(LogicalKeyboardKey.keyK): _search,
        _cmd(LogicalKeyboardKey.period): () => _onRow(menu: true),
        const SingleActivator(LogicalKeyboardKey.f2): () => _onRow(menu: false),
        const SingleActivator(LogicalKeyboardKey.escape): _escape,
        _cmd(LogicalKeyboardKey.keyB): () {
          if (!_inMenu()) prefs.toggleSidebar();
        },
        _cmd(LogicalKeyboardKey.comma): _settings,
        for (final key in [LogicalKeyboardKey.equal, LogicalKeyboardKey.add, LogicalKeyboardKey.numpadAdd]) ...{
          _cmd(key): () => prefs.stepTextScale(1),
          _cmd(key, shift: true): () => prefs.stepTextScale(1),
        },
        _cmd(LogicalKeyboardKey.minus): () => prefs.stepTextScale(-1),
        _cmd(LogicalKeyboardKey.numpadSubtract): () => prefs.stepTextScale(-1),
        _cmd(LogicalKeyboardKey.digit0): () => prefs.stepTextScale(0),
        _cmd(LogicalKeyboardKey.numpad0): () => prefs.stepTextScale(0),
        _cmd(LogicalKeyboardKey.slash): _sheet,
        _cmd(LogicalKeyboardKey.slash, shift: true): _sheet,
      },
      child: FocusScope(node: _scope, onKeyEvent: _typed, child: widget.child),
    );
  }
}

/// The list of the keyboard shortcuts (Ctrl+/): one column, each shortcut on a row of its own with its keys at the
/// right; it scrolls when the window is too low for all of it. Esc, a click outside, the ✕ or Ctrl+/ again closes it.
class ShortcutsSheet extends StatelessWidget {
  const ShortcutsSheet({super.key});

  static final _ctrl = _mac ? '⌘' : 'Ctrl';
  static final _alt = _mac ? '⌥' : 'Alt';

  /// The groups and their rows: the keys (each list one way to press it), what it does, a note under it.
  // dart format off
  static final _groups = <(String, List<(List<List<String>>, String, String?)>)>[
    ('Chats', [
      ([[_ctrl, 'N']], 'New chat', null),
      ([[_alt, '↑'], [_alt, '↓']], 'Previous / next chat', null),
      ([[_alt, 'Shift', '↑'], [_alt, 'Shift', '↓']], 'Previous / next bookmark', null),
      ([[_ctrl, 'K']], 'Search chats', 'again to close the search'),
      ([[_ctrl, '.']], 'Chat menu', 'then R, P, A or D'),
      ([['F2']], 'Rename current chat', null),
    ]),
    ('Writing', [
      ([['Enter']], 'Send', null),
      ([['Shift', 'Enter']], 'New line', null),
      ([['Ctrl', 'Enter']], 'While a reply is written: send after it', null),
      ([['Esc']], 'Stop generating response, or cancel editing a message', null),
    ]),
    ('App', [
      ([[_ctrl, 'B']], 'Show / hide the sidebar', null),
      ([[_ctrl, ',']], 'Settings', 'again to go back'),
      ([[_ctrl, '=']], 'Bigger text', null),
      ([[_ctrl, '-']], 'Smaller text', null),
      ([[_ctrl, '0']], 'Normal text size', null),
      ([[_ctrl, '/']], 'Shortcuts list', null),
    ]),
  ];
  // dart format on

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget key(String label) => Container(
      constraints: const BoxConstraints(minWidth: 28),
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: c.inputFill,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.inputBorder),
        // A little deeper at the bottom, like a key.
        boxShadow: [BoxShadow(color: c.inputBorder, offset: const Offset(0, 1))],
      ),
      alignment: Alignment.center,
      child: Text(label, style: TextStyle(fontSize: 13, height: 1, color: c.text)),
    );
    Widget keys(List<List<String>> ways) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, way) in ways.indexed) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('/', style: TextStyle(fontSize: 13, color: c.textMuted)),
            ),
          for (final (j, k) in way.indexed) ...[if (j > 0) const SizedBox(width: 5), key(k)],
        ],
      ],
    );
    Widget row((List<List<String>>, String, String?) r, {required bool last}) {
      final (ways, what, note) = r;
      return Container(
        constraints: const BoxConstraints(minHeight: 56),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: c.border.withValues(alpha: c.border.a * 0.6))),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(what, style: TextStyle(fontSize: 14.5, color: c.text)),
                  if (note != null) ...[
                    const SizedBox(height: 3),
                    Text(note, style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 16),
            keys(ways),
          ],
        ),
      );
    }

    return CallbackShortcuts(
      bindings: {
        _cmd(LogicalKeyboardKey.slash): () => Navigator.pop(context),
        _cmd(LogicalKeyboardKey.slash, shift: true): () => Navigator.pop(context),
      },
      // Holds the keys (for Ctrl+/), without showing a choice on any button.
      child: Focus(
        autofocus: true,
        child: Dialog(
          key: const Key('shortcuts-sheet'),
          backgroundColor: c.page,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 22, 18, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Keyboard shortcuts',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: c.text),
                        ),
                      ),
                      AppIconButton(
                        key: const Key('shortcuts-close'),
                        icon: Icons.close,
                        tooltip: 'Close',
                        onTap: () => Navigator.pop(context),
                        size: 32,
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(32, 8, 32, 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, (heading, rows)) in _groups.indexed) ...[
                          Padding(
                            padding: EdgeInsets.only(top: i == 0 ? 4 : 32, bottom: 4),
                            child: Text(
                              heading,
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textSecondary),
                            ),
                          ),
                          for (final (j, r) in rows.indexed) row(r, last: j == rows.length - 1),
                        ],
                        const SizedBox(height: 28),
                        Text(
                          'Typing anywhere goes into the message box.',
                          style: TextStyle(fontSize: 12.5, color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
