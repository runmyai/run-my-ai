import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'md_parse.dart';

/// How the edge of a reply being written looks: how many letters ahead of it fade in ([softness]), how many behind
/// it are fresh ink ([ink], drawn at [shade] of the full colour), and the strength of the dot riding it ([pen]).
typedef RevealLooks = ({double softness, double ink, double pen, double shade});

const _plainLooks = (softness: 0.0, ink: 0.0, pen: 0.0, shade: 1.0);

/// Where the edge of the reply being written is on screen.
class LiveEdge {
  RenderRevealText? _box;

  /// The line the edge is on (global top and bottom) and how far along it the edge is (0-1); null while no reply
  /// is being shown.
  ({double top, double bottom, double along})? get line {
    final box = _box;
    if (box == null || !box.attached || !box.hasSize) return null;
    final top = box.localToGlobal(Offset(0, box._at.top)).dy;
    return (
      top: top,
      bottom: top + box._at.bottom - box._at.top,
      along: box.size.width <= 0 ? 1.0 : (box._at.x / box.size.width).clamp(0.0, 1.0),
    );
  }
}

/// The edge of the reply being written, as a place in the reply's text (characters, with a fraction), shared by every
/// [RevealText] of the part being written. Each draws its text up to the edge; the one the edge is in (the last that
/// starts at or before it) draws the edge's touches and is what [LiveEdge] reports.
class Reveal extends ChangeNotifier {
  double _edge = 0;
  RevealLooks _looks = _plainLooks;
  LiveEdge? _liveEdge;
  final _leaves = <RenderRevealText>[];
  RenderRevealText? _holder;
  bool _holderKnown = false;

  double get edge => _edge;
  RevealLooks get looks => _looks;

  void update(double edge, RevealLooks looks, LiveEdge? liveEdge) {
    if (liveEdge != _liveEdge) {
      _liveEdge = liveEdge;
      _holderKnown = false;
    }
    if (edge == _edge && looks == _looks) return;
    if (edge != _edge) _holderKnown = false;
    _edge = edge;
    _looks = looks;
    notifyListeners();
  }

  RenderRevealText? get holder {
    if (!_holderKnown) {
      _holderKnown = true;
      // The last text starting at or before the edge; before the first one, the first.
      RenderRevealText? before, first;
      for (final l in _leaves) {
        if (l.start <= _edge && (before == null || l.start >= before.start)) before = l;
        if (first == null || l.start < first.start) first = l;
      }
      final best = before ?? first;
      _holder = best;
      _liveEdge?._box = best;
    }
    return _holder;
  }

  void _add(RenderRevealText leaf) {
    _leaves.add(leaf);
    _regroup();
  }

  void _remove(RenderRevealText leaf) {
    _leaves.remove(leaf);
    if (_holder == leaf) _holder = null;
    _regroup();
  }

  void _regroup() {
    _holderKnown = false;
    for (final l in _leaves) {
      l.markNeedsPaint();
    }
  }
}

/// Text of the part of a reply being written, drawn up to the [reveal]'s edge: everything before it fully, the next
/// letters faintly (fading out), the letters just behind it a little lighter (fresh ink), nothing after it. It is
/// only as tall as the line the edge is on. [text] shows [runs] in order: a text run as its text, a newline run as
/// one line break, a formula as its TeX. [start] is where it starts in the reply's text.
class RevealText extends LeafRenderObjectWidget {
  const RevealText({
    super.key,
    required this.text,
    required this.runs,
    required this.start,
    required this.reveal,
    this.textAlign = TextAlign.start,
  });

  final TextSpan text;
  final TextAlign textAlign;
  final List<MdRun> runs;
  final int start;
  final Reveal reveal;

  @override
  RenderRevealText createRenderObject(BuildContext context) => RenderRevealText(
    text,
    runs,
    start,
    reveal,
    MediaQuery.textScalerOf(context),
    Directionality.of(context),
    textAlign,
  );

  @override
  void updateRenderObject(BuildContext context, RenderRevealText renderObject) => renderObject
    ..text = text
    ..runs = runs
    ..start = start
    ..reveal = reveal
    ..textAlign = textAlign
    ..textScaler = MediaQuery.textScalerOf(context);
}

