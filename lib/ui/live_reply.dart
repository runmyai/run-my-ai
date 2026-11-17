import 'dart:math';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../state/motion.dart';
import 'markdown/md_live.dart';
import 'markdown/reveal_text.dart';

export 'markdown/reveal_text.dart' show LiveEdge;

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
/// The reply is drawn from its markdown as it is written (lib/ui/markdown/md_live.dart). Where the edge is can be read
/// through [edge] (the tests check the flow with it). Finished blocks are not built or laid out again as the reply
/// grows, so a long reply stays light. Once the reply is done and all of it is out, [done] (the normal message)
/// takes its place.
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


  /// The edge as the text being drawn reads it; a new view of the text (its key) for a text that is not a
  /// continuation.
  final _reveal = Reveal();
  int _view = 0;

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
        _view++;
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
    _reveal.dispose();
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

    _reveal.update(_edge, (softness: _m.softness, ink: ink, pen: pen, shade: _m.inkShade), widget.edge);
    // Start: the first line rises into place over a quarter of a second. (Always wrapped, so the drawn text keeps
    // its place in the tree, and what it built, when the slide ends.)
    var rise = 0.0;
    if (_fresh && _m.startSlide && _startedAt != null && now - _startedAt! < 0.25) {
      rise = 8 * (1 - Curves.easeOutCubic.transform(((now - _startedAt!) / 0.25).clamp(0.0, 1.0)));
    }
    return Transform.translate(
      offset: Offset(0, rise),
      child: MarkdownLive(key: ValueKey(_view), text: _text, edge: _edge, style: style, reveal: _reveal),
    );
  }
}
