import 'package:flutter/material.dart';

import '../../benchmark/metrics.dart';
import '../../benchmark/series.dart';
import '../../theme.dart';
import 'chart_colors.dart';

/// The share of its limit from which a value's bar turns amber.
const nearLimit = 0.9;

/// The live cards of a run, one per row: Speed, each graphics card, CPU, RAM and SSD, at the latest reading. Each value
/// that has one is drawn with a thin bar against its limit; a value the PC does not give is left out, and so is a card
/// with none. The Speed card stays, with [speedNote] under its name when it has nothing to show (warming up).
class MetricCards extends StatelessWidget {
  const MetricCards({super.key, required this.series, required this.rows, this.speedNote});

  final RunSeries series;
  final List<MetricRow> rows;
  final String? speedNote;

  @override
  Widget build(BuildContext context) {
    final index = series.length - 1;
    bool shown(MetricLine l) => index >= 0 && series.at(l.id, index) != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows)
          if (row.id == 'speed' || row.lines.any(shown))
            _MetricCard(
              row: row,
              lines: [for (final l in row.lines) if (shown(l)) l],
              series: series,
              index: index,
              note: row.id == 'speed' && !row.lines.any(shown) ? speedNote : null,
            ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.row, required this.lines, required this.series, required this.index, this.note});

  final MetricRow row;
  final List<MetricLine> lines;
  final RunSeries series;
  final int index;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final subtitle = note ?? row.subtitle;
    return Container(
      key: Key('card-${row.id}'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: c.text.withValues(alpha: 0.035),
        border: Border.all(color: c.text.withValues(alpha: 0.08)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(row.title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.text)),
              if (subtitle != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: c.textMuted)),
                ),
              ],
            ],
          ),
          if (lines.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [for (final line in lines) _Field(line: line, series: series, index: index)],
            ),
          ],
        ],
      ),
    );
  }
}

/// One value of a card: its name, the value (with its limit, where it has one) and a thin bar against that limit.
class _Field extends StatelessWidget {
  const _Field({required this.line, required this.series, required this.index});

  final MetricLine line;
  final RunSeries series;
  final int index;

  static const width = 170.0;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final v = series.at(line.id, index)!;
    final max = line.limitAt(series, index);
    final second = line.second == null ? null : series.at(line.second!, index);
    String n(double x) => formatNumber(x, line.digits);
    final unit = line.unit.isEmpty ? '' : ' ${line.unit}';
    final String text;
    if (second != null) {
      text = '${n(v)} / ${n(second)}${max == null ? '' : ' of ${n(max)}'}$unit';
    } else if (max != null && line.unit != '%') {
      text = '${n(v)} of ${n(max)}$unit';
    } else {
      text = '${n(v)}$unit';
    }
    final share = max == null ? null : (v / max).clamp(0.0, 1.0);
    final near = share != null && share >= nearLimit;
    final fill = near ? ChartColors.of(context, 2) : c.textSecondary;
    return SizedBox(
      key: Key('meter-${line.id}'),
      width: second != null ? width * 1.5 : width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            line.label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: c.textMuted),
          ),
          const SizedBox(height: 3),
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: c.text, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          if (share != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              key: Key('bar-${line.id}'),
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 4,
                child: LayoutBuilder(
                  builder: (context, box) {
                    final rest = second == null ? 0.0 : (second / max!).clamp(0.0, 1.0 - share);
                    return Stack(
                      children: [
                        Container(color: c.text.withValues(alpha: 0.08)),
                        if (rest > 0)
                          Positioned(
                            left: box.maxWidth * share,
                            width: box.maxWidth * rest,
                            top: 0,
                            bottom: 0,
                            child: Container(color: c.textMuted.withValues(alpha: 0.45)),
                          ),
                        Positioned(
                          left: 0,
                          width: box.maxWidth * share,
                          top: 0,
                          bottom: 0,
                          child: Container(key: near ? Key('near-${line.id}') : null, color: fill),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
