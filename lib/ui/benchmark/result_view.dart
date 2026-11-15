import 'package:flutter/material.dart';

import '../../benchmark/benchmark.dart';
import '../../benchmark/engine_stats.dart';
import '../../benchmark/metrics.dart';
import '../../benchmark/series.dart';
import '../../benchmark/summary.dart';
import '../../engine/commands.dart';
import '../../theme.dart';
import 'fold.dart';
import 'result_charts.dart';

/// The full result of a run: the headline numbers, where the time of a token went, every token, then (opened with a
/// click) the phases, the streaming, the memory layout, the hardware, the sanity checks and the record of the setup,
/// and a comparison with any earlier run. [onShowMoment] moves the graphs' cursor to a moment (seconds on their axis).
class ResultView extends StatelessWidget {
  const ResultView({super.key, required this.result, this.others = const [], this.onShowMoment});

  final BenchmarkResult result;

  /// The other runs it can be compared with.
  final List<BenchmarkResult> others;
  final void Function(double seconds)? onShowMoment;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = result;
    final ssd = r.ssdWaitPerToken;
    final parts = r.timeParts.isNotEmpty ? r.timeParts : {'SSD wait': ?ssd};
    final onShow = onShowMoment;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${r.modelName}  ·  ${contextLabel(r.contextLength)}  ·  ${r.profileName}  ·  ${r.promptLabel}  ·  '
          '${r.replyTokens} tokens generated',
          style: TextStyle(fontSize: 13, color: c.textSecondary),
        ),
        const SizedBox(height: 12),
        _Headline(result: r),
        if (r.turns.isNotEmpty) ...[
          const SizedBox(height: 18),
          const SectionLabel('The turns: each with its own numbers, the warm-ups not counted'),
          TurnsTable(turns: r.turns),
        ],
        const SizedBox(height: 18),
        const SectionLabel('Where the time per token went'),
        TimePerToken(total: r.millisPerToken, parts: parts),
        const SizedBox(height: 18),
        TokenCharts(
          tokens: r.tokens,
          onPick: (k) {
            final at = tokenTimeSeconds(r, k);
            if (at != null) onShow?.call(at);
          },
        ),
        const SizedBox(height: 14),
        RunFolds(result: r, others: others, detailed: true),
      ],
    );
  }
}

/// The folds that belong to a run as a whole, closed until clicked: its phases, the memory layout, the hardware over the
/// run, the sanity checks, the record of the setup, a comparison with another run, and the engine's output. With
/// [detailed] it also has a fold for each turn, for the streaming numbers and for each layer; a view that shows those
/// another way (the turn tabs of the live view) leaves them out and says that the phases and the sanity checks are those
/// of the measured turn.
class RunFolds extends StatefulWidget {
  const RunFolds({super.key, required this.result, this.others = const [], this.detailed = false});

  final BenchmarkResult result;

  /// The other runs it can be compared with.
  final List<BenchmarkResult> others;
  final bool detailed;

  @override
  State<RunFolds> createState() => _RunFoldsState();
}

