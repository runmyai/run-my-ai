import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../benchmark/benchmark.dart';
import '../../benchmark/metrics.dart';
import '../../benchmark/series.dart';
import '../../benchmark/whole_run.dart';
import '../../theme.dart';

/// Renders modular, fixed-width cards for Speed, GPU(s), CPU, RAM, SSD, and Engine.
/// Cards auto-wrap cleanly across rows using [Wrap]. Inside each card, metrics are
/// displayed in a clean, compact stat grid (Direction B).
class MetricCards extends StatelessWidget {
  const MetricCards({
    super.key,
    required this.series,
    required this.rows,
    this.cursor,
    this.overall = false,
    this.whole,
    this.activeTokenMillis,
  });

  final RunSeries series;
  final List<MetricRow> rows;

  /// Pinned timeline moment (in seconds); null when cursor is inactive or in overall mode.
  final double? cursor;

  /// Whether the whole-run overall mode is active.
  final bool overall;

  /// The whole run data (for latency distribution stats: p50, p90, p99, slowest).
  final WholeRun? whole;

  /// Duration of the currently active token in milliseconds (if inspecting a single token).
  final double? activeTokenMillis;

  int get _sampleIndex {
    if (cursor != null && !series.isEmpty) {
      return series.indexAt(cursor!);
    }
    return series.isEmpty ? -1 : series.length - 1;
  }

