import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../state/motion.dart';

/// The reply being written, shown so it flows in smoothly at any speed (from a few tokens a second to thousands),
/// in the fixed way [Motion] describes:
///
/// - Even pace: the pieces of the reply come out evenly over the moments between them, never more than a few
///   tenths of a second behind, so the real speed is always felt (it speeds up when the model does).
/// - Momentum: the edge speeds up and eases off smoothly instead of moving in straight steps.
/// - The edge: text is painted in by an edge that glides along the line, pixel by pixel, then on to the next line.
///   Everything behind it is fully there; just ahead of it the next letters show faintly, fading out ("softness").
///   Nothing pops in, neither words nor letters.
/// - Pen tip, fresh ink, the reply's start sliding in and its finish settling: smaller touches, each a setting.
///
/// Where the edge is can be read through [edge] (the tests check the flow with it). Finished paragraphs are not laid out
/// again as the reply grows, so a long reply stays light. Once the reply is done and all of it is out, [done]
/// (the normal message) takes its place.
class LiveReply extends StatefulWidget {
  const LiveReply({
    super.key,
    required this.text,
    required this.live,
    required this.style,
    required this.done,
    this.motion = const Motion(),
    this.edge,
  });

  /// The reply so far.
  final String text;

  /// More of it is still coming.
  final bool live;
  final TextStyle style;
  final Widget done;
  final Motion motion;

  /// Where the edge is on screen.
  final LiveEdge? edge;

  /// The reaction time of the momentum at [tokensPerSecond]: [base] up to 35 tokens a second, 0.02 s from 45, and
  /// evenly in between. Fast, the text flows evenly anyway, and more momentum would only add lag.
  static double reactionAt(double base, double tokensPerSecond) {
    const fast = 0.02;
    return fast + (base - fast) * ((45 - tokensPerSecond) / 10).clamp(0.0, 1.0);
  }

  /// How many letters behind the edge are fresh ink: those written in the last [settle] seconds at [speed] letters
  /// a second, but never more than [cap], so it stays a small hint at the edge however fast the reply comes.
  static double inkLetters(double speed, double settle, double cap) => min(cap, speed * settle);

  @override
  State<LiveReply> createState() => _LiveReplyState();
}

/// Where the edge of the reply being written is on screen.
class LiveEdge {
  _RenderFlowing? _box;

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

/// One piece of the reply: its characters come out evenly between [start] and [end] (seconds).
class _Piece {
  _Piece(this.from, this.to, this.start, this.end);

