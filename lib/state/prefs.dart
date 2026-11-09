import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/storage.dart';
import 'providers.dart';

class Prefs {
  const Prefs({
    this.theme = ThemeMode.system,
    this.darkStyle = 'dark3',
    this.lightStyle = 'light',
    this.sidebarHidden = false,
    this.textScale = 1,
    this.bell = true,
    this.soundName,
    this.soundFile,
  });

  /// System until the user picks one in Settings: then Run My AI Dark, unless the computer is set to light (see
  /// lib/system/appearance.dart).
  final ThemeMode theme;

  /// Which dark: "dark3" (Run My AI Dark, the app's own), "dark2" (Silk) or "dark" (Espresso); saved as the theme
  /// itself when one is picked.
  final String darkStyle;

  /// Which light: "light" (Run My AI Light, the app's own), "silklight" or "dusk"; saved as the theme itself when
  /// one is picked.
  final String lightStyle;
  final bool sidebarHidden;

  /// How big the text is: one of [textScales], 1 is normal.
  final double textScale;

  /// A sound plays when a reply finishes.
  final bool bell;

  /// The user's own sound for it: the chosen file's name, and its copy (relative to the data folder); null: the
  /// app's own.
  final String? soundName;
  final String? soundFile;

  /// The text sizes Ctrl+= and Ctrl+- step through.
  static const textScales = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4];

  Prefs copyWith({
    ThemeMode? theme,
    String? darkStyle,
    String? lightStyle,
    bool? sidebarHidden,
    double? textScale,
    bool? bell,
    ({String? name, String? file})? sound,
  }) => Prefs(
    theme: theme ?? this.theme,
    darkStyle: darkStyle ?? this.darkStyle,
    lightStyle: lightStyle ?? this.lightStyle,
    sidebarHidden: sidebarHidden ?? this.sidebarHidden,
    textScale: textScale ?? this.textScale,
    bell: bell ?? this.bell,
    soundName: sound != null ? sound.name : soundName,
    soundFile: sound != null ? sound.file : soundFile,
  );
}

/// The theme, the sidebar's shown / hidden state, the text size and the bell. Saved to settings.json on every change.
class PrefsNotifier extends Notifier<Prefs> {
  @override
  Prefs build() {
    final saved = ref.read(storageProvider).readPrefs();
    return Prefs(
      theme: _darks.contains(saved.theme) || saved.theme.startsWith('dpick')
          ? ThemeMode.dark
          : _lights.contains(saved.theme) || saved.theme.startsWith('pick')
          ? ThemeMode.light
          : ThemeMode.values.where((m) => m.name == saved.theme).firstOrNull ?? ThemeMode.system,
      // ("mist" and "stone" were themes once, now gone: Run My AI Light.)
      // ("pick1" ... were trials for the lights' colours: Run My AI Light.)
      lightStyle: saved.theme == 'silklight' || saved.theme == 'dusk' ? saved.theme : 'light',
      // ("dark4" and "dpick1" ... were trials, now gone: Run My AI Dark.)
      darkStyle: switch (saved.theme) {
        'dark' || 'dark2' || 'dark3' => saved.theme,
        _ => 'dark3',
      },
      sidebarHidden: saved.sidebarHidden,
      // (A size saved by hand outside the steps goes to the nearest one.)
      textScale: Prefs.textScales.reduce((a, b) => (a - saved.textScale).abs() <= (b - saved.textScale).abs() ? a : b),
      bell: saved.bell,
      soundName: saved.soundName,
      soundFile: saved.soundFile,
    );
  }

  /// The other darks, saved as the theme itself ("dark4": a trial, now Run My AI Dark).
  static const _darks = {'dark2', 'dark3', 'dark4'};

  /// The lights, saved as the theme itself ("light": the old Light, now Run My AI Light).
  static const _lights = {'light', 'silklight', 'dusk', 'mist', 'stone'};

  /// The theme picked in Settings ([darkStyle] / [lightStyle]: which dark / light, see [Prefs.darkStyle]).
  void setTheme(ThemeMode theme, {String darkStyle = 'dark', String lightStyle = 'light'}) =>
      _save(state.copyWith(theme: theme, darkStyle: darkStyle, lightStyle: lightStyle));

  void toggleSidebar() => _save(state.copyWith(sidebarHidden: !state.sidebarHidden));

  void toggleBell() => _save(state.copyWith(bell: !state.bell));

  void setBell(bool on) => _save(state.copyWith(bell: on));

  /// The user's own reply-finished sound ([file] relative to the data folder), or (both null) the app's own.
  void setSound(String? name, String? file) => _save(state.copyWith(sound: (name: name, file: file)));

  /// The text one step bigger ([step] 1) or smaller (-1), up to the biggest or smallest; [step] 0: normal.
  void stepTextScale(int step) {
    const scales = Prefs.textScales;
    final at = scales.indexOf(state.textScale);
    final to = step == 0 ? 1.0 : scales[(at + step).clamp(0, scales.length - 1)];
    if (to != state.textScale) _save(state.copyWith(textScale: to));
  }

  void _save(Prefs prefs) {
    state = prefs;
    ref
        .read(storageProvider)
        .writePrefs(
          PrefsData(
            theme: switch (prefs.theme) {
              ThemeMode.dark => prefs.darkStyle,
              ThemeMode.light => prefs.lightStyle,
              ThemeMode.system => 'system',
            },
            sidebarHidden: prefs.sidebarHidden,
            textScale: prefs.textScale,
            bell: prefs.bell,
            soundName: prefs.soundName,
            soundFile: prefs.soundFile,
          ),
        );
  }
}

final prefsProvider = NotifierProvider<PrefsNotifier, Prefs>(PrefsNotifier.new);
