import 'package:flutter/material.dart';

import '../../benchmark/benchmark.dart';
import '../../benchmark/engine_stats.dart';
import '../../benchmark/metrics.dart';
import '../../benchmark/summary.dart';
import '../../benchmark/whole_run.dart';
import '../../theme.dart';
import 'fold.dart';
import 'result_charts.dart';
import 'result_view.dart';

/// What the engine counted, as rows of facts: the shares found in RAM and in VRAM, the reads the SSD had to serve, what was
/// read from it, the wait on it and what became of the guesses. Only what the engine gave. [whole] words the rows for
/// several turns rather than one.
List<(String, String)> engineFacts(EngineNumbers e, {required bool whole}) {
  String pct(double v) => '${v.toStringAsFixed(1)} %';
  final cacheHit = e.cacheHitPercent;
  final missPct = e.calculatedMissPercent;

  String? cacheHitText;
  if (cacheHit != null) {
    final parts = <String>[];
    if (e.vramHitPercent != null) parts.add('${pct(e.vramHitPercent!)} in VRAM');
    if (e.ramHitPercent != null) parts.add('${pct(e.ramHitPercent!)} in RAM');
    cacheHitText = parts.isEmpty ? pct(cacheHit) : '${pct(cacheHit)} (${parts.join(', ')})';
  }

  String? correctText;
  if (e.guessShares.isNotEmpty) {
    const ids = ['gInTime', 'gLate', 'gMissed'];
    final all = ids.fold(0.0, (a, id) => a + (e.guesses[id] ?? 0));
    if (all > 0) {
      final inTime = e.guesses['gInTime'] ?? 0;
      final late = e.guesses['gLate'] ?? 0;
      final missed = e.guesses['gMissed'] ?? 0;
      final correctPct = pct(100.0 * (inTime + late) / all);
      final details = <String>[
        if (e.guesses.containsKey('gInTime')) 'in time ${pct(100.0 * inTime / all)}',
        if (e.guesses.containsKey('gLate')) 'late ${pct(100.0 * late / all)}',
        if (e.guesses.containsKey('gMissed')) 'missed ${pct(100.0 * missed / all)}',
      ];
      correctText = details.isNotEmpty
          ? '$correctPct of predictions (${details.join(', ')})'
          : '$correctPct of predictions';
    }
  }

  String? wrongText;
  if (e.totalWastedPercent != null) {
    final total = pct(e.totalWastedPercent!);
    final w = e.wastedPercent != null ? pct(e.wastedPercent!) : null;
    final c = e.cancelledPercent != null ? pct(e.cancelledPercent!) : null;
    if (w != null && c != null) {
      wrongText = '$total of predictions ($w pulled completely, $c cancelled in-flight)';
    } else {
      wrongText = '$total of predictions';
    }
  }

  return [
    if (cacheHitText != null) ('Cache hits', cacheHitText),
    if (missPct != null) ('Misses', pct(missPct)),
    if (e.ssdWaitPerToken != null) ('SSD wait', '${e.ssdWaitPerToken!.toStringAsFixed(2)} ms/token'),
    if (correctText != null) ('Correct guesses', correctText),
    if (wrongText != null) ('Wrong guesses', wrongText),
  ];
}

/// The engine's numbers under a caption, or a line saying it gave none.
class _EngineBlock extends StatelessWidget {
  const _EngineBlock({required this.caption, required this.numbers, required this.whole});

  final String caption;
  final EngineNumbers numbers;
  final bool whole;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(caption),
        if (numbers.isEmpty)
          Text('The engine did not report streaming numbers (it may not be streaming).', style: TextStyle(fontSize: 12.5, color: c.textMuted))
        else
          Facts(engineFacts(numbers, whole: whole)),
      ],
    );
  }
}

/// The turns of a run one beside the other, each with its TTFT and its generation speed: the first one is the message that
/// comes right after the engine starts, the measured one is the benchmark's result.
class TurnsLine extends StatelessWidget {
  const TurnsLine({super.key, required this.turns});

  final List<TurnRecord> turns;

