import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';

/// A box (the message box, a sent message) drawn the theme's way: in Dark 3 with a thin light rim along its top edge,
/// as if light catches it (the rim fades into [edge] lower down); otherwise its fill (lit from the top in Dark 2) and
/// [edge] as a plain outline, if any.
class LookBox extends StatelessWidget {
  const LookBox({
    super.key,
    required this.fill,
    required this.radius,
    required this.padding,
    required this.child,
    this.edge,
    this.shadows,
  });

  final Color fill;
  final Color? edge;
  final double radius;
  final EdgeInsets padding;
  final List<BoxShadow>? shadows;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (!c.slashes) {
      return Container(
        padding: padding,
        decoration: BoxDecoration(
          color: fill,
          gradient: c.lit(fill),
          border: edge == null ? null : Border.all(color: edge!),
          borderRadius: BorderRadius.circular(radius),
          boxShadow: shadows,
        ),
        child: child,
      );
    }
    final below = edge ?? fill;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: shadows,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          // (A light theme's rim is near white, to show on its light boxes.)
          colors: [Color.lerp(below, Colors.white, c.isLight ? 0.75 : 0.16)!, below, below],
          stops: const [0, 0.35, 1],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: Container(
          padding: edge == null ? padding : padding - const EdgeInsets.all(1),
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(radius - 1)),
          child: child,
        ),
      ),
    );
  }
}

/// Dark 3's fine grain: a faint, still noise over a dark surface, so its black looks deep rather than flat. One small
/// tile, made once and repeated; drawn behind the content.
class Grain extends StatefulWidget {
  const Grain({super.key});

  @override
  State<Grain> createState() => _GrainState();
}

class _GrainState extends State<Grain> {
  static ui.Image? _tile;

  @override
  void initState() {
    super.initState();
    if (_tile == null) _make();
  }

  Future<void> _make() async {
    const size = 128;
    final r = Random(7);
    final pixels = Uint8List(size * size * 4);
    for (var i = 0; i < size * size; i++) {
      // Light or dark specks, each faint. (The pixels are premultiplied: a light speck's colour is its alpha.)
      final alpha = r.nextInt(6);
      final v = r.nextBool() ? alpha : 0;
      pixels
        ..[i * 4] = v
        ..[i * 4 + 1] = v
        ..[i * 4 + 2] = v
        ..[i * 4 + 3] = alpha;
    }
    ui.decodeImageFromPixels(pixels, size, size, ui.PixelFormat.rgba8888, (image) {
      _tile = image;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final tile = _tile;
    if (tile == null) return const SizedBox.expand();
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(painter: _GrainPainter(tile), size: Size.infinite),
      ),
    );
  }
}

class _GrainPainter extends CustomPainter {
  _GrainPainter(this.tile);

  final ui.Image tile;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = ImageShader(tile, TileMode.repeated, TileMode.repeated, Matrix4.identity().storage),
    );
  }

  @override
  bool shouldRepaint(_GrainPainter old) => old.tile != tile;
}

/// Dark 3's sidebar picture: the logo's slashes, low in the sidebar: three broad bands leaning like the logo's
/// slashes, taller and a shade lighter from left to right, each fading out as it rises. Greys only, very faint.
class Slashes extends CustomPainter {
  Slashes(this.base, this.shaded);

  final Color base;

  /// A light sidebar: the slashes are shades darker instead of lighter.
  final bool shaded;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // The logo's slashes lean about 0.3 across for each 1 up.
    const lean = 0.3;
    const band = 46.0, gap = 18.0;
    for (final (i, (tall, light)) in [(0.20, 0.030), (0.29, 0.045), (0.38, 0.060)].indexed) {
      final left = w * 0.10 + i * (band + gap);
      final top = h * (1 - tall);
      final rise = h - top;
      final path = Path()
        ..moveTo(left, h)
        ..lineTo(left + band, h)
        ..lineTo(left + band + rise * lean, top)
        ..lineTo(left + rise * lean, top)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Color.lerp(base, shaded ? Colors.black : Colors.white, light)!,
              Color.lerp(base, shaded ? Colors.black : Colors.white, light)!.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromLTWH(0, top, w, rise)),
      );
    }
  }

  @override
  bool shouldRepaint(Slashes old) => old.base != base || old.shaded != shaded;
}
