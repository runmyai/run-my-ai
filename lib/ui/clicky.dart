import 'package:flutter/material.dart';

import '../theme.dart';

/// What a [Clicky] is doing, for a builder that draws its own states.
class ClickyStatus {
  const ClickyStatus({required this.enabled, required this.hovered, required this.pressed, required this.focused});

  /// It has an action; without one it is inert and drawn as disabled.
  final bool enabled;

  /// The pointer is over it (never while disabled).
  final bool hovered;

  /// The pointer is down on it (never while disabled).
  final bool pressed;

  /// It has keyboard focus and shows the ring.
  final bool focused;
}

/// Draws a [Clicky.builder]'s child for the [status] it is in.
typedef ClickyBuilder = Widget Function(BuildContext context, ClickyStatus status);

/// Makes a widget feel like a button: it reacts under the pointer, dips while pressed, can be reached with Tab and
/// pressed with Enter or Space, shows a ring while it has keyboard focus, and tells screen readers what it is.
/// [Clicky] tints its [child]; [Clicky.builder] hands the states to a builder that draws them itself (the
/// buttons in `buttons.dart`). Without [onTap] it is inert.
class Clicky extends StatefulWidget {
  const Clicky({
    super.key,
    required this.onTap,
    required Widget this.child,
    this.radius = 8,
    this.focusNode,
    this.autofocus = false,
    this.ringAlways = false,
    this.label,
    this.selected,
  }) : builder = null;

  const Clicky.builder({
    super.key,
    required this.onTap,
    required ClickyBuilder this.builder,
    this.radius = 8,
    this.focusNode,
    this.autofocus = false,
    this.ringAlways = false,
    this.label,
    this.selected,
  }) : child = null;

  final VoidCallback? onTap;
  final Widget? child;
  final ClickyBuilder? builder;
  final double radius;
  final FocusNode? focusNode;
  final bool autofocus;

  /// Show the ring whenever it has focus, not only while the user works with the keyboard (a dialog's chosen button).
  final bool ringAlways;

  /// What a screen reader says when the child has no words of its own.
  final String? label;

  /// For a button that is on or off (null: it is not that kind of button).
  final bool? selected;

  @override
  State<Clicky> createState() => _ClickyState();
}

class _ClickyState extends State<Clicky> {
  static const _motion = Duration(milliseconds: 90);
  static const _ringWidth = 2.0;

  var _hovered = false;
  var _pressed = false;
  var _focused = false;
  var _keyboard = false;

  void _press(bool pressed) => setState(() => _pressed = pressed);

  void _activate() => widget.onTap?.call();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = widget.onTap != null;
    final ring = enabled && (_keyboard || (widget.ringAlways && _focused));
    final status = ClickyStatus(
      enabled: enabled,
      hovered: enabled && _hovered,
      pressed: enabled && _pressed,
      focused: ring,
    );
    final builder = widget.builder;
    final Widget body;
    if (builder != null) {
      body = builder(context, status);
    } else {
      final tint = c.text.withValues(alpha: !enabled ? 0 : (_pressed ? 0.18 : (_hovered ? 0.12 : 0)));
      body = AnimatedContainer(
        duration: _motion,
        foregroundDecoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(widget.radius)),
        child: widget.child,
      );
    }
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: enabled,
        selected: widget.selected,
        label: widget.label,
        child: FocusableActionDetector(
          enabled: enabled,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          onFocusChange: (focused) => setState(() => _focused = focused),
          onShowFocusHighlight: (shown) => setState(() => _keyboard = shown),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _activate()),
            ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(onInvoke: (_) => _activate()),
          },
          child: MouseRegion(
            cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() {
              _hovered = false;
              _pressed = false;
            }),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              onTapDown: enabled ? (_) => _press(true) : null,
              onTapUp: enabled ? (_) => _press(false) : null,
              onTapCancel: enabled ? () => _press(false) : null,
              child: AnimatedScale(
                scale: status.pressed ? 0.97 : 1,
                duration: _motion,
                // The ring is drawn just outside the button, so it shows on any fill and never changes the layout.
                child: Stack(
                  fit: StackFit.passthrough,
                  clipBehavior: Clip.none,
                  children: [
                    body,
                    if (ring)
                      Positioned(
                        left: -_ringWidth,
                        top: -_ringWidth,
                        right: -_ringWidth,
                        bottom: -_ringWidth,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: c.focusRing, width: _ringWidth),
                              borderRadius: BorderRadius.circular(widget.radius + _ringWidth),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