class _RunFoldsState extends State<RunFolds> {
  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final detailed = widget.detailed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (detailed)
          for (var i = 0; i < r.turns.length; i++)
            Fold(
              title: 'Turn ${i + 1}: ${r.turns[i].warmup ? 'warm-up, not counted' : 'measured'}',
              child: _turn(context, r.turns[i]),
            ),
        if (detailed) Fold(title: 'Streaming from the SSD', child: _streaming(context, r)),
        Fold(title: 'Memory layout', hint: _memorySummary(r), child: _memory(context, r)),
        if (detailed && r.layers.isNotEmpty)
          Fold(title: 'Each layer', child: LayerHeatMap(layers: r.layers, tokens: r.replyTokens)),
        if (r.series != null) Fold(title: 'Hardware over the run', child: _hardware(context, r.series!)),
      ],
    );
  }

  Widget _turn(BuildContext context, TurnRecord turn) {
    final stats = turn.tokenStats;
    return Facts([
      ('TTFT', '${(turn.firstTokenMillis / 1000).toStringAsFixed(2)} s to the first token'),
      (
        'Prompt processing',
        '${formatNumber(turn.promptTokens.toDouble(), 0)} tokens in ${(turn.promptMillis / 1000).toStringAsFixed(2)} s '
            '(${formatNumber(turn.promptTokensPerSecond, 0)} tokens/s)',
      ),
      (
        'Generation',
        '${turn.replyTokens} tokens in ${(turn.replyMillis / 1000).toStringAsFixed(2)} s '
            '(${turn.tokensPerSecond.toStringAsFixed(1)} tokens/s)',
      ),
      ('Token times', 'p50 ${stats.p50.toStringAsFixed(0)} · p90 ${stats.p90.toStringAsFixed(0)} · p99 ${stats.p99.toStringAsFixed(0)} ms'),
      ('Time of the message', '${(turn.totalMillis / 1000).toStringAsFixed(1)} s'),
      if (turn.stopReason != null) ('Ended because', stopReasonText(turn.stopReason)),
      if (turn.hitRate != null) ('Found in memory', '${turn.hitRate!.toStringAsFixed(1)} % of the reply\'s expert uses (RAM or VRAM)'),
      if (turn.ssdWaitPerToken != null) ('SSD wait', '${turn.ssdWaitPerToken!.toStringAsFixed(2)} ms/token'),
      if (turn.engineNumber('reply', 'mib_read') != null)
        ('Read from the SSD', '${formatNumber(turn.engineNumber('reply', 'mib_read')!, 0)} MB in the reply'),
    ]);
  }

  Widget _streaming(BuildContext context, BenchmarkResult r) {
    final s = r.engineStats;
    if (s.isEmpty) return const _Empty('The engine did not report streaming numbers (it may not be streaming).');
    final promptRead = r.engineNumber('prompt', 'mib_read') ?? 0;
    final replyRead = r.engineNumber('reply', 'mib_read') ?? 0;
    String pct(double? v) => v == null ? '–' : '${v.toStringAsFixed(1)} %';
    final guesses = [
      for (final (id, label, names) in guessKinds)
        if (pickNumber(s, names) ?? r.series?.average('eng.$id', from: replyStartSeconds(r)) case final v?)
          '$label ${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)}${pickNumber(s, names) == null ? ' %' : ''}',
    ];
    return Facts([
      ('Read from the SSD', '${formatNumber(promptRead + replyRead, 0)} MB in all, ${formatNumber(r.engineNumber('reply', 'mib_per_token') ?? 0, 1)} MB per token of the reply'),
      ('Found in memory (RAM or VRAM)', 'reply ${pct(r.hitRate)}, prompt ${pct(r.engineNumber('prompt', 'hit_rate_percent'))}'),
      ('Reads from the SSD', '${formatNumber(r.engineNumber('reply', 'misses') ?? 0, 0)} in the reply, ${formatNumber(r.engineNumber('reply', 'misses_per_token') ?? 0, 2)} per token'),
      if (r.ssdWaitPerToken != null) ('SSD wait', '${r.ssdWaitPerToken!.toStringAsFixed(2)} ms/token'),
      if (guesses.isNotEmpty) ('Guesses', guesses.join(', ')),
    ]);
  }

  String? _memorySummary(BenchmarkResult r) {
    final m = r.memory;
    final s = r.engineStats;
    final slots = m.ramSlots ?? (s['slots'] as num?)?.toInt();
    final layers = m.streamedLayers ?? (s['layers'] as num?)?.toInt();
    final vramExp = m.vramExpertsPerLayer;
    final parts = <String>[];
    if (slots != null) parts.add('$slots in RAM');
    if (vramExp != null) parts.add('$vramExp in VRAM');
    if (parts.isEmpty) return null;
    final suffix = layers != null ? ' in $layers streamed layers' : '';
    return '(${parts.join(', ')}$suffix)';
  }

  Widget _memory(BuildContext context, BenchmarkResult r) {
    final c = context.colors;
    final m = r.memory;
    final s = r.engineStats;
    final slots = m.ramSlots ?? (s['slots'] as num?)?.toInt();
    final layers = m.streamedLayers ?? (s['layers'] as num?)?.toInt();
    final vramGiB = r.series?.peak('gpu.0.vram');
    final vramTotal = r.series?.peak('gpu.0.vramTotal');
    final ramEngine = r.series?.peak('ram.engine');

    Widget tierHeader(String title, String? subtitle, Color color) => Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 8),
          Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text)),
          if (subtitle != null) ...[
            const SizedBox(width: 6),
            Text(subtitle, style: TextStyle(fontSize: 12, color: c.textMuted)),
          ],
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        tierHeader('Video Memory (VRAM)', vramGiB != null ? '${formatNumber(vramGiB, 1)}${vramTotal != null ? ' of ${formatNumber(vramTotal, 1)}' : ''} GB' : null, Colors.greenAccent),
        Facts([
          ('Base model weights', 'Embeddings, Attention, Routers, Normalizations'),
          if (m.gpuLayers != null && m.gpuLayers! > 0)
            ('Whole GPU layers', '${m.gpuLayers} layers pinned in VRAM'),
          if (m.vramExpertsPerLayer != null && m.vramExpertsPerLayer! > 0)
            ('VRAM expert pool', '${m.vramExpertsPerLayer} hot experts per layer'),
          if (m.kvMiB != null)
            ('Attention cache (KV)', '${formatNumber(m.kvMiB!, 0)} MB'),
          ('Compute scratch', 'Pre-allocated CUDA activation & workspace buffers'),
        ]),
        const SizedBox(height: 12),
        tierHeader('System RAM', ramEngine != null ? '${formatNumber(ramEngine, 1)} GB allocated' : null, Colors.lightBlueAccent),
        Facts([
          if (slots != null)
            ('Streamed expert pool', '$slots slots per layer${layers == null ? '' : ' across $layers streamed layers'}'),
          ('Host buffers', 'CPU base weights, DMA page-locked transfer buffers'),
        ]),
        const SizedBox(height: 12),
        tierHeader('NVMe SSD', 'Cold store', Colors.orangeAccent),
        Facts([
          ('Cold expert store', 'Direct-IO streamed on demand without page caching'),
        ]),
      ],
    );
  }

  Widget _hardware(BuildContext context, RunSeries series) {
    final facts = hardwareFacts(series);
    if (facts.isEmpty) return const _Empty('Nothing could be read from this computer.');
    return Facts([for (final f in facts) (f.label, f.text)]);
  }



}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(fontSize: 12.5, color: context.colors.textMuted));
}

