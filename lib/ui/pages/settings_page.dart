import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../dev/dev_build.dart';
import '../../state/motion.dart';
import '../../backend/backend.dart';
import '../../state/prefs.dart';
import '../../state/library.dart';
import '../../state/providers.dart';
import '../../system/chime.dart';
import '../../theme.dart';
import '../benchmark/fold.dart';
import '../buttons.dart';
import '../context_settings.dart';
import '../settings/feedback_section.dart';
import '../settings/privacy_section.dart';
import '../menu_panel.dart';
import '../settings/folders_section.dart';
import '../settings/setting_name.dart';
import 'about_page.dart';

/// Settings: the theme (System, Light or Dark; the developer's build also has the other theme families, reply motion and
/// the speed's look), the sound when a reply finishes, the graphics card memory left free, the folders (with the saved
/// chat states' disk limit in their row), the KV cache type for each context length, and a button that opens About in
/// place of the settings. Each setting's description shows as a tooltip on its name; Folders is a drop-down, closed at
/// first.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  var _about = false;

  @override
  Widget build(BuildContext context) => _about
      ? AboutPage(key: const Key('about-page'), onBack: () => setState(() => _about = false))
      : _SettingsList(onAbout: () => setState(() => _about = true));
}

class _SettingsList extends ConsumerWidget {
  const _SettingsList({required this.onAbout});

  final VoidCallback onAbout;

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
        const SettingName('Theme'),
        const SizedBox(height: 12),
        if (!devBuild)
          Align(
            alignment: Alignment.centerLeft,
            child: _Menu(
              id: 'theme-mode',
              label: switch (prefs.theme) {
                ThemeMode.system => 'System',
                ThemeMode.light => 'Light',
                ThemeMode.dark => 'Dark',
              },
              items: [
                for (final (mode, label) in const [
                  (ThemeMode.system, 'System'),
                  (ThemeMode.light, 'Light'),
                  (ThemeMode.dark, 'Dark'),
                ])
                  (
                    id: 'theme-mode-${mode.name}',
                    label: label,
                    chosen: prefs.theme == mode,
                    onTap: () =>
                        notifier.setTheme(mode, darkStyle: _families.first.dark, lightStyle: _families.first.light),
                  ),
              ],
            ),
          )
        else
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
                    (
                      id: 'theme-family-${f.light}',
                      label: f.name,
                      chosen: f == family,
                      onTap: () => pick(f, dark: dark),
                    ),
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
        if (devBuild) ...[
          const SizedBox(height: 28),
          const SettingName(
            'Reply motion',
            description: 'How a reply comes onto the screen while it is being written.',
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
          const SettingName('Generation speed', description: 'How the speed under a reply looks.'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              _Choice(
                id: 'speed-normal',
                label: 'Normal',
                chosen: !prefs.speedHighlighted,
                onTap: () => notifier.setSpeedHighlighted(false),
              ),
              _Choice(
                id: 'speed-highlighted',
                label: 'Highlighted',
                chosen: prefs.speedHighlighted,
                onTap: () => notifier.setSpeedHighlighted(true),
              ),
            ],
          ),
        ],
        const SizedBox(height: 28),
        const _Sound(),
        const SizedBox(height: 28),
        const _VramHeadroom(),
        const SizedBox(height: 28),
        Fold(title: 'Folders', titleStyle: settingsFoldTitle(c), tooltip: foldersAbout, child: const FoldersSection()),
        const SizedBox(height: 28),
        const _Context(),
        const SizedBox(height: 28),
        const FeedbackSection(),
        const SizedBox(height: 28),
        const SettingName('Credits'),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: AppButton(
            key: const Key('about-link'),
            label: 'About Run My AI',
            trailingIcon: Icons.chevron_right,
            onTap: onAbout,
          ),
        ),
        const SizedBox(height: 40),
        const PrivacySection(),
      ],
    );
  }
}

/// The graphics card memory (VRAM) left free for the desktop and other apps while a model runs: one row per card the
/// engine can use (the same for every model).
class _VramHeadroom extends ConsumerWidget {
  const _VramHeadroom();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backend = ref.watch(backendProvider);
    if (backend is! TuneControl) return const SizedBox.shrink();
    final tune = backend as TuneControl;
    // (The cards are read again when a tune ends.)
    return ValueListenableBuilder<String?>(
      valueListenable: tune.tuning,
      builder: (context, _, _) {
        final cards = tune.cards;
        return cards.isEmpty || tune.sharesRam ? const SizedBox.shrink() : _section(context.colors, cards);
      },
    );
  }

  static String _gb(int mib) {
    final gb = (mib / 1024).toStringAsFixed(1);
    return '${gb.endsWith('.0') ? gb.substring(0, gb.length - 2) : gb} GB';
  }

  Widget _section(AppColors c, List<({String key, String name, String desc, int mib})> cards) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingName(
          'VRAM headroom',
          size: 14,
          description: 'Graphics card memory (VRAM) left free for your desktop and other apps, so they have room to grow while a model runs. A change applies the next time the model loads.',
        ),
        for (final card in cards) ...[
          const SizedBox(height: 12),
          Text(
            [
              if (card.desc.isNotEmpty) card.desc else if (card.name.isEmpty) 'Graphics card',
              if (card.name.isNotEmpty) card.name,
              _gb(card.mib),
            ].join(', '),
            key: Key('vram-card-${card.key}'),
            style: TextStyle(fontSize: 13, color: c.text),
          ),
          const SizedBox(height: 6),
          VramHeadroomInput(card: card.key),
        ],
      ],
    ),
  );
}

/// The KV cache quantization picker: the type the shown model's context cache is stored in, for each context length.
class _Context extends ConsumerWidget {
  const _Context();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final entry = ref.watch(shownModelProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingName(
          'KV cache quantization',
          description: 'How the context cache (KV cache) is stored at each context length: a smaller type uses less memory. A change applies the next time the model loads at that length.',
        ),
        const SizedBox(height: 12),
        if (entry == null)
          Text('Download a model from the Store first.', style: TextStyle(fontSize: 13, color: c.textMuted))
        else
          ContextSettings(entry: entry),
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
        const SettingName('Notification Sound', description: 'A sound when a response finishes.'),
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
      builder: (context, menu, _) => OptionPill(
        key: Key(id),
        label: label,
        chosen: menu.isOpen,
        trailingIcon: Icons.keyboard_arrow_down,
        padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
        onTap: () => menu.isOpen ? menu.close() : menu.open(),
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
    return OptionPill(
      key: Key(id),
      label: label,
      chosen: chosen,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      onTap: onTap,
    );
  }
}
