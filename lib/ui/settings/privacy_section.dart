import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/prefs.dart';
import '../../theme.dart';

/// Settings: whether benchmark results and app stats may be shared (the same choice as on the welcome screen).
class PrivacySection extends ConsumerWidget {
  const PrivacySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final share = ref.watch(prefsProvider.select((p) => p.shareBenchmarks));
    final notifier = ref.read(prefsProvider.notifier);
    return InkWell(
      key: const Key('share-check'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => notifier.setShareBenchmarks(!share),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: share,
            onChanged: (v) => notifier.setShareBenchmarks(v ?? false),
            activeColor: c.mainFill,
            checkColor: c.mainText,
            side: BorderSide(color: c.buttonBorder, width: 1.5),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Share benchmark results and app stats to help improve Run My AI',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.text),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Anonymous, never your chats. You can turn this off anytime in Settings.',
                    style: TextStyle(fontSize: 13, color: c.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