  final int from;
  final int to;
  final double start;
  final double end;
}

class _LiveReplyState extends State<LiveReply> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_frame);

  /// The time of the frame being drawn, so each frame shows the reply exactly as of the moment it is on screen.
  double get _now => SchedulerBinding.instance.currentFrameTimeStamp.inMicroseconds / 1e6;

  String _text = '';

  /// Pieces still coming out, in order (even pace).
  final _pieces = <_Piece>[];

  /// Where the edge should be (characters, with a fraction) and where it is; its speed (characters a second).
  double _target = 0;
  double _edge = 0;
  double _speed = 0;

  /// The time between pieces, smoothed.
  double _gap = 0.05;
  double? _lastArrival;
  double _lastFrame = 0;

  /// When the edge last moved (for the pen tip's pulse), when the first text came out (start slide), and when
  /// all of it was out after the reply ended (finish settle).
  double _movedAt = 0;
  double? _startedAt;
  double? _endedAt;


  /// The paragraphs before the edge's are done: they end at [_doneEnd] (the start of the edge's paragraph), and
  /// are built once each ([_doneWidgets], in the [_doneStyle] they were built with), not again every frame.
  int _doneEnd = 0;
  final _doneWidgets = <Widget>[];
  TextStyle? _doneStyle;

  /// The reply was empty when this view started (a new reply, not a chat opened midway).
  late final bool _fresh = widget.text.isEmpty;
  bool _finished = false;

  Motion get _m => widget.motion;

  @override
  void initState() {
    super.initState();
    // Opened while the reply is being written: what is there already shows at once.
    _text = widget.text;
    _target = _edge = _text.length.toDouble();
    _finished = !widget.live;
  }

  @override
  void didUpdateWidget(LiveReply old) {
    super.didUpdateWidget(old);
    if (widget.text != _text) {
      if (widget.text.startsWith(_text)) {
        _arrive(widget.text.length);
      } else {
        // Not a continuation (should not happen): show it as it is, its paragraphs built afresh.
        _pieces.clear();
        _text = widget.text;
        _target = _edge = _text.length.toDouble();
        _doneEnd = 0;
        _doneWidgets.clear();
      }
    }
    if (widget.live) {
      _finished = false;
      _endedAt = null;
    }
    if (!_finished && !_ticker.isActive) {
      _lastFrame = _now;
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  /// The reply grew to [length] characters. With even pace the new piece comes out evenly over about the time
  /// until the next one (at most 0.35 s), after the pieces before it, but never more than 0.35 s behind;
  /// without it, it is all there at once.
  void _arrive(int length) {
    final now = _now;
    final from = _text.length;
    _text = widget.text;
    final last = _lastArrival;
    _lastArrival = now;
    if (last != null) _gap = _gap * 0.7 + max(now - last, 0.001) * 0.3;
    if (!_m.evenPace) {
      _pieces.clear();
      _target = length.toDouble();
      return;
    }
    var start = max(now, _pieces.isEmpty ? now : _pieces.last.end);
    var end = start + min(_gap, 0.35);
    if (end - now > 0.35) {
      end = now + 0.35;
      start = min(start, end);
    }
    _pieces.add(_Piece(from, length, start, end));
  }

  void _frame(Duration _) {
    final now = _now;
    final dt = (now - _lastFrame).clamp(0.0, 0.05);
    _lastFrame = now;
    final before = _edge;

    // Where the edge should be.
    while (_pieces.isNotEmpty) {
      final p = _pieces.first;
      if (now >= p.end) {
        _target = p.to.toDouble();
        _pieces.removeAt(0);
        continue;
      }
      if (now > p.start) _target = max(_target, p.from + (p.to - p.from) * (now - p.start) / (p.end - p.start));
      break;
    }
    // The edge: straight there, or (momentum) like a light object pulled towards it, never overshooting and never
    // going back; the pull settles in about the reaction time, which shrinks to none as the reply gets fast (it
    // only adds lag there). Worked out exactly for the frame's time, so it stays smooth however short.
    final reaction = _m.momentum ? LiveReply.reactionAt(_m.reaction, 1 / _gap) : 0.0;
    if (reaction > 0.001 && dt > 0) {
      final w = 4 / reaction;
      final behind = _edge - _target;
      final pull = (_speed + w * behind) * dt;
      final fade = exp(-w * dt);
      _edge = min(_target + (behind + pull) * fade, _target);
      _speed = max((_speed - w * pull) * fade, 0);
      if (_target - _edge < 0.01) _edge = _target;
    } else {
      _speed = dt > 0 ? (_target - _edge) / dt : 0;
      _edge = _target;
    }
    if (_edge > before) _movedAt = now;
    if (_edge > 0 && _startedAt == null) _startedAt = now;

    final out = !widget.live && _pieces.isEmpty && _edge >= _text.length;
    if (out) _endedAt ??= now;
    final settled = out && now - _endedAt! >= (_m.finishSettle ? 0.25 : 0.0);
    final starting = _fresh && _m.startSlide && _startedAt != null && now - _startedAt! < 0.25;
    final busy = _pieces.isNotEmpty ||
        _edge < _target ||
        starting ||
        (out && !settled) ||
        // The pen tip pulses while the reply pauses.
        (_m.penTip && widget.live);
    setState(() => _finished = settled);
    // Nothing moving: no frames until more of the reply comes (or it ends).
    if (!busy || settled) _ticker.stop();
  }

  @override
  Widget build(BuildContext context) {
    if (_finished) return widget.done;
    final style = widget.style;
    final now = _lastFrame;
    // How much of the finish has passed (0 while writing, 1 when settled).
    final ending = _endedAt == null ? 0.0 : (_m.finishSettle ? ((now - _endedAt!) / 0.25).clamp(0.0, 1.0) : 1.0);
    final ink = _m.freshInk ? LiveReply.inkLetters(_speed, _m.inkSettle, _m.inkCap) * (1 - ending) : 0.0;
    final pen = !_m.penTip
        ? 0.0
        : (1 - ending) * (now - _movedAt > 0.15 ? 0.45 + 0.3 * sin((now - _movedAt) * 2 * pi / 1.2) : 0.75);

    // The paragraphs before the edge's are done, built once each; the edge's flows. The edge only moves on, so the
    // done ones are found from where they ended last time (the text is not split again every frame).
    if (_doneStyle != style) {
      // A new look (the theme): the done paragraphs are built again with it.
      _doneStyle = style;
      _doneWidgets.clear();
      _doneEnd = 0;
    }
    while (true) {
      final end = _text.indexOf('\n', _doneEnd);
      if (end < 0 || _edge <= end) break;
      // Laid out like the finished message (which keeps a few pixels at the right for its cursor).
      _doneWidgets.add(Padding(
        padding: const EdgeInsets.only(right: _cursorRoom),
        child: Text(_text.substring(_doneEnd, end), style: style),
      ));
      _doneEnd = end + 1;
    }
    final flowingEnd = _text.indexOf('\n', _doneEnd);
    final children = <Widget>[
      // On a layer of their own: drawn once, not again with each step of the edge below them.
      if (_doneWidgets.isNotEmpty)
        RepaintBoundary(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: List.of(_doneWidgets),
          ),
        ),
      _FlowingParagraph(
        text: _text.substring(_doneEnd, flowingEnd < 0 ? _text.length : flowingEnd),
        style: DefaultTextStyle.of(context).style.merge(style),
        edge: _edge - _doneEnd,
        softness: _m.softness,
        inkLetters: ink,
        inkShade: _m.inkShade,
        pen: pen,
        liveEdge: widget.edge,
      ),
    ];
    Widget body =
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children);
    // Start: the first line rises into place over a quarter of a second.
    if (_fresh && _m.startSlide && _startedAt != null && now - _startedAt! < 0.25) {
      final t = Curves.easeOutCubic.transform(((now - _startedAt!) / 0.25).clamp(0.0, 1.0));
      body = Transform.translate(offset: Offset(0, 8 * (1 - t)), child: body);
    }
    return body;
  }
}

