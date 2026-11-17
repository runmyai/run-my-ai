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
    required this.buttonFill,
    required this.buttonBorder,
    required this.buttonText,
    required this.buttonHoverFill,
    required this.buttonHoverBorder,
    required this.buttonPressedFill,
    required this.optionFill,
    required this.optionBorder,
    required this.optionText,
    required this.mainFill,
    required this.mainText,
    required this.mainHoverFill,
    required this.mainPressedFill,
    required this.disabledBorder,
    required this.disabledText,
    required this.focusRing,
    required this.rowHover,
    required this.rowPressed,
    required this.rowSelected,
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

  /// A normal button: its fill, border and text at rest, with the fill and border under the pointer and the fill
  /// while pressed. Every border is at least 3:1 against the page.
  final Color buttonFill;
  final Color buttonBorder;
  final Color buttonText;
  final Color buttonHoverFill;
  final Color buttonHoverBorder;
  final Color buttonPressedFill;

  /// A chosen option (a pill or a button that is on): one clear step above a normal button.
  final Color optionFill;
  final Color optionBorder;
  final Color optionText;

  /// The main button of a place (Start, Save, Send): a solid grey with no border, and its text.
  final Color mainFill;
  final Color mainText;
  final Color mainHoverFill;
  final Color mainPressedFill;

  /// A button that cannot be used: no fill, a faint border and quiet text.
  final Color disabledBorder;
  final Color disabledText;

  /// The ring around what has keyboard focus.
  final Color focusRing;

  /// A row or icon button with no border of its own (the sidebar, the top row): its fill under the pointer, while
  /// pressed and when chosen. Each is clearly visible on the page and on the sidebar.
  final Color rowHover;
  final Color rowPressed;
  final Color rowSelected;

  /// The sidebar's text (chat titles, its rows) and its quieter text (date headings), when it differs from
  /// [textSecondary] / [textMuted]: a step brighter in the dark themes and darker in the light ones, so the list
  /// reads easily on its hover and chosen rows.
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
    textMuted: Color(0xFF5C6066),
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
    buttonFill: Color(0xFFF3F4F6),
    buttonBorder: Color(0xFF7A7E85),
    buttonText: Color(0xFF222428),
    buttonHoverFill: Color(0xFFE8EAED),
    buttonHoverBorder: Color(0xFF5E6269),
    buttonPressedFill: Color(0xFFDADDE1),
    optionFill: Color(0xFFCDD1D6),
    optionBorder: Color(0xFF45494F),
    optionText: Color(0xFF222428),
    mainFill: Color(0xFF2A2C30),
    mainText: Color(0xFFF1F2F4),
    mainHoverFill: Color(0xFF3B3E43),
    mainPressedFill: Color(0xFF1A1B1E),
    disabledBorder: Color(0xFFCBCED3),
    disabledText: Color(0xFF9EA1A7),
    focusRing: Color(0xFF222428),
    rowHover: Color(0xFFD3D6DB),
    rowPressed: Color(0xFFBBBFC6),
    rowSelected: Color(0xFFC8CCD2),
    sidebarText: Color(0xFF3F4349),
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
    textMuted: Color(0xFF5C6066),
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
    buttonFill: Color(0xFFF3F4F6),
    buttonBorder: Color(0xFF7A7E85),
    buttonText: Color(0xFF222428),
    buttonHoverFill: Color(0xFFE8EAED),
    buttonHoverBorder: Color(0xFF5E6269),
    buttonPressedFill: Color(0xFFDADDE1),
    optionFill: Color(0xFFCDD1D6),
    optionBorder: Color(0xFF45494F),
    optionText: Color(0xFF222428),
    mainFill: Color(0xFF2A2C30),
    mainText: Color(0xFFF1F2F4),
    mainHoverFill: Color(0xFF3B3E43),
    mainPressedFill: Color(0xFF1A1B1E),
    disabledBorder: Color(0xFFCBCED3),
    disabledText: Color(0xFF9EA1A7),
    focusRing: Color(0xFF222428),
    rowHover: Color(0xFFD3D6DB),
    rowPressed: Color(0xFFBBBFC6),
    rowSelected: Color(0xFFC8CCD2),
    sidebarText: Color(0xFF3F4349),
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
    textMuted: Color(0xFF5A554E),
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
    buttonFill: Color(0xFFEDEBE7),
    buttonBorder: Color(0xFF77726A),
    buttonText: Color(0xFF22201E),
    buttonHoverFill: Color(0xFFE2E0DB),
    buttonHoverBorder: Color(0xFF5C5852),
    buttonPressedFill: Color(0xFFD3D0CA),
    optionFill: Color(0xFFC6C2BA),
    optionBorder: Color(0xFF45413C),
    optionText: Color(0xFF22201E),
    mainFill: Color(0xFF2A2826),
    mainText: Color(0xFFF0EEEA),
    mainHoverFill: Color(0xFF3B3835),
    mainPressedFill: Color(0xFF1A1918),
    disabledBorder: Color(0xFFC2BDB4),
    disabledText: Color(0xFF9A958D),
    focusRing: Color(0xFF22201E),
    rowHover: Color(0xFFC2BEB6),
    rowPressed: Color(0xFFABA79E),
    rowSelected: Color(0xFFB8B4AB),
    sidebarText: Color(0xFF34312D),
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
    textMuted: Color(0xFF8F897F),
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
    buttonFill: Color(0xFF2A2825),
    buttonBorder: Color(0xFF6A665F),
    buttonText: Color(0xFFF4EFE6),
    buttonHoverFill: Color(0xFF393630),
    buttonHoverBorder: Color(0xFF86817A),
    buttonPressedFill: Color(0xFF232220),
    optionFill: Color(0xFF45423B),
    optionBorder: Color(0xFFA09B91),
    optionText: Color(0xFFF4EFE6),
    mainFill: Color(0xFFDDD8CE),
    mainText: Color(0xFF141414),
    mainHoverFill: Color(0xFFEAE5DB),
    mainPressedFill: Color(0xFFC6C1B7),
    disabledBorder: Color(0xFF3A3732),
    disabledText: Color(0xFF5E5A53),
    focusRing: Color(0xFFF4EFE6),
    rowHover: Color(0xFF36332E),
    rowPressed: Color(0xFF4A4741),
    rowSelected: Color(0xFF3D3A35),
    sidebarText: Color(0xFFCDC8BD),
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
    textMuted: Color(0xFF858585),
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
    buttonFill: Color(0xFF181818),
    buttonBorder: Color(0xFF5C5C5C),
    buttonText: Color(0xFFE6E6E6),
    buttonHoverFill: Color(0xFF262626),
    buttonHoverBorder: Color(0xFF737373),
    buttonPressedFill: Color(0xFF141414),
    optionFill: Color(0xFF2E2E2E),
    optionBorder: Color(0xFF8A8A8A),
    optionText: Color(0xFFE6E6E6),
    mainFill: Color(0xFFCFCFCF),
    mainText: Color(0xFF0A0A0A),
    mainHoverFill: Color(0xFFDADADA),
    mainPressedFill: Color(0xFFBDBDBD),
    disabledBorder: Color(0xFF2A2A2A),
    disabledText: Color(0xFF5C5C5C),
    focusRing: Color(0xFFE6E6E6),
    rowHover: Color(0xFF262626),
    rowPressed: Color(0xFF363636),
    rowSelected: Color(0xFF2E2E2E),
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
    textMuted: Color(0xFF858585),
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
    buttonFill: Color(0xFF181818),
    buttonBorder: Color(0xFF5C5C5C),
    buttonText: Color(0xFFE6E6E6),
    buttonHoverFill: Color(0xFF262626),
    buttonHoverBorder: Color(0xFF737373),
    buttonPressedFill: Color(0xFF141414),
    optionFill: Color(0xFF2E2E2E),
    optionBorder: Color(0xFF8A8A8A),
    optionText: Color(0xFFE6E6E6),
    mainFill: Color(0xFFCFCFCF),
    mainText: Color(0xFF0A0A0A),
    mainHoverFill: Color(0xFFDADADA),
    mainPressedFill: Color(0xFFBDBDBD),
    disabledBorder: Color(0xFF2A2A2A),
    disabledText: Color(0xFF5C5C5C),
    focusRing: Color(0xFFE6E6E6),
    rowHover: Color(0xFF262626),
    rowPressed: Color(0xFF363636),
    rowSelected: Color(0xFF2E2E2E),
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
    // Flutter's usual fonts first, then the colour emoji fonts. They must come last: an emoji font also has a (very
    // wide) space and digits, which it would give all the text if it came before the font the text is in.
    fontFamilyFallback: const [
      'Ubuntu',
      'Cantarell',
      'DejaVu Sans',
      'Liberation Sans',
      'Arial',
      'Noto Color Emoji',
      'Segoe UI Emoji',
      'Apple Color Emoji',
    ],
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
    // Every dialog looks the same: the page colour with a 1 px outline (as menus and input boxes have) and a soft
    // shadow, so a dialog does not melt into a page of the same colour.
    dialogTheme: DialogThemeData(
      backgroundColor: c.page,
      surfaceTintColor: Colors.transparent,
      elevation: 16,
      shadowColor: c.shadow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: c.inputBorder)),
    ),
    // A menu's items show clearly under the pointer and with the keyboard.
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.pressed)
              ? c.rowPressed
              : (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused) ? c.rowHover : null),
        ),
      ),
    ),
    extensions: [c],
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: c.text, displayColor: c.text),
    iconTheme: IconThemeData(color: c.textSecondary, size: 18),
    dividerColor: c.border,
  );
}
