import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../benchmark/benchmark.dart';
import '../../benchmark/engine_stats.dart' show hasTimeSplit, timeBesideParts;
import '../../theme.dart';
import '../buttons.dart';
import 'chart_colors.dart';

/// A small caption over a chart or a block of numbers.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: TextStyle(fontSize: 12.5, color: context.colors.textMuted)),
  );
}

/// Every token as a bar and how their times spread, each under its caption; a click on a bar says which token it is, for
/// [onPick].
class TokenCharts extends StatefulWidget {
  const TokenCharts({super.key, required this.tokens, required this.onPick});

  final List<double> tokens;
  final void Function(int index) onPick;

  @override
  State<TokenCharts> createState() => _TokenChartsState();
}

class _TokenChartsState extends State<TokenCharts> {
  int? _picked;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('Every token: click one to see that moment in the graphs'),
        TokensChart(
          tokens: widget.tokens,
          picked: _picked,
          onPick: (k) {
            setState(() => _picked = k);
            widget.onPick(k);
          },
        ),
        const SizedBox(height: 18),
        const SectionLabel('How the times spread'),
        SpreadChart(tokens: widget.tokens),
      ],
    );
  }
}

/// Every token of the reply as a bar as tall as the token took; the slow ones stand out. A click picks the token nearest to
/// it (the slowest one close by wins, so a thin spike is easy to hit) and says which, for [onPick].
class TokensChart extends StatefulWidget {
  const TokensChart({super.key, required this.tokens, required this.onPick, this.picked});

  final List<double> tokens;
  final void Function(int index) onPick;
  final int? picked;

  @override
  State<TokensChart> createState() => _TokensChartState();
}

class _TokensChartState extends State<TokensChart> {
  int? _hover;