/// The finished message is selectable text, which keeps this much room at the right for its cursor; the reply is
/// laid out the same way, so its lines break in the same places.
const _cursorRoom = 3.0;

/// A paragraph painted up to [edge] (characters, with a fraction): everything before it fully, the next letters
/// faintly, fading out over [softness] letters; the last [inkLetters] before it a little lighter (fresh ink); a
/// dot at the edge with [pen] strength (0 = none). It is only as tall as the line the edge is on.
class _FlowingParagraph extends LeafRenderObjectWidget {
  const _FlowingParagraph({
    required this.text,
    required this.style,
    required this.edge,
    required this.softness,
    required this.inkLetters,
    required this.inkShade,
    required this.pen,
    required this.liveEdge,
  });

  final String text;
  final TextStyle style;
  final double edge;
  final double softness;
  final double inkLetters;

  /// How light fresh ink is (1 = like the rest).
  final double inkShade;
  final double pen;
  final LiveEdge? liveEdge;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFlowing(
        TextSpan(text: text, style: style),
        edge,
        MediaQuery.textScalerOf(context),
        Directionality.of(context),
      )
        ..looks = (softness: softness, ink: inkLetters, pen: pen, shade: inkShade)
        ..liveEdge = liveEdge;

  @override
  void updateRenderObject(BuildContext context, _RenderFlowing r) => r
    ..text = TextSpan(text: text, style: style)
    ..textScaler = MediaQuery.textScalerOf(context)
    ..edge = edge
    ..looks = (softness: softness, ink: inkLetters, pen: pen, shade: inkShade)
    ..liveEdge = liveEdge;
}

