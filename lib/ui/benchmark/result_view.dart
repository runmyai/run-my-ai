import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../benchmark/benchmark.dart';
import '../../benchmark/compare.dart';
import '../../benchmark/engine_stats.dart';
import '../../benchmark/metrics.dart';
import '../../benchmark/series.dart';
import '../../benchmark/summary.dart';
import '../../engine/commands.dart';
import '../../theme.dart';
import '../buttons.dart';
import '../menu_panel.dart';
import 'fold.dart';
import 'result_charts.dart';

/// The full result of a run: the headline numbers, where the time of a word went, every word, then (opened with a
/// click) the phases, the streaming, the memory layout, the hardware, the sanity checks and the record of the setup,
/// and a comparison with any earlier run. [onShowMoment] moves the graphs' cursor to a moment (seconds on their axis).
class ResultView extends StatefulWidget {
  const ResultView({super.key, required this.result, this.others = const [], this.onShowMoment});

  final BenchmarkResult result;

  /// The other runs it can be compared with.
  final List<BenchmarkResult> others;
  final void Function(double seconds)? onShowMoment;

  @override
  State<ResultView> createState() => _ResultViewState();
}

class _ResultViewState extends State<ResultView> {
  int? _picked;
  BenchmarkResult? _other;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = widget.result;
    final ssd = r.ssdWaitPerWord;
    final parts = r.timeParts.isNotEmpty ? r.timeParts : {'SSD wait': ?ssd};
    final others = [for (final o in widget.others) if (!identical(o, r) && (r.id == null || o.id != r.id)) o];
    final onShow = widget.onShowMoment;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (r.disturbed.isNotEmpty) ...[
          for (final reason in r.disturbed)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('Disturbed: $reason', style: TextStyle(fontSize: 13, color: c.danger)),
            ),
          const SizedBox(height: 6),
        ],
        Text(
          '${r.modelName}  ·  ${contextLabel(r.contextLength)}  ·  ${r.profileName}  ·  ${r.promptLabel}  ·  '
          '${r.replyTokens} tokens generated',
          style: TextStyle(fontSize: 13, color: c.textSecondary),
        ),
        const SizedBox(height: 12),
        _Headline(result: r),
        const SizedBox(height: 18),
        const _Label('Where the time per token went'),
        TimePerWord(total: r.millisPerWord, parts: parts),
        const SizedBox(height: 18),
        const _Label('Every token: click one to see that moment in the graphs'),
        WordsChart(
          words: r.words,
          picked: _picked,
          onPick: (k) {
            setState(() => _picked = k);
            final at = wordTimeSeconds(r, k);
            if (at != null) onShow?.call(at);
          },
        ),
        const SizedBox(height: 18),
        const _Label('How the times spread'),
        SpreadChart(words: r.words),
        const SizedBox(height: 14),
        Fold(title: 'Phases', child: _phases(context, r)),
        Fold(title: 'Streaming from the SSD', child: _streaming(context, r)),
        Fold(title: 'Memory layout', child: _memory(context, r)),
        if (r.layers.isNotEmpty)
          Fold(title: 'Each layer', child: LayerHeatMap(layers: r.layers, words: r.replyTokens)),
        if (r.series != null) Fold(title: 'Hardware over the run', child: _hardware(context, r.series!)),
        Fold(title: 'Sanity: the reply and why it ended', child: _sanity(context, r)),
        Fold(title: 'Setup record', child: _setup(context, r)),
        if (others.isNotEmpty) Fold(title: 'Compare with another run', child: _compare(context, r, others)),
        Fold(
          title: 'Engine output',
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              child: SizedBox(
                width: double.infinity,
                child: SelectableText(
                  r.log.isEmpty ? 'Nothing was kept.' : r.log.join('\n'),
                  style: TextStyle(fontSize: 11.5, height: 1.45, color: c.textMuted, fontFamily: 'monospace'),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _phases(BuildContext context, BenchmarkResult r) {
    final read = r.engineNumber('prompt', 'mib_read');
    final replyRead = r.engineNumber('reply', 'mib_read');
    String mb(double? v) => v == null ? 'not reported' : '${formatNumber(v, 0)} MB';
    final warm = r.series?.phases.where((p) => p.name == PhaseBand.warmUp).firstOrNull;
    return _Facts([
      ('Load', '${(r.loadMillis / 1000).toStringAsFixed(1)} s to start the engine and load the model'),
      if (warm != null) ('Warm-up', '${r.warmups.length} messages, ${((warm.end - warm.start)).toStringAsFixed(1)} s, not counted'),
      (
        'Prompt processing',
        '${formatNumber(r.promptTokens.toDouble(), 0)} tokens in ${(r.promptMillis / 1000).toStringAsFixed(2)} s '
            '(${formatNumber(r.promptTokensPerSecond, 0)} tokens/s), ${mb(read)} read from the SSD',
      ),
      (
        'Generation',
        '${r.replyTokens} tokens in ${(r.replyMillis / 1000).toStringAsFixed(2)} s '
            '(${r.tokensPerSecond.toStringAsFixed(1)} tokens/s), ${mb(replyRead)} read from the SSD',
      ),
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
    return _Facts([
      ('Read from the SSD', '${formatNumber(promptRead + replyRead, 0)} MB in all, ${formatNumber(r.engineNumber('reply', 'mib_per_token') ?? 0, 1)} MB per token of the reply'),
      ('Found in RAM', 'reply ${pct(r.hitRate)}, prompt ${pct(r.engineNumber('prompt', 'hit_rate_percent'))}'),
      ('Reads from the SSD', '${formatNumber(r.engineNumber('reply', 'misses') ?? 0, 0)} in the reply, ${formatNumber(r.engineNumber('reply', 'misses_per_token') ?? 0, 2)} per token'),
      if (r.ssdWaitPerWord != null) ('SSD wait', '${r.ssdWaitPerWord!.toStringAsFixed(2)} ms/token'),
      if (guesses.isNotEmpty) ('Guesses', guesses.join(', ')),
    ]);
  }

  Widget _memory(BuildContext context, BenchmarkResult r) {
    final m = r.memory;
    final s = r.engineStats;
    final slots = m.ramSlots ?? (s['slots'] as num?)?.toInt();
    final layers = m.streamedLayers ?? (s['layers'] as num?)?.toInt();
    return _Facts([
      if (slots != null) ('RAM slots', '$slots per layer${layers == null ? '' : ' in $layers streamed layers'}'),
      if (m.vramExpertsPerLayer != null) ('VRAM experts', '${m.vramExpertsPerLayer} per layer'),
      if (m.gpuLayers != null) ('Whole layers on the graphics card', '${m.gpuLayers}'),
      if (m.kvMiB != null) ('Attention cache', '${formatNumber(m.kvMiB!, 0)} MB'),
      ('Memory cap', r.memoryCapGiB == null ? 'all RAM but 1 GB' : '${r.memoryCapGiB} GB'),
      if (m.freeRamGiB != null) ('Free RAM at the start', '${m.freeRamGiB!.toStringAsFixed(1)} GB'),
      ('Context length', formatTokens(r.contextLength)),
    ]);
  }

  Widget _hardware(BuildContext context, RunSeries series) {
    final facts = hardwareFacts(series);
    if (facts.isEmpty) return const _Empty('Nothing could be read from this computer.');
    return _Facts([for (final f in facts) (f.label, f.text)]);
  }

  Widget _sanity(BuildContext context, BenchmarkResult r) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Facts([
          ('Ended because', stopReasonText(r.stopReason)),
          ('Tokens generated', '${r.replyTokens} of at most ${r.replyLength}'),
          ('Disturbed', r.disturbed.isEmpty ? 'no' : r.disturbed.join('\n')),
        ]),
        const SizedBox(height: 8),
        Text('The reply', style: TextStyle(fontSize: 12, color: c.textMuted)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 200),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: c.inputFill, border: Border.all(color: c.inputBorder), borderRadius: BorderRadius.circular(8)),
          child: SingleChildScrollView(
            child: SelectableText(
              r.replyText.isEmpty ? 'The reply was not kept.' : r.replyText,
              style: TextStyle(fontSize: 13, height: 1.5, color: c.textSecondary),
            ),
          ),
        ),
      ],
    );
  }

  Widget _setup(BuildContext context, BenchmarkResult r) {
    final c = context.colors;
    final e = r.environment;
    final h = e.hardware;
    final diff = _other == null ? null : diffFlags(r.flags, _other!.flags);
    final mono = TextStyle(fontSize: 12, height: 1.5, color: c.textSecondary, fontFamily: 'monospace');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Flags', style: TextStyle(fontSize: 12, color: c.textMuted)),
            const SizedBox(width: 6),
            AppIconButton(
              key: const Key('copy-flags'),
              size: 24,
              iconSize: 14,
              radius: 6,
              muted: true,
              icon: Icons.copy_outlined,
              tooltip: 'Copy flags',
              onTap: () => Clipboard.setData(ClipboardData(text: r.flags)),
            ),
            if (diff != null) Text(diff.isEmpty ? 'the same as the other run' : 'bold: differs from the other run', style: TextStyle(fontSize: 12, color: c.textMuted)),
          ],
        ),
        _FlagsText(flags: r.flags, highlight: diff?.names ?? const {}, style: mono),
        if (e.addedFlags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Added by the benchmark: ${e.addedFlags.join(', ')}', style: TextStyle(fontSize: 12, color: c.textMuted)),
          ),
        const SizedBox(height: 10),
        _Facts([
          ('Profile', r.profileName),
          ('Model', r.modelName),
          if (e.modelFileBytes != null || e.modelFileModified != null)
            (
              'Model file',
              [
                if (e.modelFileBytes != null) formatBytes(e.modelFileBytes!),
                if (e.modelFileModified != null) 'changed ${_date(e.modelFileModified!)}',
              ].join(', '),
            ),
          if (e.engineVersion != null) ('Engine', e.engineVersion!),
          if (e.appVersion != null) ('Run My AI', e.appVersion!),
          ('Context', formatTokens(r.contextLength)),
          ('Prompt', r.promptLabel),
          ('Longest reply', '${r.replyLength} tokens'),
          if (r.thinking != null) ('Thinking', r.thinking! ? 'on' : 'off'),
          if (h.cpu.isNotEmpty) ('CPU', '${h.cpu}${h.threads > 0 ? ', ${h.threads} threads' : ''}'),
          if (h.gpus.isNotEmpty) ('Graphics', h.gpus.join(', ')),
          if (h.ramGiB > 0) ('RAM', '${h.ramGiB.toStringAsFixed(1)} GB'),
          if (h.os.isNotEmpty) ('System', h.os),
          if (e.onBattery != null) ('Power', e.onBattery! ? 'on battery' : 'plugged in'),
          ('Run at', _date(r.at, time: true)),
        ]),
        const SizedBox(height: 6),
        Fold(
          title: 'Prompt text',
          child: SelectableText(
            r.promptText.isEmpty ? 'Not kept.' : r.promptText,
            maxLines: 12,
            style: TextStyle(fontSize: 12.5, height: 1.5, color: c.textSecondary),
          ),
        ),
        for (var i = 0; i < r.warmups.length; i++)
          Fold(
            title: 'Warm-up message ${i + 1}',
            child: SelectableText(r.warmups[i], style: TextStyle(fontSize: 12.5, height: 1.5, color: c.textSecondary)),
          ),
      ],
    );
  }

  Widget _compare(BuildContext context, BenchmarkResult r, List<BenchmarkResult> others) {
    final c = context.colors;
    String name(BenchmarkResult o) =>
        '${_date(o.at, time: true)}  ·  ${o.profileName}  ·  ${contextLabel(o.contextLength)}  ·  ${o.promptLabel}  ·  ${o.tokensPerSecond.toStringAsFixed(1)} tokens/s';
    final other = _other;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MenuAnchor(
          style: bareMenuStyle,
          clipBehavior: Clip.none,
          builder: (context, controller, _) => AppButton(
            key: const Key('compare-pick'),
            label: other == null ? 'Choose a run' : name(other),
            trailingIcon: Icons.arrow_drop_down,
            onTap: () => controller.isOpen ? controller.close() : controller.open(),
          ),
          menuChildren: [
            MenuPanel(
              color: c.inputFill,
              border: c.inputBorder,
              elevation: 2,
              shadowColor: Theme.of(context).shadowColor,
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                for (final o in others)
                  MenuItemButton(
                    onPressed: () => setState(() => _other = o),
                    child: Text(name(o), style: TextStyle(fontSize: 13, color: c.text)),
                  ),
              ],
            ),
          ],
        ),
        if (other != null) ...[
          const SizedBox(height: 10),
          for (final d in compareRuns(r, other)) _DeltaRow(delta: d),
          const SizedBox(height: 8),
          _flagChanges(context, diffFlags(r.flags, other.flags)),
        ],
      ],
    );
  }

  Widget _flagChanges(BuildContext context, FlagDiff diff) {
    final c = context.colors;
    if (diff.isEmpty) return Text('The flags are the same.', style: TextStyle(fontSize: 12.5, color: c.textMuted));
    final mono = TextStyle(fontSize: 12, height: 1.5, color: c.textSecondary, fontFamily: 'monospace');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Flags that differ', style: TextStyle(fontSize: 12, color: c.textMuted)),
        for (final e in diff.changed.entries)
          Text('${e.key}: ${_other == null ? '' : flagMap(_other!.flags)[e.key]}  →  ${e.value}', style: mono),
        for (final e in diff.added.entries) Text('+ ${e.key} ${e.value}', style: mono),
        for (final e in diff.removed.entries) Text('− ${e.key} ${e.value}', style: mono),
      ],
    );
  }

  static String _date(DateTime t, {bool time = false}) {
    String two(int n) => n.toString().padLeft(2, '0');
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${t.day} ${months[t.month - 1]} ${t.year}${time ? ' ${two(t.hour)}:${two(t.minute)}' : ''}';
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: TextStyle(fontSize: 12.5, color: context.colors.textMuted)),
  );
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
    Widget tile(String key, String value, String unit, String name) => Container(
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
                TextSpan(text: value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: c.text)),
                TextSpan(text: ' $unit', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
              ],
            ),
            style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
          ),
          const SizedBox(height: 2),
          Text(name, style: TextStyle(fontSize: 12, color: c.textMuted)),
        ],
      ),
    );
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        tile('reply-speed', r.tokensPerSecond.toStringAsFixed(1), 'tokens/s', 'Generation speed'),
        tile('first-word', (r.firstWordMillis / 1000).toStringAsFixed(2), 's', 'TTFT'),
        tile('prompt-speed', formatNumber(r.promptTokensPerSecond, 0), 'tokens/s', 'Prompt processing'),
        tile('load', (r.loadMillis / 1000).toStringAsFixed(1), 's', 'Load time'),
        tile('slowest-1', r.slowestOnePercent.toStringAsFixed(0), 'ms/token', 'p99'),
        tile('slowest-word', r.slowestWord.toStringAsFixed(0), 'ms', 'Slowest token'),
        tile('total', (r.measuredMillis / 1000).toStringAsFixed(1), 's', 'Time of the message'),
      ],
    );
  }
}

