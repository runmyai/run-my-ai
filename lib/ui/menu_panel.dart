import 'package:flutter/material.dart';

/// The menu's own panel is left invisible ([bareMenuStyle]) and [MenuPanel] draws it instead, so the whole menu
/// (background, border, shadow and items) can fade in. Use with `clipBehavior: Clip.none` on the MenuAnchor, so
/// the shadow shows.
const bareMenuStyle = MenuStyle(
  backgroundColor: WidgetStatePropertyAll(Colors.transparent),
  surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
  shadowColor: WidgetStatePropertyAll(Colors.transparent),
  elevation: WidgetStatePropertyAll(0),
  padding: WidgetStatePropertyAll(EdgeInsets.zero),
  side: WidgetStatePropertyAll(BorderSide.none),
);

/// A menu's background, border and shadow around its items; it fades in quickly when the menu opens (closing is
/// instant).
class MenuPanel extends StatefulWidget {
  const MenuPanel({
    super.key,
    required this.color,
    required this.border,
    required this.children,
    this.radius = 10,
    this.elevation = 3,
    this.shadowColor = Colors.black26,
    this.padding = const EdgeInsets.all(4),
  });

  final Color color;
  final Color border;
  final double radius;
  final double elevation;
  final Color shadowColor;
  final EdgeInsets padding;
  final List<Widget> children;

  @override
  State<MenuPanel> createState() => _MenuPanelState();
}

class _MenuPanelState extends State<MenuPanel> with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 100))..forward();

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: _fade, curve: Curves.easeOut),
      child: Material(
        color: widget.color,
        elevation: widget.elevation,
        shadowColor: widget.shadowColor,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: widget.border),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: widget.padding,
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.children,
            ),
          ),
        ),
      ),
    );
  }
}