class RenderRevealText extends RenderBox {
  RenderRevealText(
    TextSpan text,
    this._runs,
    this._start,
    this._reveal,
    TextScaler scaler,
    TextDirection direction,
    TextAlign align,
  ) : _painter = TextPainter(text: text, textScaler: scaler, textDirection: direction, textAlign: align);

  final TextPainter _painter;
  List<MdRun> _runs;
  int _start;
  Reveal _reveal;

  /// Where this text starts in the reply's text.
  int get start => _start;
  set start(int value) {
    if (value == _start) return;
    _start = value;
    if (attached) _reveal._regroup();
  }

  /// The edge in this text's own letters, and whether this text holds the reply's edge.
  double _edge = 0;
  bool _holds = false;

  /// The width the painter was last laid out at (null: the text changed since).
  double? _laidAt;
  double _maxWidth = double.infinity;

  /// The edge's place in the laid-out text: across, and the top and bottom of its line.
  ({double x, double top, double bottom}) _at = (x: 0, top: 0, bottom: 0);

  set text(TextSpan value) {
    if (_painter.text == value) return;
    _painter.text = value;
    _laidAt = null;
    markNeedsLayout();
  }

  set runs(List<MdRun> value) {
    if (identical(value, _runs)) return;
    _runs = value;
    markNeedsLayout();
  }

  set textAlign(TextAlign value) {
    if (_painter.textAlign == value) return;
    _painter.textAlign = value;
    _laidAt = null;
    markNeedsLayout();
  }

  set textScaler(TextScaler value) {
    if (_painter.textScaler == value) return;
    _painter.textScaler = value;
    _laidAt = null;
    markNeedsLayout();
  }

  set reveal(Reveal value) {
    if (value == _reveal) return;
    if (attached) {
      _reveal.removeListener(_moved);
      _reveal._remove(this);
      value.addListener(_moved);
      value._add(this);
    }
    _reveal = value;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _reveal.addListener(_moved);
    _reveal._add(this);
  }

  @override
  void detach() {
    _reveal.removeListener(_moved);
    _reveal._remove(this);
    super.detach();
  }

  @override
  void dispose() {
    _painter.dispose();
    super.dispose();
  }

  static int _length(MdRun r) => switch (r.kind) {
    RunKind.text => r.to - r.from,
    RunKind.newline => 1,
    _ => r.tex!.length,
  };

  /// The reply's edge in this text's letters.
  double _localEdge() {
    final e = _reveal.edge;
    var p = 0.0;
    for (final r in _runs) {
      if (e <= r.from) break;
      final n = _length(r);
      if (e >= r.to) {
        p += n;
        continue;
      }
      if (r.kind == RunKind.text) p += e - r.from;
      break;
    }
    return p;
  }

  void _ensure(double width) {
    if (_laidAt == width) return;
    _painter.layout(maxWidth: width);
    _laidAt = width;
  }

  /// The reply's edge moved, or its looks changed.
  void _moved() {
    final edge = _localEdge();
    final holds = _reveal.holder == this;
    if (edge != _edge) {
      _edge = edge;
      if (!hasSize || _laidAt == null) {
        markNeedsLayout();
      } else {
        _ensure(_maxWidth);
        final at = _place(edge);
        // On a new line the text grows; on the same line only the painting changes.
        if (at.bottom != _at.bottom) {
          markNeedsLayout();
        } else {
          _at = at;
          markNeedsPaint();
        }
      }
    } else if (holds || holds != _holds) {
      markNeedsPaint();
    }
    _holds = holds;
  }

  ({double x, double top, double bottom}) _place(double edge) {
    final length = _painter.plainText.length;
    final i = edge.floor().clamp(0, length);
    final caret = _painter.getOffsetForCaret(TextPosition(offset: i), Rect.zero);
    final height = _painter.getFullHeightForCaret(TextPosition(offset: i), Rect.zero);
    var x = caret.dx;
    final part = edge - i;
    if (part > 0 && i < length) {
      final next = _painter.getOffsetForCaret(TextPosition(offset: i + 1), Rect.zero);
      if (next.dy == caret.dy) x = ui.lerpDouble(caret.dx, next.dx, part)!;
    }
    return (x: x, top: caret.dy, bottom: caret.dy + height);
  }

  bool get _whole => _edge >= _painter.plainText.length;

