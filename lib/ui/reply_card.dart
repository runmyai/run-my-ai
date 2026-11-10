import 'package:flutter/material.dart';

import '../benchmark/metrics.dart' show formatNumber;
import '../data/reply_stats.dart';
import '../engine/commands.dart';
import '../theme.dart';

/// The lines of a reply's card, name and value: only the numbers the engine gave.
List<(String, String)> replyFacts(ReplyStats s) {
  String seconds(double ms) => ms >= 10000 ? '${(ms / 1000).toStringAsFixed(0)} s' : '${(ms / 1000).toStringAsFixed(ms < 1000 ? 2 : 1)} s';
  final tokens = [
    if (s.promptTokens != null) 'in ${formatNumber(s.promptTokens!.toDouble(), 0)}',
    if (s.replyTokens != null) 'out ${formatNumber(s.replyTokens!.toDouble(), 0)}',
  ];
  return [
    if (s.wordsPerSecond != null) ('Generation speed', '${s.wordsPerSecond!.toStringAsFixed(1)} tokens/s'),
    if (s.promptTokensPerSecond != null) ('Prompt processing', '${formatNumber(s.promptTokensPerSecond!, 0)} tokens/s'),
    if (s.firstWordMillis != null) ('TTFT', seconds(s.firstWordMillis!)),
    if (tokens.isNotEmpty) ('Tokens', tokens.join('  ·  ')),
    if (s.totalMillis != null) ('Time', seconds(s.totalMillis!)),
    if (s.ssdWaitPerWord != null) ('SSD wait', '${s.ssdWaitPerWord!.toStringAsFixed(1)} ms/token'),
    if (s.hitRate != null) ('Found in RAM', '${s.hitRate!.toStringAsFixed(0)} %'),
  ];
}

/// What wrote the reply: the model, the profile and the context length, as one line; empty when none is known.
String replyBasis(ReplyStats s) => [
  if (s.modelName != null) s.modelName!,
  if (s.profileName != null) s.profileName!,
  if (s.contextLength != null) contextLabel(s.contextLength!),
].join('  ·  ');

/// The small card the "⋯" button under a reply opens: how the reply went, and what wrote it.
class ReplyStatsCard extends StatelessWidget {
  const ReplyStatsCard({super.key, required this.stats});

  final ReplyStats stats;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final basis = replyBasis(stats);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 250, maxWidth: 340),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (name, value) in replyFacts(stats))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 124, child: Text(name, style: TextStyle(fontSize: 12.5, color: c.textMuted))),
                    Expanded(
                      child: Text(
                        value,
                        style: TextStyle(fontSize: 12.5, color: c.text, fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                    ),
                  ],
                ),
              ),
            if (basis.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(basis, key: const Key('reply-card-basis'), style: TextStyle(fontSize: 12, color: c.textMuted)),
            ],
          ],
        ),
      ),
    );
  }
}
