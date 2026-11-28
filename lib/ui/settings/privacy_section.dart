import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/prefs.dart';
import '../../theme.dart';
import '../welcome.dart' show shareBenchmarksLabel, shareBenchmarksNote;

/// Whether benchmark results and app stats may be shared: one small, quiet line (a small box and muted text), the same
/// choice on the welcome screen ([firstStart]: its note written under it) and in Settings (its note a tooltip).
class PrivacySection extends ConsumerWidget {
  const PrivacySection({super.key, this.firstStart = false});

  final bool firstStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final share = ref.watch(prefsProvider.select((p) => p.shareBenchmarks));
    final notifier = ref.read(prefsProvider.notifier);
    final label = Text(shareBenchmarksLabel, style: TextStyle(fontSize: 12, color: c.textMuted));
    // (Aligned so the line is only as wide as its text, also in a list that stretches its rows.)
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        key: Key(firstStart ? 'welcome-share' : 'share-check'),
        borderRadius: BorderRadius.circular(6),
        onTap: () => notifier.setShareBenchmarks(!share),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox.square(
                dimension: 16,
                child: Transform.scale(
                  scale: 0.75,
                  child: Checkbox(
                    value: share,
                    onChanged: (v) => notifier.setShareBenchmarks(v ?? false),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    activeColor: c.mainFill,
                    checkColor: c.mainText,
                    side: BorderSide(color: c.buttonBorder, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: firstStart
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          label,
                          Text(shareBenchmarksNote, style: TextStyle(fontSize: 11.5, color: c.textMuted)),
                        ],
                      )
                    : Tooltip(message: shareBenchmarksNote, child: label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
