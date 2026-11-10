import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/prefs.dart';
import 'buttons.dart';

/// The bulb: whether the model thinks before it answers. A change applies from the next reply.
/// A model without the choice shows it lit, and says so.
class ThinkingToggle extends ConsumerWidget {
  const ThinkingToggle({super.key, required this.canChoose});

  final bool canChoose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = !canChoose || ref.watch(prefsProvider.select((p) => p.thinking));
    final tooltip = !canChoose
        ? 'This model thinks before it answers.'
        : on
        ? 'Thinking is on. Click to turn it off.'
        : 'Thinking is off. Click to turn it on.';
    // Quiet at rest: only the bulb; a soft round background comes under the pointer, when it can be switched.
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: AppIconButton(
        key: const Key('thinking-toggle'),
        tooltip: tooltip,
        icon: on ? Icons.lightbulb : Icons.lightbulb_outline,
        round: true,
        muted: !on,
        keepIconColor: true,
        size: 28,
        iconSize: 16,
        tooltipWait: const Duration(milliseconds: 1500),
        onTap: canChoose ? () => ref.read(prefsProvider.notifier).toggleThinking() : null,
      ),
    );
  }
}
