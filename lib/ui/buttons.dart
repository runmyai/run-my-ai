import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'clicky.dart';

// The app's buttons: a normal button, a main button, an option that can be chosen, and an icon button. All are
// drawn from the colour roles of AppColors and built on Clicky, so each has the same hover, press, keyboard
// focus and screen-reader behaviour.

const _fade = Duration(milliseconds: 90);

enum _Kind { normal, main, option }

/// The face of a text button: a fill, a border, and a label with an icon before it or after it.
class _ButtonFace extends StatelessWidget {
  const _ButtonFace({
    required this.kind,
    required this.label,
    required this.onTap,
    required this.icon,
    required this.trailing,
    required this.danger,
    required this.chosen,
    required this.padding,
    required this.fontSize,
    required this.focusNode,
    required this.autofocus,
    required this.ringAlways,
  });

  final _Kind kind;
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final IconData? trailing;
  final bool danger;
  final bool chosen;
  final EdgeInsets padding;
  final double fontSize;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool ringAlways;

  @override
  Widget build(BuildContext context) {
    return Clicky.builder(
      onTap: onTap,
      focusNode: focusNode,
      autofocus: autofocus,
      ringAlways: ringAlways,
      selected: kind == _Kind.option ? chosen : null,
      builder: (context, s) {
        final c = context.colors;
        final active = s.hovered || s.pressed;
        final Color fill;
        final Color? border;
        final Color text;
        if (!s.enabled) {
          fill = Colors.transparent;
          border = c.disabledBorder;
          text = c.disabledText;
        } else if (kind == _Kind.main) {
          border = null;
          if (danger) {
            final base = c.danger;
            final toward = c.isLight ? Colors.black : Colors.white;
            fill = s.pressed
                ? Color.lerp(base, Colors.black, 0.15)!
                : (s.hovered ? Color.lerp(base, toward, 0.12)! : base);
            // The light red on dark needs dark text.
            text = c.isLight ? Colors.white : c.page;
          } else {
            fill = s.pressed ? c.mainPressedFill : (s.hovered ? c.mainHoverFill : c.mainFill);
            text = c.mainText;
          }
        } else if (kind == _Kind.option && chosen) {
          fill = s.pressed ? c.buttonPressedFill : c.optionFill;
          border = c.optionBorder;
          text = c.optionText;
        } else {
          fill = s.pressed ? c.buttonPressedFill : (s.hovered ? c.buttonHoverFill : c.buttonFill);
          border = active ? c.buttonHoverBorder : c.buttonBorder;
          text = danger ? c.danger : c.buttonText;
        }
        final style = TextStyle(
          fontSize: fontSize,
          fontWeight: kind == _Kind.main ? FontWeight.w500 : FontWeight.w400,
          color: text,
        );
        return AnimatedContainer(
          duration: _fade,
          padding: padding,
          decoration: BoxDecoration(
            color: fill,
            // (The main button has an invisible border, so it is as big as the others beside it.)
            border: Border.all(color: border ?? Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: fontSize + 3, color: text), const SizedBox(width: 6)],
              Text(label, style: style),
              if (trailing != null) ...[const SizedBox(width: 6), Icon(trailing, size: 16, color: text)],
            ],
          ),
        );
      },
    );
  }
}

EdgeInsets _padding(bool dense, EdgeInsets? padding) =>
    padding ?? (dense ? const EdgeInsets.symmetric(horizontal: 10, vertical: 4) : const EdgeInsets.symmetric(horizontal: 14, vertical: 6));

/// A normal button: a quiet fill with a clear border. [danger] writes the label in the danger colour. Greyed out
/// without [onTap].
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.trailingIcon,
    this.danger = false,
    this.dense = false,
    this.padding,
    this.focusNode,
    this.autofocus = false,
    this.ringAlways = false,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final IconData? trailingIcon;
  final bool danger;

  /// Smaller, for a button inside a line of text or a card.
  final bool dense;
  final EdgeInsets? padding;
  final FocusNode? focusNode;
  final bool autofocus;

  /// Show the focus ring whenever it has focus (a dialog's chosen button), not only for keyboard use.
  final bool ringAlways;

  @override
  Widget build(BuildContext context) => _ButtonFace(
    kind: _Kind.normal,
    label: label,
    onTap: onTap,
    icon: icon,
    trailing: trailingIcon,
    danger: danger,
    chosen: false,
    padding: _padding(dense, padding),
    fontSize: dense ? 12.5 : 13,
    focusNode: focusNode,
    autofocus: autofocus,
    ringAlways: ringAlways,
  );
}

/// The main button of a place (Start, Save): a solid grey with no border, the one thing to press. With [danger], the
/// danger colour (the button of a delete question). Greyed out without [onTap].
class MainButton extends StatelessWidget {
  const MainButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.danger = false,
    this.dense = false,
    this.fontSize,
    this.padding,
    this.focusNode,
    this.autofocus = false,
    this.ringAlways = false,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool danger;
  final bool dense;
  final double? fontSize;
  final EdgeInsets? padding;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool ringAlways;