/// The big numbers of a run.
class _Headline extends StatelessWidget {
  const _Headline({required this.result});

  final BenchmarkResult result;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final c = context.colors;
    Widget tile(String key, String value, String unit, String name, {bool small = false}) => Container(
      key: Key('result-$key'),
      width: 150,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: c.text.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: TextStyle(
                    fontSize: small ? 14.5 : 22,
                    height: small ? 1.35 : null,
                    fontWeight: FontWeight.w500,
                    color: c.text,
                  ),
                ),
                if (unit.isNotEmpty) TextSpan(text: ' $unit', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
              ],
            ),
            style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
          ),
          const SizedBox(height: 2),
          Text(name, style: TextStyle(fontSize: 12, color: c.textMuted)),
        ],
      ),
    );

    // The engine's streaming numbers, when it reported them: several per card, so in a smaller type.
    final vramHits = r.engineNumber('reply', 'vram_hit_percent');
    final ramHits = r.ramHitPercent ?? r.hitRate;
    final guesses = [for (final (_, _, names) in guessKinds) pickNumber(r.engineStats, names) ?? 0.0];
    final guessSum = guesses.fold(0.0, (a, b) => a + b);
    final readsPerToken = r.engineNumber('reply', 'misses_per_token');
    final mibPerToken = r.engineNumber('reply', 'mib_per_token');
    String share(double v) => '${v.toStringAsFixed(1)} %';
    final hasStreaming = vramHits != null || ramHits != null || guessSum > 0 || readsPerToken != null || mibPerToken != null;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        tile('reply-speed', r.tokensPerSecond.toStringAsFixed(1), 'tokens/s', 'Generation speed'),
        tile('first-token', (r.firstTokenMillis / 1000).toStringAsFixed(2), 's', 'TTFT'),
        tile('prompt-speed', formatNumber(r.promptTokensPerSecond, 0), 'tokens/s', 'Prompt processing'),
        tile('load', (r.loadMillis / 1000).toStringAsFixed(1), 's', 'Load time'),
        tile('slowest-1', r.slowestOnePercent.toStringAsFixed(0), 'ms/token', 'p99'),
        tile('slowest-token', r.slowestToken.toStringAsFixed(0), 'ms', 'Slowest token'),
        tile('total', (r.measuredMillis / 1000).toStringAsFixed(1), 's', 'Time of the message'),
        if (hasStreaming) ...[
          tile(
            'hits',
            [
              if (vramHits != null) '${share(vramHits)} VRAM',
              if (ramHits != null) '${share(ramHits)} RAM',
            ].join(' · '),
            '',
            'VRAM / RAM hits',
            small: true,
          ),
          if (guessSum > 0)
            tile(
              'guesses',
              '${share(100 * guesses[0] / guessSum)} / ${share(100 * guesses[1] / guessSum)} / ${share(100 * guesses[2] / guessSum)}',
              '',
              'Guesses: in time / late / missed',
              small: true,
            ),
          if (readsPerToken != null || mibPerToken != null)
            tile(
              'ssd-reads',
              [
                if (readsPerToken != null) '${readsPerToken.toStringAsFixed(1)} reads',
                if (mibPerToken != null) '${formatNumber(mibPerToken, 1)} MB',
              ].join(' · '),
              '',
              'SSD reads per token',
              small: true,
            ),
        ],
      ],
    );
  }
}

