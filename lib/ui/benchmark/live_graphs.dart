import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../benchmark/hardware.dart';
import '../../benchmark/metrics.dart';
import '../../benchmark/series.dart';
import '../../state/benchmark.dart';
import '../../theme.dart';
import '../clicky.dart';
import 'chart_colors.dart';

/// How a time on the shared axis is written: "42 s", or "2:05" from a minute on.
String formatSeconds(double seconds) {
  final s = seconds.round();
  if (s < 60) return '$s s';
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// A step for the axis' marks that gives about six of them over [domain] seconds.
double niceStep(double domain) {
  const steps = <double>[1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600];
  for (final step in steps) {
    if (domain / step <= 7) return step;
  }
  return steps.last;
}

/// The stretch of the time axis the graphs draw, from [from] to [to] seconds on the run's clock: the whole run, or
/// one window of it stretched over the full width. All the maths between a moment and a place on the axis is here.
class AxisSpan {
  const AxisSpan(this.from, this.to, {this.windowed = false});

  /// The span for a run [runEnd] seconds long, or for [window] (from, to) when one is given. A span is at least a
  /// second wide, so a run or a turn that has only just begun still has an axis.
  factory AxisSpan.of(double runEnd, (double, double)? window) {
    if (window == null) return AxisSpan(0, math.max(runEnd, 1));
    return AxisSpan(window.$1, math.max(window.$2, window.$1 + 1), windowed: true);
  }

  final double from;
  final double to;

  /// Whether this is a window of the run rather than all of it; only a window clips what it draws.
  final bool windowed;

  double get length => to - from;

  /// Where [seconds] falls on an axis [width] pixels wide.
  double x(double seconds, double width) => (seconds - from) / length * width;

  /// The moment [dx] pixels from the left of an axis [width] pixels wide (a place outside it counts as its edge).
  double timeAt(double dx, double width) => from + (dx / width).clamp(0.0, 1.0) * length;

  bool contains(double seconds) => seconds >= from && seconds <= to;

  /// The part of a phase from [start] to [end] that is on this axis, as (start, end); null when none of it is. A
  /// phase that is [open] (still going on, so it has no end yet) reaches the end of the span. The whole run draws
  /// every phase as it is.
  (double, double)? band(double start, double end, {bool open = false}) {
    if (!windowed) return (start, end);
    final last = open ? math.max(end, to) : end;
    if (last <= from || start >= to) return null;
    return (math.max(start, from), math.min(last, to));
  }

  @override
  bool operator ==(Object other) => other is AxisSpan && other.from == from && other.to == to && other.windowed == windowed;

  @override
  int get hashCode => Object.hash(from, to, windowed);
}

/// The graphs of a run on one time axis, in rows: speed, each graphics card, CPU, RAM, SSD and the engine's numbers.
/// The phases of the run (load, warm-up, prompt, reply) are shaded behind every row. Hovering a graph puts a cursor on
/// that moment in all of them and the rows say what each value was then; a click on a line (or on a row) opens the row's
/// detail, with every value against its limit. [cursor] is a moment pinned from outside (a token picked in the result).
/// A [window] (from, to seconds on the run's clock) shows only that stretch, for one turn of the run, stretched over the
/// full width, with the axis counting from its start; without one the graphs show the whole run.
class LiveGraphs extends StatefulWidget {
  const LiveGraphs({
    super.key,
    required this.series,
    required this.cursor,
    this.revision = 0,
    this.counters = EngineCounters.available,
    this.running = false,
    this.gpuNames = const [],
    this.window,
  });

  final RunSeries series;

  /// Counts the ticks of a run going on, so the graphs paint again.
  final int revision;
  final ValueNotifier<double?> cursor;
  final EngineCounters counters;
  final bool running;
  final List<String> gpuNames;
  final (double, double)? window;

  @override
  State<LiveGraphs> createState() => _LiveGraphsState();
}

class _LiveGraphsState extends State<LiveGraphs> {
  double? _hover;
  final _open = <String>{};

  /// The line opened in each open row.
  final _focus = <String, String>{};

  @override
  void initState() {
    super.initState();
    widget.cursor.addListener(_changed);
  }

  @override
  void didUpdateWidget(LiveGraphs old) {
    super.didUpdateWidget(old);
    if (old.cursor != widget.cursor) {
      old.cursor.removeListener(_changed);
      widget.cursor.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.cursor.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  /// The moment to mark: the hovered one, else the one pinned from outside. In a window, a moment outside it is none.
  double? _moment(AxisSpan span) {
    double? inside(double? t) => t == null || !span.windowed || span.contains(t) ? t : null;
    return inside(_hover) ?? inside(widget.cursor.value);
  }

  @override
  Widget build(BuildContext context) {
    final series = widget.series;
    final span = AxisSpan.of(series.end, widget.window);
    final rows = metricRows(series, gpuNames: widget.gpuNames);
    final time = _moment(span);
    // The values the rows say when nothing is hovered or pinned: the latest, or the end of the window.
    final index = series.isEmpty
        ? -1
        : time != null
        ? series.indexAt(time)
        : span.windowed
        ? series.indexAt(span.to)
        : series.length - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows) _row(context, row, index, time, span),
        const SizedBox(height: 2),
        LayoutBuilder(
          builder: (context, box) => SizedBox(
            height: 34,
            width: double.infinity,
            child: CustomPaint(
              painter: _AxisPainter(
                series: series,
                span: span,
                running: widget.running,
                cursor: time,
                text: context.colors.text,
                muted: context.colors.textMuted,
                rule: context.colors.border,
                revision: widget.revision,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, MetricRow row, int index, double? time, AxisSpan span) {
    final c = context.colors;
    final series = widget.series;
    final open = _open.contains(row.id);
    final has = row.hasData(series);
    final visible = open ? row.lines : row.lines.take(3).toList();
    final focus = _focus[row.id];

    Widget summary() {
      if (!has) {
        final waiting = row.id == 'engine' && widget.running && widget.counters != EngineCounters.missing;
        return Text(
          waiting ? 'Waiting for the engine…' : (row.note ?? '–'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, color: c.textMuted),
        );
      }
      final spans = <InlineSpan>[];
      for (var i = 0; i < row.lines.length && spans.length < 5; i++) {
        final line = row.lines[i];
        if (i >= 3 || line.bitmask || index < 0 || series.at(line.id, index) == null) continue;
        if (spans.isNotEmpty) spans.add(TextSpan(text: '   ', style: TextStyle(color: c.textMuted)));
        spans.add(TextSpan(text: '● ', style: TextStyle(color: ChartColors.of(context, i), fontSize: 10)));
        spans.add(TextSpan(text: line.text(series, index), style: TextStyle(color: c.textSecondary)));
      }
      return Text.rich(
        TextSpan(children: spans.isEmpty ? [const TextSpan(text: '–')] : spans),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.end,
        style: TextStyle(fontSize: 12.5, color: c.textSecondary, fontFeatures: const [FontFeature.tabularFigures()]),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Clicky(
            key: Key('graph-row-${row.id}'),
            onTap: () => setState(() => open ? _open.remove(row.id) : _open.add(row.id)),
            radius: 6,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: open ? 0 : -0.25,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(Icons.keyboard_arrow_down, size: 16, color: c.textMuted),
                  ),
                  const SizedBox(width: 4),
                  Text(row.title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.text)),
                  if (row.subtitle != null) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        row.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: c.textMuted),
                      ),
                    ),
                  ],
                  const SizedBox(width: 12),
                  Expanded(child: Align(alignment: Alignment.centerRight, child: summary())),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          LayoutBuilder(
            builder: (context, box) {
              double timeAt(Offset p) => span.timeAt(p.dx, box.maxWidth);
              return MouseRegion(
                cursor: SystemMouseCursors.precise,
                onHover: (e) => setState(() => _hover = series.isEmpty ? null : timeAt(e.localPosition)),
                onExit: (_) => setState(() => _hover = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) {
                    final hit = _nearest(visible, timeAt(d.localPosition), d.localPosition.dy);
                    setState(() {
                      _open.add(row.id);
                      if (hit != null) {
                        _focus[row.id] = hit.id;
                      } else if (open) {
                        _open.remove(row.id);
                      }
                    });
                  },
                  child: SizedBox(
                    height: _chartHeight,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: _RowPainter(
                        series: series,
                        row: row,
                        shown: visible.length,
                        span: span,
                        running: widget.running,
                        cursor: time,
                        focus: focus,
                        colors: [for (var i = 0; i < row.lines.length; i++) ChartColors.of(context, i)],
                        text: c.text,
                        muted: c.textMuted,
                        danger: c.danger,
                        revision: widget.revision,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          if (open && has) _detail(context, row, index, focus, span, time),
        ],
      ),
    );
  }

  static const _chartHeight = 56.0;

  /// The visible line nearest to a click at ([time], [dy]) if one passes within a few pixels.
  MetricLine? _nearest(List<MetricLine> lines, double time, double dy) {
    final series = widget.series;
    final i = series.indexAt(time);
    if (i < 0) return null;
    MetricLine? best;
    var distance = 14.0;
    for (final line in lines) {
      final v = series.at(line.id, i);
      if (v == null || line.bitmask) continue;
      final y = _lineY(line, series, i, v, _chartHeight, line.scale(series));
      if ((y - dy).abs() < distance) {
        distance = (y - dy).abs();
        best = line;
      }
    }
    return best;
  }

  Widget _detail(BuildContext context, MetricRow row, int index, String? focus, AxisSpan span, double? time) {
    final series = widget.series;
    final lines = [for (final l in row.lines) if (series.series(l.id)?.any((v) => v != null) ?? false) l];
    final focused = lines.where((l) => l.id == focus).firstOrNull;
    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 18,
            runSpacing: 10,
            children: [
              for (final line in lines)
                _Meter(
                  line: line,
                  color: ChartColors.of(context, row.lines.indexOf(line)),
                  series: series,
                  index: index,
                  focused: line.id == focus,
                  onTap: () => setState(() => line.id == focus ? _focus.remove(row.id) : _focus[row.id] = line.id),
                ),
            ],
          ),
          if (row.id == 'cpu') ...[const SizedBox(height: 12), _Cores(series: series, index: index)],
          if (focused != null) ...[
            const SizedBox(height: 12),
            _FocusedLine(
              line: focused,
              color: ChartColors.of(context, row.lines.indexOf(focused)),
              series: series,
              span: span,
              running: widget.running,
              cursor: time,
              revision: widget.revision,
              onHover: (t) => setState(() => _hover = t),
            ),
          ],
        ],
      ),
    );
  }
}

/// The y of a point of [line] with value [v] at tick [i] in a chart [h] high.
double _lineY(MetricLine line, RunSeries series, int i, double v, double h, double scale) {
  final max = line.limitAt(series, i) ?? scale;
  final frac = max <= 0 ? 0.0 : (v / max).clamp(0.0, 1.0);
  return h - 3 - frac * (h - 9);
}

class _RowPainter extends CustomPainter {
  _RowPainter({
    required this.series,
    required this.row,
    required this.shown,
    required this.span,
    required this.running,
    required this.cursor,
    required this.focus,
    required this.colors,
    required this.text,
    required this.muted,
    required this.danger,
    required this.revision,
  });

  final RunSeries series;
  final MetricRow row;

  /// How many of the row's lines are drawn (the first few, until the row is opened).
  final int shown;
  final AxisSpan span;

  /// Whether the run is still going on, so its last phase has no end yet.
  final bool running;
  final double? cursor;
  final String? focus;
  final List<Color> colors;
  final Color text;
  final Color muted;
  final Color danger;
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    double x(double seconds) => span.x(seconds, w);
    // A window shows nothing from outside it.
    if (span.windowed) canvas.clipRect(Offset.zero & size);
    // The phases behind the lines.
    for (var k = 0; k < series.phases.length; k++) {
      final p = series.phases[k];
      final band = span.band(p.start, p.end, open: running && k == series.phases.length - 1);
      if (band == null) continue;
      final x0 = x(band.$1), x1 = math.max(x0 + 1, x(band.$2));
      canvas.drawRect(Rect.fromLTRB(x0, 0, x1, h), Paint()..color = text.withValues(alpha: k.isEven ? 0.035 : 0.075));
    }
    canvas.drawLine(Offset(0, h - 0.5), Offset(w, h - 0.5), Paint()..color = muted.withValues(alpha: 0.3));
    canvas.drawLine(
      const Offset(0, 3),
      Offset(w, 3),
      Paint()
        ..color = muted.withValues(alpha: 0.18)
        ..strokeWidth = 1,
    );

    for (var li = 0; li < shown && li < row.lines.length; li++) {
      final line = row.lines[li];
      final column = series.series(line.id);
      if (column == null) continue;
      if (line.bitmask) {
        for (var i = 0; i < column.length; i++) {
          final v = column[i];
          if (v != null && (v.toInt() & heldDownReasons) != 0) {
            canvas.drawRect(Rect.fromLTWH(x(series.times[i]) - 1, h - 4, 3, 4), Paint()..color = danger);
          }
        }
        continue;
      }
      final scale = line.scale(series);
      final dim = focus != null && focus != line.id;
      final color = colors[li].withValues(alpha: dim ? 0.22 : 1);
      final path = Path();
      var pen = false;
      double? firstX, lastX;
      for (var i = 0; i < column.length; i++) {
        final v = column[i];
        if (v == null) {
          pen = false;
          continue;
        }
        final px = x(series.times[i]);
        final py = _lineY(line, series, i, v, h, scale);
        if (pen) {
          path.lineTo(px, py);
        } else {
          path.moveTo(px, py);
          pen = true;
        }
        firstX ??= px;
        lastX = px;
      }
      if (firstX == null) continue;
      if (li == 0 && !dim) {
        final area = Path.from(path)
          ..lineTo(lastX!, h)
          ..lineTo(firstX, h)
          ..close();
        canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.10));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = focus == line.id ? 2 : 1.4
          ..strokeJoin = StrokeJoin.round,
      );
    }

    final at = cursor;
    if (at != null && !series.isEmpty) {
      final cx = x(at.clamp(span.from, span.to));
      canvas.drawLine(Offset(cx, 0), Offset(cx, h), Paint()..color = text.withValues(alpha: 0.55));
      final i = series.indexAt(at);
      for (var li = 0; li < shown && li < row.lines.length; li++) {
        final line = row.lines[li];
        final v = series.at(line.id, i);
        if (v == null || line.bitmask) continue;
        canvas.drawCircle(
            Offset(x(series.times[i]), _lineY(line, series, i, v, h, line.scale(series))), 2.6, Paint()..color = colors[li]);
      }
    }
  }

  @override
  bool shouldRepaint(_RowPainter old) =>
      old.revision != revision ||
      old.cursor != cursor ||
      old.span != span ||
      old.running != running ||
      old.focus != focus ||
      old.shown != shown ||
      old.text != text ||
      !identical(old.series, series);
}