  Size _sizeFor(BoxConstraints constraints) {
    _ensure(constraints.maxWidth);
    _edge = _localEdge();
    _at = _place(_edge);
    final height = _whole ? _painter.height : max(_at.bottom, _painter.preferredLineHeight);
    return constraints.constrain(Size(_painter.width, height));
  }

  @override
  void performLayout() {
    _maxWidth = constraints.maxWidth;
    size = _sizeFor(constraints);
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final (edge, at) = (_edge, _at);
    final s = _sizeFor(constraints);
    _edge = edge;
    _at = at;
    _laidAt = null;
    return s;
  }

  double _intrinsic(double Function() read) {
    _painter.layout();
    _laidAt = null;
    return read();
  }

  @override
  double computeMinIntrinsicWidth(double height) => _intrinsic(() => _painter.minIntrinsicWidth);

  @override
  double computeMaxIntrinsicWidth(double height) => _intrinsic(() => _painter.maxIntrinsicWidth);

  @override
  double computeMinIntrinsicHeight(double width) => computeDryLayout(BoxConstraints(maxWidth: width)).height;

  @override
  double computeMaxIntrinsicHeight(double width) => computeMinIntrinsicHeight(width);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    _ensure(_maxWidth);
    return _painter.computeDistanceToActualBaseline(baseline);
  }

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(PaintingContext context, Offset offset) {
    _ensure(_maxWidth);
    final canvas = context.canvas;
    final holds = _reveal.holder == this;
    _holds = holds;
    if (!holds) {
      // Not where the edge is: all of it (it is behind the edge), or nothing yet.
      if (_whole) _painter.paint(canvas, offset);
      if (_edge <= 0 || _whole) return;
    }
    final looks = holds ? _reveal.looks : _plainLooks;
    final box = offset & size;
    final fontSize = _painter.text?.style?.fontSize ?? 14;
    // About the width of a letter.
    final letter = fontSize * 0.5;
    final x = offset.dx + _at.x;
    final top = offset.dy + _at.top;
    // On the edge's line, left to right: fully there; a little lighter just behind the edge (fresh ink); fading out
    // over the letters ahead of it; nothing after. Lines below the edge's are not shown yet.
    final trail = looks.ink * letter;
    final lead = max(looks.softness * letter, 0.5);
    final inked = trail > 0.5;
    final from = inked ? x - trail : x - 0.01;
    // Only the few letters of fresh ink and fade go through an off-screen layer; the rest is drawn as it is.
    final zone = Rect.fromLTRB(max(box.left, from), top, min(box.right, x + lead), box.bottom);
    void paintIn(Rect clip) {
      canvas.save();
      canvas.clipRect(clip);
      _painter.paint(canvas, offset);
      canvas.restore();
    }

    // The lines above the edge's.
    if (top > box.top) paintIn(Rect.fromLTRB(box.left, box.top, box.right, top));
    // The edge's line, up to the fresh ink (or the edge).
    if (zone.left > box.left) paintIn(Rect.fromLTRB(box.left, top, zone.left, box.bottom));
    // The fresh ink and the fade, through the layer. The gradient holds its first colour before its start and its
    // last after its end.
    if (zone.width > 0 && zone.height > 0) {
      final span = x + lead - from;
      canvas.save();
      canvas.clipRect(zone);
      canvas.saveLayer(zone, Paint());
      _painter.paint(canvas, offset);
      canvas.drawRect(
        zone,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = ui.Gradient.linear(
            Offset(from, 0),
            Offset(x + lead, 0),
            [
              const Color(0xFFFFFFFF),
              Color.fromRGBO(255, 255, 255, inked ? looks.shade : 1.0),
              const Color(0x00FFFFFF),
            ],
            [0, (x - from) / span, 1],
          ),
      );
      canvas.restore();
      canvas.restore();
    }
    // The pen tip: a small dot at the edge, in the text's colour.
    if (looks.pen > 0) {
      final color = _painter.text?.style?.color ?? const Color(0xFF000000);
      canvas.drawCircle(
        Offset(x + 3, top + (_at.bottom - _at.top) / 2),
        2.6,
        Paint()..color = color.withValues(alpha: color.a * looks.pen.clamp(0.0, 1.0)),
      );
    }
  }
}