  /// What turn [i] is: the first message after a start, a warm-up, or the benchmark's result.
  String _role(int i) => [
    if (i == 0) 'first message after a start',
    if (!turns[i].warmup) 'benchmark result' else if (i != 0) 'warm-up',
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Wrap(
      spacing: 26,
      runSpacing: 8,
      children: [
        for (var i = 0; i < turns.length; i++)
          Column(
            key: Key('whole-turn-$i'),
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: 'Turn ${i + 1}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: c.text)),
                    TextSpan(text: '  ${_role(i)}', style: TextStyle(fontSize: 11.5, color: c.textMuted)),
                  ],
                ),
              ),
              Text(
                '${(turns[i].firstTokenMillis / 1000).toStringAsFixed(2)} s TTFT  ·  ${turns[i].tokensPerSecond.toStringAsFixed(1)} tokens/s',
                style: TextStyle(fontSize: 12.5, color: c.textSecondary, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ],
          ),
      ],
    );
  }
}

/// The details of one finished turn, under its graphs: where the time of a token went, every token and how the times
/// spread, what the engine counted, the layers, and why the reply ended. [onShowMoment] is told the moment (seconds on the
/// run's clock) of a token that is picked.
class TurnDetails extends StatelessWidget {
  const TurnDetails({super.key, required this.turn, this.onShowMoment});

  final TurnRecord turn;
  final void Function(double seconds)? onShowMoment;

  @override
  Widget build(BuildContext context) {
    final t = turn;
    final parts = timeParts(t.engineStats);
    final ssd = t.ssdWaitPerToken;
    final layers = layersOf(t.engineStats);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('Where the time per token went'),
        TimePerToken(total: t.replyTokens > 0 ? t.replyMillis / t.replyTokens : 0, parts: parts.isNotEmpty ? parts : {'SSD wait': ?ssd}),
        const SizedBox(height: 18),
        TokenCharts(
          tokens: t.tokens,
          onPick: (k) {
            final at = turnTokenSeconds(t, k);
            if (at != null) onShowMoment?.call(at);
          },
        ),
        const SizedBox(height: 18),
        _EngineBlock(caption: 'What the engine counted in this turn', numbers: engineNumbers([t]), whole: false),
        const SizedBox(height: 6),
        Facts([('Ended because', stopReasonText(t.stopReason))]),
        if (layers.isNotEmpty) Fold(title: 'Each layer', child: LayerHeatMap(layers: layers, tokens: t.replyTokens)),
      ],
    );
  }
}

/// The details of a whole run that has ended, under its graphs: the run's size, what the engine counted over all the turns
/// together, the turns side by side, every token of the run and how the times spread, and the folds of the run when its
/// [result] is here. [clockEnd] is where the run's clock stopped. [onShowMoment] is told the moment of a token that is
/// picked.
class WholeRunDetails extends StatelessWidget {
  const WholeRunDetails({
    super.key,
    required this.whole,
    this.result,
    this.others = const [],
    this.clockEnd,
    this.onShowMoment,
  });

  final WholeRun whole;
  final BenchmarkResult? result;

  /// The other runs the result can be compared with.
  final List<BenchmarkResult> others;
  final double? clockEnd;
  final void Function(double seconds)? onShowMoment;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final load = r?.loadMillis;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('The run'),
        Facts([
          if (load != null) ('Load time', '${(load / 1000).toStringAsFixed(1)} s'),
          (
            'Tokens in all',
            '${formatNumber(whole.promptTokens.toDouble(), 0)} read in the prompts, '
                '${formatNumber(whole.replyTokens.toDouble(), 0)} written in the replies, in ${whole.turns.length} turns',
          ),
        ]),
        const SizedBox(height: 18),
        _EngineBlock(caption: 'What the engine counted over all the turns', numbers: whole.engine, whole: true),
        const SizedBox(height: 18),
        const SectionLabel('The turns: each with its own numbers, the warm-ups not counted'),
        TurnsTable(turns: whole.turns),
        const SizedBox(height: 18),
        TokenCharts(
          tokens: whole.tokens,
          onPick: (k) {
            final at = whole.tokenSeconds(k);
            if (at != null) onShowMoment?.call(at);
          },
        ),
        if (r != null) ...[
          const SizedBox(height: 14),
          RunFolds(result: r, others: others),
        ],
      ],
    );
  }
}
