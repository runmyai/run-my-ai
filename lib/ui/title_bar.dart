import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../theme.dart';
import '../window/app_window.dart';

/// The app has no system title bar; the top row of the sidebar and of the page take its place.
const titleBarHeight = 48.0;

/// Room kept free at the top left for Apple's three buttons.
const macButtonsWidth = 72.0;

bool get isMacLook => windowLook == WindowLook.mac;

/// The window's top row, a little faded while another app is in front (like the system's own title bars).
class TitleRowFade extends ConsumerWidget {
  const TitleRowFade({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focused = ref.watch(windowFocusedProvider);
    return AnimatedOpacity(opacity: focused ? 1 : 0.55, duration: const Duration(milliseconds: 150), child: child);
  }
}

/// The window's shape: on Linux the corners are rounded (8 px; the app draws its own window there, see
/// linux/runner/my_application.cc), and on every system its outline is drawn over everything (dialogs too). Square,
/// with no outline, when maximized or full screen.
class WindowShape extends ConsumerWidget {
  const WindowShape({super.key, required this.child});

  final Widget child;

  static const radius = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final whole = ref.watch(windowMaximizedProvider) || ref.watch(windowFullScreenProvider);
    final r = whole || !Platform.isLinux ? 0.0 : radius;
    return Stack(children: [
      Positioned.fill(child: ClipRRect(borderRadius: BorderRadius.circular(r), child: child)),
      if (!whole) Positioned.fill(child: WindowEdge(radius: r)),
    ]);
  }
}

/// The window's outline, softer while another app is in front, with its top edge as the theme sets it (lit from
/// above in dark). It takes no clicks.
class WindowEdge extends ConsumerWidget {
  const WindowEdge({super.key, this.radius = 0});

  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).extension<AppColors>()!;
    final focused = ref.watch(windowFocusedProvider);
    return IgnorePointer(
      child: CustomPaint(
        key: const Key('window-edge'),
        painter: _EdgePainter(
          radius: radius,
          side: focused ? c.edge : c.edgeInactive,
          top: focused ? c.edgeTop : c.edgeTopInactive,
          shine: focused ? c.edgeShine : c.edgeShineInactive,
        ),
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  _EdgePainter({required this.radius, required this.side, required this.top, required this.shine});

  final double radius;
  final Color side;
  final Color top;
  final Color shine;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // The top line in its own colour, fading into the sides' colour around the top corners.
    final shade = (radius + 2) / size.height;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, top, side, side],
          stops: [0, shade * 0.5, shade, 1],
        ).createShader(rect),
    );
    // A faint light line just inside the top edge, between the corners, fading out at its ends.
    if (shine.a > 0 && size.width > 2 * radius + 4) {
      final from = radius + 1, to = size.width - radius - 1;
      canvas.drawLine(
        Offset(from, 1.5),
        Offset(to, 1.5),
        Paint()
          ..strokeWidth = 1
          ..shader = LinearGradient(
            colors: [shine.withValues(alpha: 0), shine, shine, shine.withValues(alpha: 0)],
            stops: const [0, 0.08, 0.92, 1],
          ).createShader(Rect.fromLTWH(from, 0, to - from, 3)),
      );
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) =>
      old.radius != radius || old.side != side || old.top != top || old.shine != shine;
}

/// The empty parts of [child] act like a title bar: drag to move the window, double-click to maximize,
/// right-click for the system's window menu. Buttons inside [child] still work as buttons.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => windowManager.startDragging(),
            onDoubleTap: toggleMaximize,
            onSecondaryTapUp: Platform.isMacOS ? null : (_) => windowManager.popUpWindowMenu(),
          ),
        ),
        child,
      ],
    );
  }
}

