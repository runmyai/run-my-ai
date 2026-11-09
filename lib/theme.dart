import 'package:flutter/material.dart';

/// Brand colours: the logo is ink on light and ivory on dark (assets/logo/README.txt); the app has no other accent.
const ink = Color(0xFF141414);
const ivory = Color(0xFFF4EFE6);

/// How a dark theme is drawn beyond its colours: flat (Dark), a silky wave and boxes lit from the top (Dark 2), or the
/// logo's slashes, a fine grain, a light rim on the boxes and the faint logo on an empty chat (Dark 3).
enum DarkLook { flat, silk, slashes }

/// The app's own colours, one set for light and one for dark: warm greys from the logo's ivory and ink.
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.page,
    required this.sidebar,
    required this.border,
    required this.selected,
    required this.switchTrack,
    required this.switchOn,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.inputFill,
    required this.inputBorder,
    required this.danger,
    required this.shadow,
    required this.edge,
    required this.edgeInactive,
    required this.edgeTop,
    required this.edgeTopInactive,
    required this.edgeShine,
    required this.edgeShineInactive,
    this.look = DarkLook.flat,
    this.sidebarText,
    this.sidebarMuted,
  });

  final Color page;
  final Color sidebar;
  final Color border;
  final Color selected;
  final Color switchTrack;
  final Color switchOn;
  final Color text;
  final Color textSecondary;
  final Color textMuted;
  final Color inputFill;
  final Color inputBorder;

  /// Delete actions only.
  final Color danger;

  /// Soft shadows (the message box, the chat area's edge on the sidebar, under the top row while scrolled).
  final Color shadow;

  /// The window's outline (not when maximized or full screen), softer while another app is in front; its top edge
  /// can differ (in dark, a faint lighter line, as if lit from above).
  final Color edge;
  final Color edgeInactive;
  final Color edgeTop;
  final Color edgeTopInactive;

  /// In light, the same lit-from-above touch: a faint white line just inside the top edge (in dark the top edge
  /// itself is lighter, so none there).
  final Color edgeShine;
  final Color edgeShineInactive;

  /// The sidebar's text (chat titles, its rows) and its quieter text (date headings), when it differs from
  /// [textSecondary] / [textMuted]: a step brighter in the black themes, so the list reads easily.
  final Color? sidebarText;
  final Color? sidebarMuted;

  Color get sideText => sidebarText ?? textSecondary;
  Color get sideMuted => sidebarMuted ?? textMuted;

  /// Beyond the colours (see [DarkLook]). All drawn once; nothing moves.
  final DarkLook look;

  /// Not flat: a soft light low on the page.
  bool get decorated => look != DarkLook.flat;

  /// A light theme (its decorations shade instead of lighten, and it has no grain).
  bool get isLight => page.computeLuminance() > 0.5;

  /// Dark 3: the logo's slashes, the grain, the rims, the faint logo.
  bool get slashes => look == DarkLook.slashes;

  /// [base] lit from the top (a shade lighter at its top) in Dark 2; else null (flat).
  Gradient? lit(Color base) => look == DarkLook.silk
      ? LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(base, Colors.white, 0.035)!, base],
        )
      : null;

  /// Run My AI Light, the app's own light (the partner of Run My AI Dark): light, slightly cool greys ("graphite
  /// light"), never white, dark grey text; the logo's slashes shaded into the sidebar, light rims, a soft light along the bottom.
  static const light = AppColors(
    page: Color(0xFFE5E6E8),
    sidebar: Color(0xFFEDEEF0),
    border: Color(0xFFCACDD1),
    selected: Color(0xFFD9DBDE),
    switchTrack: Color(0xFFDDDFE2),
    switchOn: Color(0xFFF1F2F4),
    text: Color(0xFF222428),
    textSecondary: Color(0xFF52565C),
    textMuted: Color(0xFF83878D),
    inputFill: Color(0xFFF1F2F4),
    inputBorder: Color(0xFFCACDD1),
    danger: Color(0xFFC42B1C),
    shadow: Color(0x1F000000),
    edge: Color(0xFFCACDD1),
    edgeInactive: Color(0xFFCACDD1),
    edgeTop: Color(0xFFCACDD1),
    edgeTopInactive: Color(0xFFCACDD1),
    edgeShine: Color(0xCCFFFFFF),
    edgeShineInactive: Color(0x66FFFFFF),
    look: DarkLook.slashes,
  );

  /// Silk Light (the partner of Silk): Run My AI Light's colours, with the silky wave, a round soft light, boxes lit
  /// from the top.
  static const silkLight = AppColors(
    page: Color(0xFFE5E6E8),
    sidebar: Color(0xFFEDEEF0),
    border: Color(0xFFCACDD1),
    selected: Color(0xFFD9DBDE),
    switchTrack: Color(0xFFDDDFE2),
    switchOn: Color(0xFFF1F2F4),
    text: Color(0xFF222428),
    textSecondary: Color(0xFF52565C),
    textMuted: Color(0xFF83878D),
    inputFill: Color(0xFFF1F2F4),
    inputBorder: Color(0xFFCACDD1),
    danger: Color(0xFFC42B1C),
    shadow: Color(0x1F000000),
    edge: Color(0xFFCACDD1),
    edgeInactive: Color(0xFFCACDD1),
    edgeTop: Color(0xFFCACDD1),
    edgeTopInactive: Color(0xFFCACDD1),
    edgeShine: Color(0xCCFFFFFF),
    edgeShineInactive: Color(0x66FFFFFF),
    look: DarkLook.silk,
  );

  /// Dusk: a darker light, for evenings and bright screens; plain.
  static const dusk = AppColors(
    page: Color(0xFFDFDDD8),
    sidebar: Color(0xFFD4D1CB),
    border: Color(0xFFC2BDB4),
    selected: Color(0xFFCCC8C1),
    switchTrack: Color(0xFFCAC6BF),
    switchOn: Color(0xFFE8E6E2),
    text: Color(0xFF22201E),
    textSecondary: Color(0xFF4F4B46),
    textMuted: Color(0xFF7A756E),
    inputFill: Color(0xFFE8E6E2),
    inputBorder: Color(0xFFC2BDB4),
    danger: Color(0xFFC42B1C),
    shadow: Color(0x1F000000),
    edge: Color(0xFFC2BDB4),
    edgeInactive: Color(0xFFC2BDB4),
    edgeTop: Color(0xFFC2BDB4),
    edgeTopInactive: Color(0xFFC2BDB4),
    edgeShine: Color(0xCCFFFFFF),
    edgeShineInactive: Color(0x66FFFFFF),
  );

  /// Espresso: warm greys from the logo's ivory and ink.
  static const dark = AppColors(
    page: Color(0xFF1C1B19),
    sidebar: ink,
    border: Color(0xFF2A2825),
    selected: Color(0xFF2C2A26),
    switchTrack: Color(0xFF232220),
    switchOn: Color(0xFF34322E),
    text: ivory,
    textSecondary: Color(0xFFB9B3A8),
    textMuted: Color(0xFF857F75),
    inputFill: Color(0xFF252320),
    inputBorder: Color(0xFF3A3733),
    danger: Color(0xFFF0766B),
    shadow: Color(0x99000000),
    edge: Color(0xFF3A3733),
    edgeInactive: Color(0xFF2C2A26),
    edgeTop: Color(0xFF55514A),
    edgeTopInactive: Color(0xFF3A3733),
    edgeShine: Color(0x00FFFFFF),
    edgeShineInactive: Color(0x00FFFFFF),
  );

  /// Silk (Dark 2): Run My AI Dark's colours, with the silky wave, a round soft light, boxes lit from the top.
  static const dark2 = AppColors(
    page: Color(0xFF060606),
    sidebar: Color(0xFF030303),
    border: Color(0xFF1E1E1E),
    selected: Color(0xFF161616),
    switchTrack: Color(0xFF0D0D0D),
    switchOn: Color(0xFF222222),
    text: Color(0xFFE6E6E6),
    textSecondary: Color(0xFFA0A0A0),
    textMuted: Color(0xFF6E6E6E),
    inputFill: Color(0xFF0E0E0E),
    inputBorder: Color(0xFF222222),
    danger: Color(0xFFF0766B),
    shadow: Color(0xB3000000),
    edge: Color(0xFF222222),
    edgeInactive: Color(0xFF161616),
    edgeTop: Color(0xFF323232),
    edgeTopInactive: Color(0xFF222222),
    edgeShine: Color(0x00FFFFFF),
    edgeShineInactive: Color(0x00FFFFFF),
    look: DarkLook.silk,
    sidebarText: Color(0xFFBFBFBF),
    sidebarMuted: Color(0xFF898989),
  );

  /// Run My AI Dark (Dark 3), the app's own: deep blacks (a #060606 page on a #030303 sidebar), drawn with the logo's slashes, a fine grain and light rims (see [DarkLook]).
  static const dark3 = AppColors(
    page: Color(0xFF060606),
    sidebar: Color(0xFF030303),
    border: Color(0xFF1E1E1E),
    selected: Color(0xFF161616),
    switchTrack: Color(0xFF0D0D0D),
    switchOn: Color(0xFF222222),
    text: Color(0xFFE6E6E6),
    textSecondary: Color(0xFFA0A0A0),
    textMuted: Color(0xFF6E6E6E),
    inputFill: Color(0xFF0E0E0E),
    inputBorder: Color(0xFF222222),
    danger: Color(0xFFF0766B),
    shadow: Color(0xB3000000),
    edge: Color(0xFF222222),
    edgeInactive: Color(0xFF161616),
    edgeTop: Color(0xFF323232),
    edgeTopInactive: Color(0xFF222222),
    edgeShine: Color(0x00FFFFFF),
    edgeShineInactive: Color(0x00FFFFFF),
    look: DarkLook.slashes,
    sidebarText: Color(0xFFBFBFBF),
    sidebarMuted: Color(0xFF898989),
  );

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(AppColors? other, double t) => t < 0.5 || other == null ? this : other;
}

extension AppColorsOf on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
}

/// [lightColors] / [darkColors]: which light / dark theme.
ThemeData buildTheme(
  Brightness brightness, {
  AppColors lightColors = AppColors.light,
  AppColors darkColors = AppColors.dark3,
}) {
  final c = brightness == Brightness.light ? lightColors : darkColors;
  final base = ThemeData(
    brightness: brightness,
    // No colour accent: Flutter's own widgets (Store buttons, menus, text selection) use ink / ivory too.
    colorScheme: ColorScheme.fromSeed(
      seedColor: c.text,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
    ).copyWith(primary: c.text, onPrimary: c.page),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.text,
      selectionColor: c.text.withValues(alpha: 0.18),
      selectionHandleColor: c.text,
    ),
    scaffoldBackgroundColor: c.page,
    splashFactory: NoSplash.splashFactory,
    extensions: [c],
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: c.text, displayColor: c.text),
    iconTheme: IconThemeData(color: c.textSecondary, size: 18),
    dividerColor: c.border,
  );
}
