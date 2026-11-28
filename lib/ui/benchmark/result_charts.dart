import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../benchmark/engine_stats.dart' show hasTimeSplit, timeBesideParts;
import '../../theme.dart';
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
    // (The gap between the parts and the whole token, as the engine timed the reply, is the server's own work around
    // each token: it joins the engine's own leftover.)
    final gap = rest > total * 0.02 ? rest : 0.0;
    final shown = <(String, double)>[
      for (final e in stacked.entries)
        if (e.key != 'Other') (e.key, e.value),
      if ((stacked['Other'] ?? 0) + gap > 0) ('Other', (stacked['Other'] ?? 0) + gap),
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