  int _tokenAt(double dx, double width) {
    final tokens = widget.tokens;
    if (tokens.isEmpty || width <= 0) return 0;
    return (dx / width * tokens.length).floor().clamp(0, tokens.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (widget.tokens.isEmpty) {
      return Text('The engine gave no times per token.', style: TextStyle(fontSize: 12.5, color: c.textMuted));
    }
    final typical = percentile(widget.tokens, 0.5);
    return LayoutBuilder(
      builder: (context, box) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onHover: (e) => setState(() => _hover = _tokenAt(e.localPosition.dx, box.maxWidth)),
            onExit: (_) => setState(() => _hover = null),
            child: GestureDetector(
              key: const Key('tokens-chart'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => widget.onPick(_tokenAt(d.localPosition.dx, box.maxWidth)),
              child: SizedBox(
                height: 92,
                width: double.infinity,
                child: CustomPaint(
                  painter: _TokensPainter(
                    tokens: widget.tokens,
                    picked: widget.picked,
                    hover: _hover,
                    bar: c.textMuted.withValues(alpha: 0.65),
                    slow: ChartColors.of(context, 2),
                    fast: ChartColors.of(context, 0),
                    mark: c.text,
                    typical: typical,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _hover == null
                ? 'Token 1 to ${widget.tokens.length} · Fast (< ${(typical * 0.85).round()} ms) in blue, slow (> ${(typical * 1.5).round()} ms) in yellow.'
                : 'Token ${_hover! + 1}: ${widget.tokens[_hover!].toStringAsFixed(1)} ms',
            style: TextStyle(fontSize: 12, color: c.textMuted, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}

class _TokensPainter extends CustomPainter {
  _TokensPainter({
    required this.tokens,
    required this.picked,
    required this.hover,
    required this.bar,
    required this.slow,
    required this.fast,
    required this.mark,
    required this.typical,
  });

  final List<double> tokens;
  final int? picked;
  final int? hover;
  final Color bar;
  final Color slow;
  final Color fast;
  final Color mark;
  final double typical;

  @override
  void paint(Canvas canvas, Size size) {
    final top = math.max(percentile(tokens, 0.995) * 1.15, 1.0);
    final w = size.width, h = size.height;
    final columns = math.min(tokens.length, w.floor());
    if (columns <= 0) return;
    final each = w / columns;
    for (var i = 0; i < columns; i++) {
      // A column covers several tokens when there are more tokens than pixels: its tallest token shows.
      final from = i * tokens.length ~/ columns, to = math.max(from + 1, (i + 1) * tokens.length ~/ columns);
      var most = 0.0;
      var at = from;
      for (var k = from; k < to; k++) {
        if (tokens[k] > most) {
          most = tokens[k];
          at = k;
        }
      }
      final bh = math.max(1.0, h * (most / top).clamp(0.0, 1.0));
      final isPicked = picked != null && picked! >= from && picked! < to;
      final isHover = hover != null && hover! >= from && hover! < to;

      Color color;
      if (isPicked || isHover) {
        color = mark;
      } else if (tokens[at] > typical * 1.5) {
        color = slow;
      } else if (tokens[at] < typical * 0.85) {
        color = fast;
      } else {
        color = bar;
      }

      canvas.drawRect(
        Rect.fromLTWH(i * each, h - bh, math.max(1.0, each - (each > 3 ? 0.8 : 0)), bh),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_TokensPainter old) =>
      !identical(old.tokens, tokens) ||
      old.picked != picked ||
      old.hover != hover ||
      old.bar != bar ||
      old.slow != slow ||
      old.fast != fast;
}

/// How the tokens' times spread: a histogram with the 50 %, 90 % and 99 % marks, and the numbers.
class SpreadChart extends StatelessWidget {
  const SpreadChart({super.key, required this.tokens});

  final List<double> tokens;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (tokens.isEmpty) return const SizedBox.shrink();
    final stats = TokenStats.of(tokens);
    final top = math.max(stats.p99 * 1.25, stats.max.clamp(0, stats.p99 * 3).toDouble());
    Widget chip(String label, double ms) => Padding(
      padding: const EdgeInsets.only(right: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${ms.toStringAsFixed(ms < 100 ? 1 : 0)} ms', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: c.text)),
          Text(label, style: TextStyle(fontSize: 12, color: c.textMuted)),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          children: [
            chip('median (p50)', stats.p50),
            chip('p90', stats.p90),
            chip('p99', stats.p99),
            chip('slowest token', stats.max),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 64,
          width: double.infinity,
          child: CustomPaint(
            painter: _SpreadPainter(
              counts: histogram(tokens, top, 48),
              top: top,
              stats: stats,
              bar: ChartColors.of(context, 0).withValues(alpha: 0.75),
              mark: c.text,
              muted: c.textMuted,
            ),
          ),
        ),
      ],
    );
  }
}

class _SpreadPainter extends CustomPainter {
  _SpreadPainter({
    required this.counts,
    required this.top,
    required this.stats,
    required this.bar,
    required this.mark,
    required this.muted,
  });

  final List<int> counts;
  final double top;
  final TokenStats stats;
  final Color bar;
  final Color mark;
  final Color muted;

  @override
  void paint(Canvas canvas, Size size) {
    final peak = counts.reduce(math.max);
    if (peak == 0) return;
    final w = size.width, h = size.height - 14;
    final each = w / counts.length;
    for (var i = 0; i < counts.length; i++) {
      // (A square-root scale keeps the thin tail of slow tokens visible beside the crowd of typical ones.)
      final bh = counts[i] == 0 ? 0.0 : math.max(1.5, h * math.sqrt(counts[i] / peak));
      canvas.drawRect(Rect.fromLTWH(i * each + 0.5, h - bh, each - 1, bh), Paint()..color = bar);
    }
    void rule(double ms, String label) {
      final x = (ms / top).clamp(0.0, 1.0) * w;
      canvas.drawLine(Offset(x, 0), Offset(x, h), Paint()..color = mark.withValues(alpha: 0.6));
      final tp = TextPainter(
        text: TextSpan(text: label, style: TextStyle(fontSize: 11, color: muted)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(math.min(x + 3, w - tp.width), h + 1));
    }

    rule(stats.p50, 'p50');
    rule(stats.p90, 'p90');
    rule(stats.p99, 'p99');
  }

  @override
  bool shouldRepaint(_SpreadPainter old) => old.counts != counts || old.top != top;
}

/// Where the time per token went: one bar cut in the parts the engine measured, and what is left. The graphics card's
/// kernels run beside the CPU's work, so they are named under the bar and not cut out of it.
class TimePerToken extends StatelessWidget {
  const TimePerToken({super.key, required this.total, required this.parts});

  /// The mean time of a token in milliseconds, and its parts by name.
  final double total;
  final Map<String, double> parts;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (total <= 0 || !hasTimeSplit(parts)) return const SizedBox.shrink();
    final stacked = {for (final e in parts.entries) if (!timeBesideParts.contains(e.key)) e.key: e.value};
    final beside = {for (final e in parts.entries) if (timeBesideParts.contains(e.key)) e.key: e.value};
    final known = stacked.values.fold(0.0, (a, b) => a + b);
    final rest = total - known;
    final shown = <(String, double)>[
      for (final e in stacked.entries) (e.key, e.value),
      // (The engine's own leftover already came in as a part; this is the gap between the parts and the whole token:
      // the server's work around each token, outside its compute.)
      if (rest > total * 0.02) ('Sampling and server', rest),
    ];
    final width = math.max(total, known);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 24,
            child: Row(
              children: [
                for (final (name, ms) in shown)
                  Expanded(
                    flex: math.max(1, (ms / width * 1000).round()),
                    child: Tooltip(
                      message: '$name: ${ms.toStringAsFixed(1)} ms',
                      child: Container(color: ChartColors.part(context, name).withValues(alpha: 0.9)),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 18,
          runSpacing: 4,
          children: [
            for (final (name, ms) in shown)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 9, height: 9, decoration: BoxDecoration(color: ChartColors.part(context, name), borderRadius: BorderRadius.circular(3))),
                  const SizedBox(width: 6),
                  Text(
                    '$name ${ms.toStringAsFixed(1)} ms (${(100 * ms / total).round()} %)',
                    style: TextStyle(fontSize: 12.5, color: c.textSecondary, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
            Text('${total.toStringAsFixed(1)} ms in all', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
          ],
        ),
        for (final e in beside.entries)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 9, height: 9, decoration: BoxDecoration(border: Border.all(color: ChartColors.part(context, e.key)), borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    '${e.key} kernels ${e.value.toStringAsFixed(1)} ms/token, running beside the CPU work (not added to the bar)',
                    style: TextStyle(fontSize: 12.5, color: c.textMuted),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One cell for each streamed layer, as dark as that layer's number is high: where the SSD is waited on.
class LayerHeatMap extends StatefulWidget {
  const LayerHeatMap({super.key, required this.layers, required this.tokens});

  /// Each layer's counters over the reply, and the tokens the reply had.
  final List<Map<String, double>> layers;
  final int tokens;

  @override
  State<LayerHeatMap> createState() => _LayerHeatMapState();
}

class _LayerHeatMapState extends State<LayerHeatMap> {
  String? _metric;

  /// What can be shown, by name: the key of the layer's numbers and how to turn it into a value per layer.
  List<(String, String, double? Function(Map<String, double> layer))> get _metrics {
    final tokens = math.max(1, widget.tokens);
    bool has(String key) => widget.layers.any((l) => l.containsKey(key));
    return [
      if (has('stall_ms')) ('SSD wait (ms/token)', 'stall_ms', (l) => l['stall_ms'] == null ? null : l['stall_ms']! / tokens),
      if (has('misses')) ('Reads from the SSD (per token)', 'misses', (l) => l['misses'] == null ? null : l['misses']! / tokens),
      if (has('hit_rate_percent'))
        ('Missed in RAM (%)', 'hit_rate_percent', (l) => l['hit_rate_percent'] == null ? null : 100 - l['hit_rate_percent']!),
      if (has('vram_hits'))
        (
          'VRAM hits (%)',
          'vram_hit_percent',
          (l) {
            final vram = l['vram_hits'];
            final all = (l['hits'] ?? 0) + (l['misses'] ?? 0) + (vram ?? 0);
            return vram == null || all <= 0 ? null : 100 * vram / all;
          },
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final metrics = _metrics;
    if (metrics.isEmpty) return Text('The engine gave no numbers per layer.', style: TextStyle(fontSize: 12.5, color: c.textMuted));
    final chosen = metrics.firstWhere((m) => m.$2 == _metric, orElse: () => metrics.first);
    final values = [for (final l in widget.layers) chosen.$3(l)];
    final top = values.whereType<double>().fold(0.0, math.max);
    final color = ChartColors.of(context, 2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (metrics.length > 1)
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final m in metrics) OptionPill(label: m.$1, chosen: m == chosen, onTap: () => setState(() => _metric = m.$2)),
            ],
          )
        else
          Text(chosen.$1, style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 3,
          runSpacing: 3,
          children: [
            for (var i = 0; i < values.length; i++)
              Tooltip(
                message: 'Layer ${i + 1}: ${values[i] == null ? '–' : values[i]!.toStringAsFixed(2)}',
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: values[i] == null || top <= 0
                        ? c.text.withValues(alpha: 0.06)
                        : color.withValues(alpha: 0.12 + 0.88 * (values[i]! / top).clamp(0.0, 1.0)),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text('Layer 1 first. Darkest: ${top.toStringAsFixed(2)}.', style: TextStyle(fontSize: 12, color: c.textMuted)),
      ],
    );
  }
}
