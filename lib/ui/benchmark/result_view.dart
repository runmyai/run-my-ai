import 'package:flutter/material.dart';

import '../../benchmark/benchmark.dart';
import '../../benchmark/engine_stats.dart';
import '../../benchmark/metrics.dart';
import '../../engine/commands.dart';
import '../../theme.dart';
import 'result_charts.dart';

/// The result of a run, the same right after it and in the history: where the time per token went (with the reply
/// speed test, when the engine split it), then the numbers of the chosen tests only: the reply speed, and a line per
/// prompt test with its prompt speed and time to first token. Everything else measured stays in the saved run.
class ResultView extends StatelessWidget {
  const ResultView({super.key, required this.result});

  final BenchmarkResult result;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = result;
    final tests = r.testResults;
    final reply = tests.where((t) => t.isReplySpeed).firstOrNull;
    final prompts = [for (final t in tests) if (!t.isReplySpeed) t];
    final perToken = reply == null || reply.turn.replyTokens == 0 ? 0.0 : reply.turn.replyMillis / reply.turn.replyTokens;
    final split = reply != null && perToken > 0 && hasTimeSplit(reply.timeParts);

    Widget tile(String key, String name, Widget body) => Container(
      key: Key('result-$key'),
      constraints: const BoxConstraints(minWidth: 150),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(color: c.text.withValues(alpha: 0.04), borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [body, const SizedBox(height: 2), Text(name, style: TextStyle(fontSize: 12, color: c.textMuted))],
      ),
    );
    const figures = [FontFeature.tabularFigures()];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${r.modelName}  ·  ${contextLabel(r.contextLength)}  ·  ${r.profileName}  ·  ${r.promptLabel}',
          style: TextStyle(fontSize: 13, color: c.textSecondary),
        ),
        const SizedBox(height: 12),
        if (split) ...[
          const SectionLabel('Where the time per token went'),
          TimePerToken(total: perToken, parts: reply.timeParts),
          const SizedBox(height: 18),
        ],
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (reply != null)
              tile(
                'reply-speed',
                'Reply speed',
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: reply.turn.tokensPerSecond.toStringAsFixed(1),
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: c.text),
                      ),
                      TextSpan(text: ' tokens/s', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                    ],
                  ),
                  style: const TextStyle(fontFeatures: figures),
                ),
              ),
            if (prompts.isNotEmpty)
              tile(
                'prompt-speed',
                'Prompt processing',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final t in prompts)
                      Padding(
                        key: Key('result-${t.testId}'),
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '${t.test.size} → ${formatNumber(t.turn.promptTokensPerSecond, 0)}',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.text),
                              ),
                              TextSpan(
                                text: ' tokens/s  ·  TTFT ${(t.turn.firstTokenMillis / 1000).toStringAsFixed(2)} s',
                                style: TextStyle(fontSize: 12.5, color: c.textMuted),
                              ),
                            ],
                          ),
                          style: const TextStyle(fontFeatures: figures),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A run's figure for its row in the history: the reply speed when it took that test, else its first prompt's speed.
String historyFigure(BenchmarkResult r) {
  final tests = r.testResults;
  final reply = tests.where((t) => t.isReplySpeed).firstOrNull;
  if (reply != null) return '${reply.turn.tokensPerSecond.toStringAsFixed(1)} tokens/s';
  final first = tests.first;
  return '${first.test.size} → ${formatNumber(first.turn.promptTokensPerSecond, 0)} tokens/s';
}