/// Names and their values in two columns.
class _Facts extends StatelessWidget {
  const _Facts(this.rows);

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

/// The flags of a run in one block; those named in [highlight] (and their values) are written in bold.
class _FlagsText extends StatelessWidget {
  const _FlagsText({required this.flags, required this.highlight, required this.style});

  final String flags;
  final Set<String> highlight;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    var on = false;
    for (final word in flags.split(RegExp(r'\s+')).where((w) => w.isNotEmpty)) {
      final isFlag = word.startsWith('-') && !RegExp(r'^-\d').hasMatch(word);
      final env = RegExp(r'^([A-Za-z_]\w*)=').firstMatch(word);
      if (isFlag) {
        final name = word.contains('=') ? word.substring(0, word.indexOf('=')) : word;
        on = highlight.contains(name);
      } else if (env != null) {
        on = highlight.contains(env[1]);
      }
      spans.add(
        TextSpan(
          text: '$word ',
          style: on ? style.copyWith(fontWeight: FontWeight.w700, color: context.colors.text) : null,
        ),
      );
    }
    return SelectableText.rich(TextSpan(style: style, children: spans));
  }
}

class _DeltaRow extends StatelessWidget {
  const _DeltaRow({required this.delta});

  final RunDelta delta;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final d = delta;
    String f(double? v) => v == null ? '–' : formatNumber(v, d.digits);
    final change = d.change;
    final worse = d.better == false;
    final text = change == null
        ? ''
        : '${change >= 0 ? '+' : '−'}${formatNumber(change.abs(), d.digits)}'
              '${d.percent == null ? '' : ' (${d.percent! >= 0 ? '+' : '−'}${d.percent!.abs().toStringAsFixed(1)} %)'}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 170, child: Text(d.label, style: TextStyle(fontSize: 12.5, color: c.textMuted))),
          SizedBox(
            width: 190,
            child: Text(
              '${f(d.now)} against ${f(d.other)} ${d.unit}',
              style: TextStyle(fontSize: 12.5, color: c.text, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
          Text(
            text,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: d.better == null ? FontWeight.w400 : FontWeight.w600,
              color: worse ? c.danger : c.text,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (d.better != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(d.better! ? 'better' : 'worse', style: TextStyle(fontSize: 12, color: worse ? c.danger : c.textMuted)),
            ),
        ],
      ),
    );
  }
}