class _AxisPainter extends CustomPainter {
  _AxisPainter({
    required this.series,
    required this.span,
    required this.running,
    required this.cursor,
    required this.text,
    required this.muted,
    required this.rule,
    required this.revision,
  });

  final RunSeries series;
  final AxisSpan span;
  final bool running;
  final double? cursor;
  final Color text;
  final Color muted;
  final Color rule;
  final int revision;

  void _label(Canvas canvas, String s, double x, double y, Color color, {bool centre = false, double width = 90}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: 11.5, color: color)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: width);
    tp.paint(canvas, Offset(centre ? x - tp.width / 2 : x, y));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    double x(double seconds) => span.x(seconds, w);
    if (span.windowed) canvas.clipRect(Offset.zero & size);
    final here = cursor == null ? null : series.phaseAt(cursor!);
    for (var k = 0; k < series.phases.length; k++) {
      final p = series.phases[k];
      final band = span.band(p.start, p.end, open: running && k == series.phases.length - 1);
      if (band == null) continue;
      final x0 = x(band.$1), x1 = math.max(x0 + 1, x(band.$2));
      // A phase that began before the window has no beginning to mark on it.
      if (p.start >= span.from) canvas.drawLine(Offset(x0, 0), Offset(x0, 14), Paint()..color = rule);
      _label(canvas, p.name, x0 + 4, 0, identical(p, here) ? text : muted, width: math.max(10, x1 - x0 - 6));
    }
    // The marks count from the start of the span: "0 s" is its first moment.
    final step = niceStep(span.length);
    for (var t = 0.0; t <= span.length; t += step) {
      final tx = x(span.from + t);
      canvas.drawLine(Offset(tx, 17), Offset(tx, 22), Paint()..color = rule);
      _label(canvas, formatSeconds(t), tx + (t == 0 ? 0 : -14), 21, muted, width: 50);
    }
    final at = cursor;
    if (at != null) {
      final cx = x(at.clamp(span.from, span.to));
      canvas.drawLine(Offset(cx, 15), Offset(cx, 24), Paint()..color = text);
    }
  }

  @override
  bool shouldRepaint(_AxisPainter old) =>
      old.revision != revision ||
      old.cursor != cursor ||
      old.span != span ||
      old.running != running ||
      old.text != text ||
      !identical(old.series, series);
}