class _RenderFlowing extends RenderBox {
  _RenderFlowing(TextSpan text, this._edge, TextScaler scaler, TextDirection direction)
      : _painter = TextPainter(text: text, textScaler: scaler, textDirection: direction);

  final TextPainter _painter;
  double _edge;
  ({double softness, double ink, double pen, double shade}) _looks = (softness: 1, ink: 0, pen: 0, shade: 1);
  LiveEdge? _liveEdge;

  /// The text changed since the last layout (the painter cannot be asked where anything is until it is laid out).
  bool _changed = true;

  /// The edge's place in the laid-out text: across, and the top and bottom of its line.
  ({double x, double top, double bottom}) _at = (x: 0, top: 0, bottom: 0);

  set text(TextSpan value) {
    if (_painter.text == value) return;
    _painter.text = value;
    _changed = true;
    markNeedsLayout();
  }

  set textScaler(TextScaler value) {
    if (_painter.textScaler == value) return;
    _painter.textScaler = value;
    _changed = true;
    markNeedsLayout();
  }

  set edge(double value) {
    if (value == _edge) return;
    _edge = value;
    if (!hasSize || _changed) return markNeedsLayout();
    final at = _place(value);
    // On a new line the paragraph grows; on the same line only the painting changes.
    if (at.bottom != _at.bottom) {
      markNeedsLayout();
    } else {
      _at = at;
      markNeedsPaint();
    }
  }

  set looks(({double softness, double ink, double pen, double shade}) value) {
    if (value == _looks) return;
    _looks = value;
    markNeedsPaint();
  }

  set liveEdge(LiveEdge? value) {
    _liveEdge = value;
    value?._box = this;
  }

  @override
  void detach() {
    if (_liveEdge?._box == this) _liveEdge!._box = null;
    super.detach();
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

  @override
  void performLayout() {
    _painter.layout(maxWidth: max(0, constraints.maxWidth - _cursorRoom));
    _changed = false;
    _at = _place(_edge);
    size = constraints.constrain(Size(_painter.width + _cursorRoom, max(_at.bottom, _painter.preferredLineHeight)));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final box = offset & size;
    final fontSize = _painter.text?.style?.fontSize ?? 14;
    // About the width of a letter.
    final letter = fontSize * 0.5;
    final x = offset.dx + _at.x;
    final top = offset.dy + _at.top;
    // On the edge's line, left to right: fully there; a little lighter just behind the edge (fresh ink); fading out
    // over the letters ahead of it; nothing after. Lines below the edge's are not shown yet.
    final trail = _looks.ink * letter;
    final lead = max(_looks.softness * letter, 0.5);
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
            [const Color(0xFFFFFFFF), Color.fromRGBO(255, 255, 255, inked ? _looks.shade : 1.0), const Color(0x00FFFFFF)],
            [0, (x - from) / span, 1],
          ),
      );
      canvas.restore();
      canvas.restore();
    }
    // The pen tip: a small dot at the edge, in the text's colour.
    if (_looks.pen > 0) {
      final color = _painter.text?.style?.color ?? const Color(0xFF000000);
      canvas.drawCircle(
        Offset(x + 3, top + (_at.bottom - _at.top) / 2),
        2.6,
        Paint()..color = color.withValues(alpha: color.a * _looks.pen.clamp(0.0, 1.0)),
      );
    }
  }
}
