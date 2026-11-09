import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/motion.dart';
import '../../state/prefs.dart';
import '../../system/chime.dart';
import '../../theme.dart';
import '../menu_panel.dart';

/// Settings: the theme (two menus: Run My AI, Silk or Plain, then Light or Dark - Plain's are Dusk and Espresso), saved; Reply motion, two buttons to show the difference
/// smoothing makes (Smooth, as replies normally move, and Raw, with none), until the app is restarted; and the
/// sound when a reply finishes.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final motion = ref.watch(motionProvider);
    void set(Motion m) => ref.read(motionProvider.notifier).set(m);
    final prefs = ref.watch(prefsProvider);
    final notifier = ref.read(prefsProvider.notifier);
    // The theme on screen (before one is picked, the default for the computer's light or dark): its family and side.
    final dark = Theme.of(context).brightness == Brightness.dark;
    final family = _families.firstWhere((f) => dark ? f.dark == prefs.darkStyle : f.light == prefs.lightStyle);
    void pick(_Family f, {required bool dark}) =>
        notifier.setTheme(dark ? ThemeMode.dark : ThemeMode.light, darkStyle: f.dark, lightStyle: f.light);
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 40),
      children: [
        Text(
          'Settings',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: c.text),
        ),
        const SizedBox(height: 24),
        Text(
          'Theme',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.text),
        ),
        const SizedBox(height: 12),
        // Two menus: the family, then its light or dark side (switching the family keeps the side).
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Menu(
              id: 'theme-family',
              label: family.name,
              items: [
                for (final f in _families)
                  (id: 'theme-family-${f.light}', label: f.name, chosen: f == family, onTap: () => pick(f, dark: dark)),
              ],
            ),
            _Menu(
              id: 'theme-side',
              label: dark ? family.darkName : family.lightName,
              items: [
                (
                  id: 'theme-side-light',
                  label: family.lightName,
                  chosen: !dark,
                  onTap: () => pick(family, dark: false),
                ),
                (id: 'theme-side-dark', label: family.darkName, chosen: dark, onTap: () => pick(family, dark: true)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 28),
        Text(
          'Reply motion',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.text),
        ),
        const SizedBox(height: 2),
        Text(
          'How a reply comes onto the screen while it is being written.',
          style: TextStyle(fontSize: 13, color: c.textSecondary),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            _Choice(
              id: 'motion-smooth',
              label: 'Smooth',
              chosen: motion == smoothMotion,
              onTap: () => set(smoothMotion),
            ),
            _Choice(id: 'motion-raw', label: 'Raw', chosen: motion == rawMotion, onTap: () => set(rawMotion)),
          ],
        ),
        const SizedBox(height: 28),
        const _Sound(),
      ],
    );
  }
}

/// The sound when a reply finishes: on or off (the same as the bell in the chat's top row), and which sound: the
/// app's own, or a file the user chose (WAV, MP3, FLAC or OGG), with Play to hear it.
class _Sound extends ConsumerStatefulWidget {
  const _Sound();

  @override
  ConsumerState<_Sound> createState() => _SoundState();
}

class _SoundState extends ConsumerState<_Sound> {
  /// The last file chosen could not be played.
  String? _error;

  Future<void> _choose() async {
    try {
      await ref.read(chimeProvider).choose();
      if (mounted) setState(() => _error = null);
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on FileSystemException {
      if (mounted) setState(() => _error = 'That file could not be copied.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final prefs = ref.watch(prefsProvider);
    final chime = ref.read(chimeProvider);
    final notifier = ref.read(prefsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Notification Sound',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.text),
        ),
        const SizedBox(height: 2),
        Text('A sound when a response finishes.', style: TextStyle(fontSize: 13, color: c.textSecondary)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            _Choice(id: 'sound-on', label: 'On', chosen: prefs.bell, onTap: () => notifier.setBell(true)),
            _Choice(id: 'sound-off', label: 'Off', chosen: !prefs.bell, onTap: () => notifier.setBell(false)),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'Sound: ',
                      style: TextStyle(color: c.textSecondary),
                    ),
                    TextSpan(
                      text: prefs.soundName ?? 'Default',
                      style: TextStyle(color: c.text),
                    ),
                  ],
                ),
                key: const Key('sound-name'),
                style: const TextStyle(fontSize: 13.5),
              ),
            ),
            _Choice(id: 'sound-play', label: '▶  Play', chosen: false, onTap: chime.play),
            _Choice(id: 'sound-choose', label: 'Choose file…', chosen: false, onTap: _choose),
            if (prefs.soundFile != null)
              _Choice(
                id: 'sound-reset',
                label: 'Reset',
                chosen: false,
                onTap: () {
                  chime.reset();
                  setState(() => _error = null);
                },
              ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              key: const Key('sound-error'),
              style: TextStyle(fontSize: 13, color: c.danger),
            ),
          ),
      ],
    );
  }
}

/// A theme family: its name, its light and dark themes (as saved in the prefs) and their names in the side menu.
typedef _Family = ({String name, String light, String dark, String lightName, String darkName});

const List<_Family> _families = [
  (name: 'Run My AI', light: 'light', dark: 'dark3', lightName: 'Light', darkName: 'Dark'),
  (name: 'Silk', light: 'silklight', dark: 'dark2', lightName: 'Light', darkName: 'Dark'),
  (name: 'Plain', light: 'dusk', dark: 'dark', lightName: 'Dusk', darkName: 'Espresso'),
];

/// A button showing the chosen [label] with a small arrow; a click opens its [items] (the chosen one ticked).
class _Menu extends StatelessWidget {
  const _Menu({required this.id, required this.label, required this.items});

  final String id;
  final String label;
  final List<({String id, String label, bool chosen, VoidCallback onTap})> items;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MenuAnchor(
      style: bareMenuStyle,
      clipBehavior: Clip.none,
      menuChildren: [
        MenuPanel(
          color: c.inputFill,
          border: c.inputBorder,
          elevation: 2,
          shadowColor: Theme.of(context).shadowColor,
          padding: const EdgeInsets.symmetric(vertical: 6),
          children: [
            for (final item in items)
              MenuItemButton(
                key: Key(item.id),
                onPressed: item.onTap,
                trailingIcon: item.chosen ? Icon(Icons.check, size: 16, color: c.text) : null,
                child: SizedBox(
                  width: 110,
                  child: Text(item.label, style: TextStyle(fontSize: 13, color: c.text)),
                ),
              ),
          ],
        ),
      ],
      builder: (context, menu, _) => GestureDetector(
        key: Key(id),
        onTap: () => menu.isOpen ? menu.close() : menu.open(),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
            decoration: BoxDecoration(
              color: menu.isOpen ? c.selected : Colors.transparent,
              border: Border.all(color: c.inputBorder),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: TextStyle(fontSize: 13, color: c.text)),
                const SizedBox(width: 6),
                Icon(Icons.keyboard_arrow_down, size: 16, color: c.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({required this.id, required this.label, required this.chosen, required this.onTap});

  final String id;
  final String label;
  final bool chosen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      key: Key(id),
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          decoration: BoxDecoration(
            color: chosen ? c.selected : Colors.transparent,
            border: Border.all(color: chosen ? c.text.withValues(alpha: 0.35) : c.inputBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label, style: TextStyle(fontSize: 13, color: chosen ? c.text : c.textSecondary)),
        ),
      ),
    );
  }
}