  @override
  Widget build(BuildContext context) => _ButtonFace(
    kind: _Kind.main,
    label: label,
    onTap: onTap,
    icon: icon,
    trailing: null,
    danger: danger,
    chosen: false,
    padding: _padding(dense, padding),
    fontSize: fontSize ?? (dense ? 12.5 : 13),
    focusNode: focusNode,
    autofocus: autofocus,
    ringAlways: ringAlways,
  );
}

/// One of a set of options (a profile, a tab, a setting's choice), or a button that opens a list ([trailingIcon]): the
/// [chosen] one has a lighter fill and a brighter border than the rest.
class OptionPill extends StatelessWidget {
  const OptionPill({
    super.key,
    required this.label,
    required this.onTap,
    this.chosen = false,
    this.trailingIcon,
    this.padding,
    this.focusNode,
  });

  final String label;
  final VoidCallback? onTap;
  final bool chosen;
  final IconData? trailingIcon;
  final EdgeInsets? padding;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => _ButtonFace(
    kind: _Kind.option,
    label: label,
    onTap: onTap,
    icon: null,
    trailing: trailingIcon,
    danger: false,
    chosen: chosen,
    padding: padding ?? const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    fontSize: 13,
    focusNode: focusNode,
    autofocus: false,
    ringAlways: false,
  );
}

/// How an [AppIconButton] is drawn when it is at rest.
enum IconButtonLook {
  /// No fill or border: a fill shows under the pointer (the sidebar, the top row, small actions).
  quiet,

  /// Like a normal button: a fill and a border.
  outlined,

  /// The main button of a place (Send): a solid grey.
  main,
}

/// A button that is an icon. [tooltip] names it for the pointer and for screen readers. [round] makes it a circle.
/// [chosen] shows it as on (the sidebar's open page). [muted] draws the icon quieter at rest.
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 34,
    this.height,
    this.iconSize = 18,
    this.round = false,
    this.radius,
    this.look = IconButtonLook.quiet,
    this.chosen = false,
    this.muted = false,
    this.color,
    this.keepIconColor = false,
    this.tooltipWait = const Duration(milliseconds: 400),
    this.focusNode,
    this.ringAlways = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;

  /// The height, when it is not the same as the width ([size]).
  final double? height;
  final double iconSize;
  final bool round;

  /// The corner radius of a button that is not [round]; default 8.
  final double? radius;
  final IconButtonLook look;
  final bool chosen;
  final bool muted;

  /// The icon's colour at rest, when it is not the usual one.
  final Color? color;

  /// Without [onTap] the icon keeps its colour instead of greying (a lit bulb that cannot be switched).
  final bool keepIconColor;

  /// How long the pointer rests on it before the tooltip shows.
  final Duration tooltipWait;
  final FocusNode? focusNode;
  final bool ringAlways;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: tooltipWait,
      excludeFromSemantics: true,
      child: Clicky.builder(
        onTap: onTap,
        radius: round ? math.min(size, height ?? size) / 2 : (radius ?? 8),
        focusNode: focusNode,
        autofocus: false,
        ringAlways: ringAlways,
        label: tooltip,
        selected: chosen ? true : null,
        builder: (context, s) {
          final c = context.colors;
          final active = s.hovered || s.pressed;
          final Color fill;
          final Color? border;
          final Color iconColor;
          switch (look) {
            case IconButtonLook.quiet:
              fill = !s.enabled
                  ? Colors.transparent
                  : s.pressed
                  ? c.rowPressed
                  : chosen
                  ? c.rowSelected
                  : (s.hovered ? c.rowHover : Colors.transparent);
              border = null;
              iconColor = !s.enabled && !keepIconColor
                  ? c.disabledText
                  : (active || chosen ? c.text : (color ?? (muted ? c.textMuted : c.textSecondary)));
            case IconButtonLook.outlined:
              if (!s.enabled) {
                fill = Colors.transparent;
                border = c.disabledBorder;
                iconColor = c.disabledText;
              } else if (chosen) {
                fill = s.pressed ? c.buttonPressedFill : c.optionFill;
                border = c.optionBorder;
                iconColor = c.optionText;
              } else {
                fill = s.pressed ? c.buttonPressedFill : (s.hovered ? c.buttonHoverFill : c.buttonFill);
                border = active ? c.buttonHoverBorder : c.buttonBorder;
                iconColor = c.buttonText;
              }
            case IconButtonLook.main:
              if (!s.enabled) {
                fill = Colors.transparent;
                border = c.disabledBorder;
                iconColor = c.disabledText;
              } else {
                fill = s.pressed ? c.mainPressedFill : (s.hovered ? c.mainHoverFill : c.mainFill);
                border = null;
                iconColor = c.mainText;
              }
          }
          return AnimatedContainer(
            duration: _fade,
            width: size,
            height: height ?? size,
            decoration: BoxDecoration(
              color: fill,
              border: border == null ? null : Border.all(color: border),
              borderRadius: BorderRadius.circular(round ? math.min(size, height ?? size) / 2 : (radius ?? 8)),
            ),
            child: Icon(icon, size: iconSize, color: iconColor),
          );
        },
      ),
    );
  }
}
