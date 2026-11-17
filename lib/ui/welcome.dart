import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/first_run.dart';
import '../state/prefs.dart';
import '../theme.dart';
import 'buttons.dart';
import 'engine_setup.dart';
import 'title_bar.dart';

/// What happens after the welcome screen's "Get started": the engine download step, unless an engine is already there.
Future<void> afterWelcome(BuildContext context, WidgetRef ref) async {
  if (engineMissing(ref)) await showEngineSetup(context);
}

/// The app, with the welcome screen over it on the very first start. The window's top row stays usable.
class FirstRunGate extends ConsumerWidget {
  const FirstRunGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = !ref.watch(firstRunProvider.select((f) => f.welcomeShown));
    return Stack(
      children: [
        ExcludeFocus(excluding: show, child: child),
        if (show) const Positioned.fill(top: titleBarHeight, child: _Welcome()),
      ],
    );
  }
}

class _Welcome extends ConsumerWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final share = ref.watch(prefsProvider.select((p) => p.shareBenchmarks));
    return Material(
      key: const Key('welcome'),
      color: c.page,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Welcome to Run My AI',
                  style: TextStyle(fontSize: 31, fontWeight: FontWeight.w600, color: c.text),
                ),
                const SizedBox(height: 14),
                Text(
                  'Simple, private, fast and models beyond your memory. This is an early version, getting better every '
                  "week. We're here to provide you the best local AI experience. We'd love to hear from you anytime.",
                  style: TextStyle(fontSize: 16.5, height: 1.5, color: c.textSecondary),
                ),
                const SizedBox(height: 28),
                InkWell(
                  key: const Key('welcome-share'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => ref.read(prefsProvider.notifier).setShareBenchmarks(!share),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Checkbox(
                          value: share,
                          onChanged: (v) => ref.read(prefsProvider.notifier).setShareBenchmarks(v ?? false),
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
                                  'Share benchmark results to help make Run My AI faster',
                                  style: TextStyle(fontSize: 15, color: c.text),
                                ),
                                const SizedBox(height: 4),
                                Text(shareBenchmarksNote, style: TextStyle(fontSize: 13.5, color: c.textMuted)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                MainButton(
                  key: const Key('welcome-start'),
                  label: 'Get started',
                  autofocus: true,
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
                  onTap: () async {
                    ref.read(firstRunProvider.notifier).welcomeDone();
                    await afterWelcome(context, ref);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The small line under the choice to share benchmark results (here and in Settings).
const shareBenchmarksNote =
    'Only benchmark numbers (your hardware and speeds), never your chats. You can turn this off anytime in Settings.';
