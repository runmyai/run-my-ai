import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/first_run.dart';
import '../state/prefs.dart';
import '../state/section.dart';
import '../theme.dart';
import 'buttons.dart';
import 'engine_setup.dart';
import 'title_bar.dart';

/// The app, with the first start over it: the welcome screen, then the engine step (unless an engine is already
/// there), then the main window, one at a time. The window's top row stays usable.
class FirstRunGate extends ConsumerStatefulWidget {
  const FirstRunGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<FirstRunGate> createState() => _FirstRunGateState();
}

class _FirstRunGateState extends ConsumerState<FirstRunGate> {
  @override
  void initState() {
    super.initState();
    // The app was closed in the engine step last time: the step comes back, as the app has no engine yet.
    final f = ref.read(firstRunProvider);
    if (f.welcomeShown && f.setupOpen) WidgetsBinding.instance.addPostFrameCallback((_) => _afterWelcome());
  }

  /// The engine step if the engine is missing, then the chat section of the main window.
  Future<void> _afterWelcome() async {
    if (engineMissing(ref)) await showEngineSetup(context, firstStart: true);
    if (!mounted) return;
    ref.read(sectionProvider.notifier).select(Section.chat);
    ref.read(firstRunProvider.notifier).setupDone();
  }

  @override
  Widget build(BuildContext context) {
    final f = ref.watch(firstRunProvider);
    final cover = !f.welcomeShown || f.setupOpen;
    return Stack(
      children: [
        ExcludeFocus(excluding: cover, child: widget.child),
        if (cover)
          Positioned.fill(
            top: titleBarHeight,
            // Behind the engine step a plain page, so the main window first shows when it can be used.
            child: f.welcomeShown
                ? Material(color: context.colors.page)
                : _Welcome(
                    onStart: () {
                      ref.read(firstRunProvider.notifier).welcomeDone();
                      _afterWelcome();
                    },
                  ),
          ),
      ],
    );
  }
}

class _Welcome extends ConsumerWidget {
  const _Welcome({required this.onStart});

  final VoidCallback onStart;

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
                Row(
                  children: [
                    // The app's mark, as in the window's top row, about as tall as the title's capitals and ascenders.
                    Image.asset(
                      c.isLight ? 'assets/logo/mark-light.png' : 'assets/logo/mark-dark.png',
                      height: 26,
                      filterQuality: FilterQuality.medium,
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        'Welcome to Run My AI',
                        style: TextStyle(fontSize: 31, fontWeight: FontWeight.w600, color: c.text),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'Simple, private, fast and models beyond your memory. This is an early version, getting better every '
                  "week. We're here to provide you the best local AI experience. We'd love to hear from you anytime.",
                  style: TextStyle(fontSize: 17, height: 1.5, color: Color.lerp(c.textSecondary, c.text, 0.6)),
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
                        // A little smaller than usual: a second choice under the main text.
                        Transform.scale(
                          scale: 0.88,
                          child: Checkbox(
                            value: share,
                            onChanged: (v) => ref.read(prefsProvider.notifier).setShareBenchmarks(v ?? false),
                            activeColor: c.mainFill,
                            checkColor: c.mainText,
                            side: BorderSide(color: c.buttonBorder, width: 1.5),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(shareBenchmarksLabel, style: TextStyle(fontSize: 14, color: c.text)),
                                const SizedBox(height: 3),
                                Text(shareBenchmarksNote, style: TextStyle(fontSize: 13, color: c.textMuted)),
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
                  onTap: onStart,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The choice to share benchmark results and app stats.
const shareBenchmarksLabel = 'Share benchmark results and app stats to help improve Run My AI';

/// The small line under the choice to share benchmark results and app stats (here and in Settings).
const shareBenchmarksNote = 'Anonymous, never your chats. You can turn this off anytime in Settings.';
