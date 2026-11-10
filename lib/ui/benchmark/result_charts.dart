import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../benchmark/benchmark.dart';
import '../../benchmark/engine_stats.dart' show timeBesideParts;
import '../../theme.dart';
import '../buttons.dart';
import 'chart_colors.dart';

/// Every word of the reply as a bar as tall as the word took; the slow ones stand out. A click picks the word nearest to
/// it (the slowest one close by wins, so a thin spike is easy to hit) and says which, for [onPick].
class WordsChart extends StatefulWidget {
  const WordsChart({super.key, required this.words, required this.onPick, this.picked});

  final List<double> words;
  final void Function(int index) onPick;
  final int? picked;

  @override
  State<WordsChart> createState() => _WordsChartState();
}

class _WordsChartState extends State<WordsChart> {
  int? _hover;

  int _wordAt(double dx, double width) {
    final words = widget.words;
    var k = (dx / width * words.length).floor().clamp(0, words.length - 1);
    final reach = math.max(1, (words.length / width * 4).ceil());
    for (var j = math.max(0, k - reach); j <= math.min(words.length - 1, k + reach); j++) {
      if (words[j] > words[k]) k = j;
    }
    return k;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (widget.words.isEmpty) {
      return Text('The engine gave no times per token.', style: TextStyle(fontSize: 12.5, color: c.textMuted));
    }
    final typical = percentile(widget.words, 0.5);
    return LayoutBuilder(
      builder: (context, box) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onHover: (e) => setState(() => _hover = _wordAt(e.localPosition.dx, box.maxWidth)),
            onExit: (_) => setState(() => _hover = null),
            child: GestureDetector(
              key: const Key('words-chart'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => widget.onPick(_wordAt(d.localPosition.dx, box.maxWidth)),
              child: SizedBox(
                height: 92,
                width: double.infinity,
                child: CustomPaint(
                  painter: _WordsPainter(
                    words: widget.words,
                    picked: widget.picked,
                    hover: _hover,
                    bar: c.textMuted.withValues(alpha: 0.7),
                    slow: ChartColors.of(context, 2),
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
                ? 'Token 1 to ${widget.words.length}. Bars above ${(typical * 1.5).round()} ms are marked.'
                : 'Token ${_hover! + 1}: ${widget.words[_hover!].toStringAsFixed(1)} ms',
            style: TextStyle(fontSize: 12, color: c.textMuted, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}

class _WordsPainter extends CustomPainter {
  _WordsPainter({
    required this.words,
    required this.picked,
    required this.hover,
    required this.bar,
    required this.slow,
    required this.mark,
    required this.typical,
  });

  final List<double> words;
  final int? picked;
  final int? hover;
  final Color bar;
  final Color slow;
  final Color mark;
  final double typical;

  @override
  void paint(Canvas canvas, Size size) {
    final top = math.max(percentile(words, 0.995) * 1.15, 1.0);
    final w = size.width, h = size.height;
    final columns = math.min(words.length, w.floor());
    final each = w / columns;
    for (var i = 0; i < columns; i++) {
      // A column covers several words when there are more words than pixels: its tallest word shows.
      final from = i * words.length ~/ columns, to = math.max(from + 1, (i + 1) * words.length ~/ columns);
      var most = 0.0;
      var at = from;
      for (var k = from; k < to; k++) {
        if (words[k] > most) {
          most = words[k];
          at = k;
        }
      }
      final bh = math.max(1.0, h * (most / top).clamp(0.0, 1.0));
      final isPicked = picked != null && picked! >= from && picked! < to;
      final isHover = hover != null && hover! >= from && hover! < to;
      canvas.drawRect(
        Rect.fromLTWH(i * each, h - bh, math.max(1.0, each - (each > 3 ? 0.8 : 0)), bh),
        Paint()..color = isPicked || isHover ? mark : (words[at] > typical * 1.5 ? slow : bar),
      );
    }
  }

  @override
  bool shouldRepaint(_WordsPainter old) =>
      !identical(old.words, words) || old.picked != picked || old.hover != hover || old.bar != bar;
}

/// How the words' times spread: a histogram with the 50 %, 90 % and 99 % marks, and the numbers.
class SpreadChart extends StatelessWidget {
  const SpreadChart({super.key, required this.words});

  final List<double> words;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (words.isEmpty) return const SizedBox.shrink();
    final stats = WordStats.of(words);
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
              counts: histogram(words, top, 48),
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
  final WordStats stats;
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
      // (A square-root scale keeps the thin tail of slow words visible beside the crowd of typical ones.)
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
class TimePerWord extends StatelessWidget {
  const TimePerWord({super.key, required this.total, required this.parts});

  /// The mean time of a word in milliseconds, and its parts by name.
  final double total;
  final Map<String, double> parts;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (total <= 0) return const SizedBox.shrink();
    final stacked = {for (final e in parts.entries) if (!timeBesideParts.contains(e.key)) e.key: e.value};
    final beside = {for (final e in parts.entries) if (timeBesideParts.contains(e.key)) e.key: e.value};
    final known = stacked.values.fold(0.0, (a, b) => a + b);
    final rest = total - known;
    final shown = <(String, double)>[
      for (final e in stacked.entries) (e.key, e.value),
      if (rest > total * 0.02) (stacked.isEmpty ? 'Everything else' : 'Other', rest),
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
  const LayerHeatMap({super.key, required this.layers, required this.words});

  /// Each layer's counters over the reply, and the words the reply had.
  final List<Map<String, double>> layers;
  final int words;

  @override
  State<LayerHeatMap> createState() => _LayerHeatMapState();
}

class _LayerHeatMapState extends State<LayerHeatMap> {
  String? _metric;

  /// What can be shown, by name: the key of the layer's numbers and how to turn it into a value per layer.
  List<(String, String, double? Function(Map<String, double> layer))> get _metrics {
    final words = math.max(1, widget.words);
    bool has(String key) => widget.layers.any((l) => l.containsKey(key));
    return [
      if (has('stall_ms')) ('SSD wait (ms/token)', 'stall_ms', (l) => l['stall_ms'] == null ? null : l['stall_ms']! / words),
      if (has('misses')) ('Reads from the SSD (per token)', 'misses', (l) => l['misses'] == null ? null : l['misses']! / words),
      if (has('hit_rate_percent'))
        ('Missed in RAM (%)', 'hit_rate_percent', (l) => l['hit_rate_percent'] == null ? null : 100 - l['hit_rate_percent']!),
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
