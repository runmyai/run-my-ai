import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/prefs.dart';
import '../state/section.dart';
import '../theme.dart';
import '../window/app_window.dart';
import 'buttons.dart';
import 'dev_speed_control.dart';
import 'model_picker.dart';
import 'pages/chat_page.dart';
import 'pages/settings_page.dart';
import 'pages/engine_page.dart';
import 'pages/simple_pages.dart';
import 'pages/store_page.dart';
import 'serve_panel.dart';
import 'shortcuts.dart';
import 'sidebar.dart';
import 'title_bar.dart';

/// The whole window: the sidebar on the left, the chosen section on the right, and no system title bar.
class Shell extends ConsumerWidget {
  const Shell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    // How much the soft light brightens the page (more on a light page, where a small step does not show).
    final glow = c.isLight ? 0.3 : 0.045;
    final section = ref.watch(sectionProvider);
    final page = switch (section) {
      Section.chat => const ChatPage(),
      Section.code => const CodePage(),
      Section.store => const StorePage(),
      Section.engine => const EnginePage(),
      Section.settings => const SettingsPage(),
    };
    return AppShortcuts(
      child: Scaffold(
        body: Stack(
          children: [
            Row(
              children: [
                const Sidebar(),
                Expanded(
                  // The section lies on the sidebar: a faint shadow along its left edge.
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: c.page,
                      // Dark 2 and 3: a soft light low on the page, fading to black above it.
                      // The top stays the page's own colour (the conversation's top edge is covered with it).
                      gradient: switch (c.look) {
                        // Dark 2: a round glow around the message box.
                        DarkLook.silk => RadialGradient(
                          center: const Alignment(0.0, 1.4),
                          radius: 1.3,
                          colors: [Color.lerp(c.page, Colors.white, glow)!, c.page],
                        ),
                        // Dark 3: light rising straight up from the bottom edge, gone by the middle; on a dark
                        // page half as bright and lower, so the black stays deep.
                        DarkLook.slashes => LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            c.page,
                            c.page,
                            Color.lerp(c.page, Colors.white, (c.isLight ? glow : glow / 2) / 3)!,
                            Color.lerp(c.page, Colors.white, c.isLight ? glow : glow / 2)!,
                          ],
                          stops: c.isLight ? const [0, 0.45, 0.72, 1] : const [0, 0.6, 0.82, 1],
                        ),
                        DarkLook.flat => null,
                      },
                      boxShadow: [BoxShadow(color: c.shadow.withValues(alpha: c.shadow.a * 0.5), blurRadius: 10)],
                    ),
                    child: Stack(
                      children: [
                        Column(
                          children: [
                            _PageTopRow(showPicker: section == Section.chat),
                            Expanded(child: page),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (isMacLook && lookIsPreview) const Positioned(left: 0, top: 0, child: MacButtonsPreview()),
          ],
        ),
      ),
    );
  }
}

/// The page's part of the window's top row: the model picker and the search matches bar (in Chat), and the window
/// buttons.
class _PageTopRow extends StatelessWidget {
  const _PageTopRow({required this.showPicker});

  final bool showPicker;

  @override
  Widget build(BuildContext context) {
    return WindowDragArea(
      child: SizedBox(
        height: titleBarHeight,
        child: TitleRowFade(
          child: Row(
            children: [
              if (showPicker) const Padding(padding: EdgeInsets.only(left: 16), child: ModelPicker()),
              // The stand-in backend's reply speed (a test control; not there with a real engine), in the free room.
              if (showPicker)
                const Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(padding: EdgeInsets.only(left: 12), child: DevSpeedControl()),
                  ),
                )
              else
                const Spacer(),
              if (showPicker) const Padding(padding: EdgeInsets.only(right: 12), child: FindBar()),
              const Padding(padding: EdgeInsets.only(right: 8), child: ServeButton()),
              const Padding(padding: EdgeInsets.only(right: 8), child: _Bell()),
              if (!isMacLook) const WindowButtons() else const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bell: on, a sound plays each time a reply finishes (lib/system/chime.dart); a click turns it off or on. Under
/// the pointer it lights up like the window buttons beside it (a soft square behind it, the icon brighter).
class _Bell extends ConsumerWidget {
  const _Bell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(prefsProvider.select((p) => p.bell));
    return AppIconButton(
      key: const Key('bell'),
      icon: on ? Icons.notifications_none_rounded : Icons.notifications_off_outlined,
      tooltip: on ? 'Sound when a reply finishes: on' : 'Sound when a reply finishes: off',
      onTap: ref.read(prefsProvider.notifier).toggleBell,
      size: 32,
    );
  }
}