/// The turns of a run side by side: one row per turn, so they compare without a click. The warm-up rows are
/// marked; the engine's hit and SSD-wait numbers are each turn's own.
class TurnsTable extends StatelessWidget {
  const TurnsTable({super.key, required this.turns});

  final List<TurnRecord> turns;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cell = TextStyle(fontSize: 12.5, color: c.text, fontFeatures: const [FontFeature.tabularFigures()]);
    final head = TextStyle(fontSize: 12, color: c.textMuted);
    String? pct(double? v) => v == null ? null : '${v.toStringAsFixed(1)} %';

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        defaultVerticalAlignment: TableCellVerticalAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          TableRow(
            children: [
              for (final h in ['Turn', 'TTFT', 'Reply', 'Speed', 'Time', 'RAM hits', 'SSD wait'])
                Padding(
                  padding: const EdgeInsets.only(right: 22, bottom: 4),
                  child: Text(h, style: head),
                ),
            ],
          ),
          for (var i = 0; i < turns.length; i++)
            TableRow(
              children: [
                for (final v in [
                  '${i + 1}. ${turns[i].warmup ? 'Warm-up' : 'Measured'}',
                  '${(turns[i].firstTokenMillis / 1000).toStringAsFixed(2)} s',
                  '${turns[i].replyTokens} tokens',
                  '${turns[i].tokensPerSecond.toStringAsFixed(1)} tokens/s',
                  '${(turns[i].totalMillis / 1000).toStringAsFixed(1)} s',
                  pct(turns[i].ramHitPercent ?? turns[i].hitRate) ?? '–',
                  turns[i].ssdWaitPerToken?.toStringAsFixed(2) != null
                      ? '${turns[i].ssdWaitPerToken!.toStringAsFixed(2)} ms/token'
                      : '–',
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 22, bottom: 4),
                    child: Text(v, style: cell),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Names and their values in two columns.
class Facts extends StatelessWidget {
  const Facts(this.rows, {super.key});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (name, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 170, child: Text(name, style: TextStyle(fontSize: 12.5, color: c.textMuted))),
                Expanded(child: SelectableText(value, style: TextStyle(fontSize: 12.5, height: 1.45, color: c.text))),
              ],
            ),
          ),
      ],
    );
  }
}

