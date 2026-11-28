import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/storage.dart';
import '../dev/dev_build.dart';
import '../engine/commands.dart';
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
    this.thinking = false,
    this.engineFolder,
    this.speedHighlighted = false,
    this.stateLimitGiB = PrefsData.defaultStateLimitGiB,
    this.shareBenchmarks = true,
    this.vramHeadroomGiB,
    this.vramHeadroom = const {},
    this.communityStep = 0,
    this.starReplies = 0,
    this.starCardClosed = false,
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

  /// A model that can choose thinks before it answers. A change applies from the next reply.
  final bool thinking;

  /// The folder the engine is in; null: where it is by default.
  final String? engineFolder;

  /// The speed under a reply stands out (blue and bold) instead of looking like normal text.
  final bool speedHighlighted;

  /// The most the chats' saved states may take on the disk.
  final double stateLimitGiB;

  /// The benchmark numbers (the hardware and the speeds, never a chat) may be shared.
  final bool shareBenchmarks;

  /// The value older versions saved for all cards: the one for a card that has none of its own (null: the default).
  final double? vramHeadroomGiB;

  /// The graphics card memory (VRAM) the engine leaves free on each card, by [cardKeys].
  final Map<String, double> vramHeadroom;

  /// The line under the message box: 0 GitHub, 1 Discord, 2 done (see [PrefsData.communityStep]).
  final int communityStep;

  /// Finished replies counted toward the star card (see [starCardAfter]), and whether it was closed for good.
  final int starReplies;
  final bool starCardClosed;

  /// What the engine is started with.
  VramHeadroom get vramHeadroomSetting =>
      VramHeadroom(byCard: vramHeadroom, others: vramHeadroomGiB ?? defaultVramHeadroomGiB);

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
    bool? thinking,
    String? Function()? engineFolder,
    bool? speedHighlighted,
    double? stateLimitGiB,
    bool? shareBenchmarks,
    Map<String, double>? vramHeadroom,
    int? communityStep,
    int? starReplies,
    bool? starCardClosed,
  }) => Prefs(
    theme: theme ?? this.theme,
    darkStyle: darkStyle ?? this.darkStyle,
    lightStyle: lightStyle ?? this.lightStyle,
    sidebarHidden: sidebarHidden ?? this.sidebarHidden,
    textScale: textScale ?? this.textScale,
    bell: bell ?? this.bell,
    soundName: sound != null ? sound.name : soundName,
    soundFile: sound != null ? sound.file : soundFile,
    thinking: thinking ?? this.thinking,
    engineFolder: engineFolder != null ? engineFolder() : this.engineFolder,
    speedHighlighted: speedHighlighted ?? this.speedHighlighted,
    stateLimitGiB: stateLimitGiB ?? this.stateLimitGiB,
    shareBenchmarks: shareBenchmarks ?? this.shareBenchmarks,
    vramHeadroomGiB: vramHeadroomGiB,
    vramHeadroom: vramHeadroom ?? this.vramHeadroom,
    communityStep: communityStep ?? this.communityStep,
    starReplies: starReplies ?? this.starReplies,
    starCardClosed: starCardClosed ?? this.starCardClosed,
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
      // (The shipped app has only Run My AI Light and Dark; the other families are the developer's build's.)
      lightStyle: devBuild && (saved.theme == 'silklight' || saved.theme == 'dusk') ? saved.theme : 'light',
      // ("dark4" and "dpick1" ... were trials, now gone: Run My AI Dark.)
      darkStyle: switch (saved.theme) {
        'dark' || 'dark2' when devBuild => saved.theme,
        _ => 'dark3',
      },
      sidebarHidden: saved.sidebarHidden,
      // (A size saved by hand outside the steps goes to the nearest one.)
      textScale: Prefs.textScales.reduce((a, b) => (a - saved.textScale).abs() <= (b - saved.textScale).abs() ? a : b),
      bell: saved.bell,
      soundName: saved.soundName,
      soundFile: saved.soundFile,
      thinking: saved.thinking,
      engineFolder: saved.engineFolder,
      speedHighlighted: saved.speedHighlighted,
      stateLimitGiB: saved.stateLimitGiB,
      shareBenchmarks: saved.shareBenchmarks,
      vramHeadroomGiB: saved.vramHeadroomGiB,
      vramHeadroom: saved.vramHeadroom,
      communityStep: saved.communityStep,
      starReplies: saved.starReplies,
      starCardClosed: saved.starCardClosed,
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

  void setStateLimit(double gib) => _save(state.copyWith(stateLimitGiB: gib));

  void setSpeedHighlighted(bool on) => _save(state.copyWith(speedHighlighted: on));

  void setShareBenchmarks(bool on) => _save(state.copyWith(shareBenchmarks: on));

  /// The graphics card memory to leave free on the card [card] (its key), at least [minVramHeadroomGiB]. Applies the next
  /// time the model loads. Always saved as the card's own value: a card with one no longer takes the older single value.
  void setVramHeadroom(String card, double gib) =>
      _save(state.copyWith(vramHeadroom: {...state.vramHeadroom, card: max(gib, minVramHeadroomGiB)}));

  void setCommunityStep(int step) => _save(state.copyWith(communityStep: step));

  /// One more finished reply toward the star card, until it has shown or was closed.
  void countReply() {
    if (state.starCardClosed || state.starReplies >= starCardAfter) return;
    _save(state.copyWith(starReplies: state.starReplies + 1));
  }

  void closeStarCard() => _save(state.copyWith(starCardClosed: true));

  void toggleThinking() => _save(state.copyWith(thinking: !state.thinking));

  /// The folder the engine is in; empty: where it is by default.
  void setEngineFolder(String folder) {
    folder = folder.trim();
    _save(state.copyWith(engineFolder: () => folder.isEmpty ? null : folder));
  }

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
            thinking: prefs.thinking,
            engineFolder: prefs.engineFolder,
            speedHighlighted: prefs.speedHighlighted,
            stateLimitGiB: prefs.stateLimitGiB,
            soundName: prefs.soundName,
            soundFile: prefs.soundFile,
            shareBenchmarks: prefs.shareBenchmarks,
            vramHeadroomGiB: prefs.vramHeadroomGiB,
            vramHeadroom: prefs.vramHeadroom,
            communityStep: prefs.communityStep,
            starReplies: prefs.starReplies,
            starCardClosed: prefs.starCardClosed,
          ),
        );
  }
}

/// The star card shows after this many finished replies ever.
const starCardAfter = 3;

final prefsProvider = NotifierProvider<PrefsNotifier, Prefs>(PrefsNotifier.new);