  @override
  Widget build(BuildContext context) {
    if (series.isEmpty && rows.isEmpty) {
      return const SizedBox.shrink();
    }
    final index = _sampleIndex;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        const spacing = 12.0;
        const minCardWidth = 280.0;
        final cols = math.max(1, ((totalWidth + spacing) / (minCardWidth + spacing)).floor());
        final cardWidth = (totalWidth - (cols - 1) * spacing) / cols;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
              _MetricCard(
                row: rows[rowIndex],
                rowIndex: rowIndex,
                series: series,
                index: index,
                overall: overall,
                whole: whole,
                activeTokenMillis: activeTokenMillis,
                width: cardWidth,
              ),
          ],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.row,
    required this.rowIndex,
    required this.series,
    required this.index,
    required this.overall,
    required this.width,
    this.whole,
    this.activeTokenMillis,
  });

  final MetricRow row;
  final int rowIndex;
  final RunSeries series;
  final int index;
  final bool overall;
  final double width;
  final WholeRun? whole;
  final double? activeTokenMillis;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isSpeed = row.id == 'speed';
    final tokenStats = whole?.tokenStats;

    return Container(
      key: Key('card-${row.id}'),
      width: width,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.text.withValues(alpha: 0.035),
        border: Border.all(color: c.text.withValues(alpha: 0.08)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.title,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.text),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (row.subtitle != null) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    row.subtitle!,
                    style: TextStyle(fontSize: 11.5, color: c.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
          if (row.note != null) ...[
            const SizedBox(height: 4),
            Text(row.note!, style: TextStyle(fontSize: 11, color: c.textMuted)),
          ],
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, cardConstraints) {
              const colSpacing = 8.0;
              final int cols = (row.lines.length == 3 && cardConstraints.maxWidth >= 360) ? 3 : 2;
              final tileWidth = (cardConstraints.maxWidth - (cols - 1) * colSpacing) / cols;

              return Wrap(
                spacing: colSpacing,
                runSpacing: colSpacing,
                children: [
                  for (final line in row.lines)
                    SizedBox(
                      width: tileWidth,
                      child: _StatTile(
                        line: line,
                        series: series,
                        index: index,
                        overall: overall,
                        whole: whole,
                        activeTokenMillis: activeTokenMillis,
                      ),
                    ),
                ],
              );
            },
          ),
          if (isSpeed && overall && tokenStats != null) ...[
            const SizedBox(height: 10),
            _LatencyPercentiles(stats: tokenStats),
          ],
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.line,
    required this.series,
    required this.index,
    required this.overall,
    this.whole,
    this.activeTokenMillis,
  });

  final MetricLine line;
  final RunSeries series;
  final int index;
  final bool overall;
  final WholeRun? whole;
  final double? activeTokenMillis;

  (String, String?) _values() {
    if (line.bitmask) {
      return (line.text(series, index), null);
    }

    if (overall) {
      if (whole != null) {
        if (line.id == 'speed.tokens') {
          return ('${whole!.tokensPerSecond.toStringAsFixed(1)} tokens/s', null);
        }
        if (line.id == 'speed.prompt') {
          return ('${formatNumber(whole!.promptTokensPerSecond, 0)} tokens/s', null);
        }
        if (line.id == 'speed.ttft') {
          return ('${(whole!.ttftMillis / 1000).toStringAsFixed(2)} s', null);
        }
        if (line.id == 'eng.stall' && whole!.engine.ssdWaitPerToken != null) {
          return ('${whole!.engine.ssdWaitPerToken!.toStringAsFixed(2)} ms/token', null);
        }
        if (line.id == 'eng.ramHit' && whole!.engine.ramHitPercent != null) {
          return ('${whole!.engine.ramHitPercent!.toStringAsFixed(1)} %', null);
        }
        if (line.id == 'eng.vramHit' && whole!.engine.vramHitPercent != null) {
          return ('${whole!.engine.vramHitPercent!.toStringAsFixed(1)} %', null);
        }
        if (line.id == 'eng.reads' && whole!.engine.missesPerToken != null) {
          return ('${whole!.engine.missesPerToken!.toStringAsFixed(2)} per token', null);
        }
      }

      if (line.id.endsWith('.temp')) {
        final avg = series.average(line.id);
        final peak = series.peak(line.id);
        if (avg != null && peak != null) {
          return ('avg ${formatNumber(avg, 0)} °C', 'peak ${formatNumber(peak, 0)} °C');
        } else if (peak != null) {
          return ('${formatNumber(peak, 0)} °C', null);
        }
      }

      if (line.id.endsWith('.power')) {
        final avg = series.average(line.id);
        final peak = series.peak(line.id);
        final max = line.limit != null ? series.peak(line.limit!) : null;
        if (avg != null) {
          final pText = peak != null ? 'peak ${formatNumber(peak, line.digits)} W' : null;
          final mText = max != null ? 'of ${formatNumber(max, line.digits)} W' : null;
          final sub = [?pText, ?mText].join(' · ');
          return ('avg ${formatNumber(avg, line.digits)} W', sub.isEmpty ? null : sub);
        }
      }

      if (line.id.endsWith('.load')) {
        final avg = series.average(line.id);
        final peak = series.peak(line.id);
        if (avg != null) {
          return ('avg ${formatNumber(avg, 0)} %', peak != null ? 'peak ${formatNumber(peak, 0)} %' : null);
        }
      }

      if (line.id.endsWith('.clock') || line.id.endsWith('.mhz')) {
        final avg = series.average(line.id);
        final peak = series.peak(line.id);
        if (avg != null) {
          return ('avg ${formatNumber(avg, 0)} MHz', peak != null ? 'peak ${formatNumber(peak, 0)} MHz' : null);
        }
      }

      if (line.id.endsWith('.pcieRx') || line.id.endsWith('.pcieTx')) {
        final avg = series.average(line.id);
        final peak = series.peak(line.id);
        if (avg != null) {
          return ('avg ${formatNumber(avg, 0)} MB/s', peak != null ? 'peak ${formatNumber(peak, 0)} MB/s' : null);
        } else if (peak != null) {
          return ('${formatNumber(peak, 0)} MB/s', null);
        }
      }

      if (line.id.endsWith('.vram')) {
        final peak = series.peak(line.id);
        final max = line.limit != null ? series.peak(line.limit!) : null;
        if (peak != null) {
          return ('${formatNumber(peak, 1)} GB', max != null ? 'of ${formatNumber(max, 1)} GB' : null);
        }
      }

      final v = series.peak(line.id) ?? series.at(line.id, index);
      final max = line.limit != null ? series.peak(line.limit!) : null;
      if (v != null) {
        final p = '${formatNumber(v, line.digits)} ${line.unit}'.trim();
        final s = max != null && line.showLimit && line.unit != '%' ? 'of ${formatNumber(max, line.digits)} ${line.unit}'.trim() : null;
        return (p, s);
      }
    }

    // Live mode (or inspecting a token)
    if (!overall && activeTokenMillis != null && activeTokenMillis! > 0 && line.id == 'speed.tokens') {
      final tokSec = 1000.0 / activeTokenMillis!;
      return ('${tokSec.toStringAsFixed(1)} tokens/s (${activeTokenMillis!.toStringAsFixed(1)} ms)', null);
    }

    final v = series.at(line.id, index);
    if (v == null) return ('–', null);
    final max = line.limitAt(series, index);
    final p = '${formatNumber(v, line.digits)} ${line.unit}'.trim();
    final s = max != null && line.showLimit && line.unit != '%' ? 'of ${formatNumber(max, line.digits)} ${line.unit}'.trim() : null;
    return (p, s);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (primary, sub) = _values();

    return Container(
      key: Key('meter-${line.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: c.text.withValues(alpha: 0.025),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.text.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            line.label.toUpperCase(),
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: c.textMuted,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            primary,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: c.text,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (sub != null && sub.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              sub,
              style: TextStyle(
                fontSize: 11,
                color: c.textMuted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class _LatencyPercentiles extends StatelessWidget {
  const _LatencyPercentiles({required this.stats});

  final TokenStats stats;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    String fmt(double ms) => '${ms.toStringAsFixed(ms < 100 ? 1 : 0)} ms';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: c.text.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        children: [
          Text('p50: ${fmt(stats.p50)}', style: TextStyle(fontSize: 11, color: c.textSecondary, fontFeatures: const [FontFeature.tabularFigures()])),
          Text('p90: ${fmt(stats.p90)}', style: TextStyle(fontSize: 11, color: c.textSecondary, fontFeatures: const [FontFeature.tabularFigures()])),
          Text('p99: ${fmt(stats.p99)}', style: TextStyle(fontSize: 11, color: c.textSecondary, fontFeatures: const [FontFeature.tabularFigures()])),
          Text('max: ${fmt(stats.max)}', style: TextStyle(fontSize: 11, color: c.textSecondary, fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}