/// One value of a row against its limit: its name and value, and a bar of how full the limit is.
class _Meter extends StatelessWidget {
  const _Meter({
    required this.line,
    required this.color,
    required this.series,
    required this.index,
    required this.focused,
    required this.onTap,
  });

  final MetricLine line;
  final Color color;
  final RunSeries series;
  final int index;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final v = series.at(line.id, index);
    final max = line.limitAt(series, index) ?? line.scale(series);
    final frac = v == null || line.bitmask || max <= 0 ? 0.0 : (v / max).clamp(0.0, 1.0);
    return Clicky(
      key: Key('meter-${line.id}'),
      onTap: onTap,
      radius: 6,
      selected: focused,
      child: Container(
        width: 196,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: focused ? c.text.withValues(alpha: 0.35) : Colors.transparent),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(line.label, style: TextStyle(fontSize: 12, color: c.textMuted), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              line.text(series, index),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: c.text, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            if (!line.bitmask) ...[
              const SizedBox(height: 5),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Stack(
                  children: [
                    Container(height: 5, color: c.text.withValues(alpha: 0.10)),
                    FractionallySizedBox(widthFactor: frac, child: Container(height: 5, color: color)),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Every core's load at the moment under the cursor, as bars; the tooltip of a bar gives its clock.
class _Cores extends StatelessWidget {
  const _Cores({required this.series, required this.index});

  final RunSeries series;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final loads = <(int, double?)>[];
    for (var n = 0; series.series('cpu.core.$n.load') != null || series.series('cpu.core.$n.mhz') != null; n++) {
      loads.add((n, series.at('cpu.core.$n.load', index)));
    }
    if (loads.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Each core: load (hover for its clock)', style: TextStyle(fontSize: 12, color: c.textMuted)),
        const SizedBox(height: 6),
        SizedBox(
          height: 44,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final (n, load) in loads)
                Expanded(
                  child: Tooltip(
                    message: 'Core ${n + 1}: ${load == null ? '–' : '${load.round()} %'}'
                        '${series.at('cpu.core.$n.mhz', index) == null ? '' : ', ${series.at('cpu.core.$n.mhz', index)!.round()}'
                            '${series.at('cpu.core.$n.mhzMax', index) == null ? '' : ' of ${series.at('cpu.core.$n.mhzMax', index)!.round()}'} MHz'}',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: FractionallySizedBox(
                        heightFactor: ((load ?? 0) / 100).clamp(0.04, 1.0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: ChartColors.of(context, 1).withValues(alpha: load == null ? 0.2 : 0.85),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A line alone, taller, with its limit, and what it was over the span on the axis: the opened detail of a line.
class _FocusedLine extends StatelessWidget {
  const _FocusedLine({
    required this.line,
    required this.color,
    required this.series,
    required this.span,
    required this.running,
    required this.cursor,
    required this.revision,
    required this.onHover,
  });

  final MetricLine line;
  final Color color;
  final RunSeries series;
  final AxisSpan span;
  final bool running;
  final double? cursor;
  final int revision;
  final void Function(double?) onHover;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final low = series.valuesBetween(line.id, span.from, span.to).fold<double?>(null, (a, b) => a == null || b < a ? b : a);
    final high = series.peak(line.id, from: span.from, to: span.to);
    final average = series.average(line.id, from: span.from, to: span.to);
    String f(double? v) => v == null ? '–' : formatNumber(v, line.digits);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${line.label}: lowest ${f(low)}, average ${f(average)}, highest ${f(high)} ${line.unit}',
          style: TextStyle(fontSize: 12, color: c.textSecondary),
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, box) => MouseRegion(
            cursor: SystemMouseCursors.precise,
            onHover: (e) => onHover(span.timeAt(e.localPosition.dx, box.maxWidth)),
            onExit: (_) => onHover(null),
            child: SizedBox(
              height: 96,
              width: double.infinity,
              child: CustomPaint(
                painter: _FocusPainter(
                  line: line,
                  color: color,
                  series: series,
                  span: span,
                  running: running,
                  cursor: cursor,
                  text: c.text,
                  muted: c.textMuted,
                  revision: revision,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FocusPainter extends CustomPainter {
  _FocusPainter({
    required this.line,
    required this.color,
    required this.series,
    required this.span,
    required this.running,
    required this.cursor,
    required this.text,
    required this.muted,
    required this.revision,
  });

  final MetricLine line;
  final Color color;
  final RunSeries series;
  final AxisSpan span;
  final bool running;
  final double? cursor;
  final Color text;
  final Color muted;
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    double x(double seconds) => span.x(seconds, w);
    if (span.windowed) canvas.clipRect(Offset.zero & size);
    for (var k = 0; k < series.phases.length; k++) {
      final p = series.phases[k];
      final band = span.band(p.start, p.end, open: running && k == series.phases.length - 1);
      if (band == null) continue;
      canvas.drawRect(
        Rect.fromLTRB(x(band.$1), 0, math.max(x(band.$1) + 1, x(band.$2)), h),
        Paint()..color = text.withValues(alpha: k.isEven ? 0.035 : 0.075),
      );
    }
    final top = line.scale(series);
    void label(String s, double y) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontSize: 11, color: muted)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(4, y));
    }

    canvas.drawLine(const Offset(0, 4), Offset(w, 4), Paint()..color = muted.withValues(alpha: 0.35));
    label('${formatNumber(top, line.digits)} ${line.unit}', 6);
    label('0', h - 15);
    final column = series.series(line.id);
    if (column == null) return;
    final path = Path();
    var pen = false;
    for (var i = 0; i < column.length; i++) {
      final v = column[i];
      if (v == null) {
        pen = false;
        continue;
      }
      final px = x(series.times[i]);
      final py = h - 4 - (v / top).clamp(0.0, 1.0) * (h - 10);
      if (pen) {
        path.lineTo(px, py);
      } else {
        path.moveTo(px, py);
        pen = true;
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeJoin = StrokeJoin.round,
    );
    final at = cursor;
    if (at != null) {
      final cx = x(at.clamp(span.from, span.to));
      canvas.drawLine(Offset(cx, 0), Offset(cx, h), Paint()..color = text.withValues(alpha: 0.55));
    }
  }

  @override
  bool shouldRepaint(_FocusPainter old) =>
      old.revision != revision ||
      old.cursor != cursor ||
      old.span != span ||
      old.running != running ||
      old.line != line ||
      !identical(old.series, series);
}
