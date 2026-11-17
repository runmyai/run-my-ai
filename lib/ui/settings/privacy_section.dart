import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/prefs.dart';
import '../../theme.dart';
import '../buttons.dart';
import '../welcome.dart' show shareBenchmarksNote;

/// Settings: whether benchmark results may be shared (the same choice as on the welcome screen).
class PrivacySection extends ConsumerWidget {
  const PrivacySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final share = ref.watch(prefsProvider.select((p) => p.shareBenchmarks));
    final notifier = ref.read(prefsProvider.notifier);
    Widget choice(String id, String label, bool on) => OptionPill(
      key: Key(id),
      label: label,
      chosen: share == on,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      onTap: () => notifier.setShareBenchmarks(on),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Share benchmark results',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.text),
        ),
        const SizedBox(height: 2),
        Text(shareBenchmarksNote, style: TextStyle(fontSize: 13, color: c.textSecondary)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [choice('share-on', 'On', true), choice('share-off', 'Off', false)]),
      ],
    );
  }
}