/// Minimize, maximize / restore and close, drawn in our colors (Windows and Linux). Compact, like the app's
/// other icon buttons; sizes are in the app's own units, so they follow the screen's scaling like everything else.
class WindowButtons extends ConsumerWidget {
  const WindowButtons({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maximized = ref.watch(windowMaximizedProvider);
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          _CaptionButton(
            key: const Key('window-minimize'),
            tooltip: 'Minimize',
            glyph: _Glyph.minimize,
            onTap: windowManager.minimize,
          ),
          _CaptionButton(
            key: const Key('window-maximize'),
            tooltip: maximized ? 'Restore' : 'Maximize',
            glyph: maximized ? _Glyph.restore : _Glyph.maximize,
            onTap: toggleMaximize,
          ),
          _CaptionButton(
            key: const Key('window-close'),
            tooltip: 'Close',
            glyph: _Glyph.close,
            isClose: true,
            onTap: windowManager.close,
          ),
        ],
      ),
    );
  }
}

enum _Glyph { minimize, maximize, restore, close }

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    super.key,
    required this.tooltip,
    required this.glyph,
    required this.onTap,
    this.isClose = false,
  });

  final String tooltip;
  final _Glyph glyph;
  final VoidCallback onTap;
  final bool isClose;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  static const _closeRed = Color(0xFFC42B1C);
  static const _closeRedPressed = Color(0xFFB0281A);

  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final Color background;
    final Color icon;
    if (widget.isClose && (_hover || _pressed)) {
      background = _pressed ? _closeRedPressed : _closeRed;
      icon = Colors.white;
    } else {
      background = _pressed ? c.switchOn : (_hover ? c.selected : Colors.transparent);
      icon = _hover || _pressed ? c.text : c.textSecondary;
    }
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = _pressed = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(8)),
            child: CustomPaint(painter: _GlyphPainter(widget.glyph, icon)),
          ),
        ),
      ),
    );
  }
}

/// Thin 10 x 10 icons, like the system's own window buttons.
class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);

  final _Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const s = 10.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.translate(((size.width - s) / 2).roundToDouble(), ((size.height - s) / 2).roundToDouble());
    switch (glyph) {
      case _Glyph.minimize:
        canvas.drawLine(const Offset(0, 5.5), const Offset(s, 5.5), paint);
      case _Glyph.maximize:
        canvas.drawRect(const Rect.fromLTWH(0.5, 0.5, s - 1, s - 1), paint);
      case _Glyph.restore:
        canvas.drawRect(const Rect.fromLTWH(0.5, 2.5, s - 3, s - 3), paint);
        canvas.drawPath(
          Path()
            ..moveTo(2.5, 2.5)
            ..lineTo(2.5, 0.5)
            ..lineTo(s - 0.5, 0.5)
            ..lineTo(s - 0.5, s - 2.5)
            ..lineTo(s - 2.5, s - 2.5),
          paint,
        );
      case _Glyph.close:
        canvas.drawLine(Offset.zero, const Offset(s, s), paint);
        canvas.drawLine(const Offset(s, 0), const Offset(0, s), paint);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.color != color;
}

/// A drawn copy of Apple's three buttons, for previewing the Mac look on another system
/// (on a real Mac, macOS draws its own in the same spot). They work in the preview too.
class MacButtonsPreview extends StatelessWidget {
  const MacButtonsPreview({super.key});

  @override
  Widget build(BuildContext context) {
    Widget light(Color fill, Color edge, String tooltip, VoidCallback onTap) => Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: fill,
            shape: BoxShape.circle,
            border: Border.all(color: edge, width: 0.5),
          ),
        ),
      ),
    );
    // Where macOS puts them in a window without a title bar: 8 px in, centered in the top 28 px.
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 0, 0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          light(const Color(0xFFFF5F57), const Color(0xFFE2463F), 'Close', windowManager.close),
          const SizedBox(width: 8),
          light(const Color(0xFFFEBC2E), const Color(0xFFE1A116), 'Minimize', windowManager.minimize),
          const SizedBox(width: 8),
          light(const Color(0xFF28C840), const Color(0xFF14AE2B), 'Zoom', toggleMaximize),
        ],
      ),
    );
  }
}
