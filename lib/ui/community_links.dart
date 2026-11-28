import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/prefs.dart';
import '../system/open_url.dart';
import '../theme.dart';

const starUsLabel = 'Star us on GitHub';
const starUsUrl = 'https://github.com/runmyai/run-my-ai';
const discordUrl = 'https://discord.gg/BfpvUFp58';
const sponsorUrl = 'https://github.com/sponsors/HarinManiK';

/// The project's accounts, as (name, address) pairs; the About page writes them out in this order.
const communityLinks = [
  ('GitHub', 'https://github.com/runmyai'),
  ('Discord', discordUrl),
  ('YouTube', 'https://www.youtube.com/@RunMyAI'),
  ('X', 'https://x.com/runmyai7'),
  ('LinkedIn', 'https://www.linkedin.com/company/run-my-ai'),
  ('Hugging Face', 'https://huggingface.co/runmyai'),
];

/// The sidebar's icons: (tooltip, picture in assets/social, address).
const _icons = [
  (starUsLabel, 'star', starUsUrl),
  ('Discord', 'discord', discordUrl),
  ('YouTube', 'youtube', 'https://www.youtube.com/@RunMyAI'),
  ('X', 'x', 'https://x.com/runmyai7'),
  ('LinkedIn', 'linkedin', 'https://www.linkedin.com/company/run-my-ai'),
  ('Hugging Face', 'huggingface', 'https://huggingface.co/runmyai'),
  ('Sponsor', 'sponsor', sponsorUrl),
];

/// One row of small muted icons, each opening its link; brighter under the pointer.
class CommunityIcons extends StatelessWidget {
  const CommunityIcons({super.key});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [for (final (tip, name, url) in _icons) _Icon(tip: tip, name: name, url: url)],
  );
}

class _Icon extends StatefulWidget {
  const _Icon({required this.tip, required this.name, required this.url});

  final String tip, name, url;

  @override
  State<_Icon> createState() => _IconState();
}

class _IconState extends State<_Icon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: widget.tip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          key: Key('community-icon-${widget.name}'),
          borderRadius: BorderRadius.circular(6),
          onTap: () => openUrl(widget.url),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Image.asset(
              'assets/social/${widget.name}.png',
              width: 16,
              height: 16,
              color: _hover ? c.sideText : c.sideMuted,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      ),
    );
  }
}

/// How long after the app starts the line under the message box shows.
const communityLineTime = Duration(minutes: 10);

/// The time the line's ten minutes are counted by (replaced in tests).
final communityClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// Which step of the line under the message box is up this session (0 GitHub, 1 Discord), or null for none: when
/// the step is closed (the next one waits for the next start), or when all are done..
class CommunityAskNotifier extends Notifier<int?> {
  late final DateTime _start;

  @override
  int? build() {
    _start = ref.read(communityClockProvider)();
    final step = ref.read(prefsProvider).communityStep;
    return step > 1 ? null : step;
  }

  /// How much of the ten minutes is left.
  Duration get left => communityLineTime - ref.read(communityClockProvider)().difference(_start);

  void close() {
    final step = state;
    if (step == null) return;
    ref.read(prefsProvider.notifier).setCommunityStep(step + 1);
    state = null;
  }
}

final communityAskProvider = NotifierProvider<CommunityAskNotifier, int?>(CommunityAskNotifier.new);

/// One quiet line under the message box: the step's ask, an open-link icon after it, and a close button. It shows
/// during the first [communityLineTime] after the app starts.
class CommunityLine extends ConsumerStatefulWidget {
  const CommunityLine({super.key});

  @override
  ConsumerState<CommunityLine> createState() => _CommunityLineState();
}

class _CommunityLineState extends ConsumerState<CommunityLine> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final left = ref.read(communityAskProvider.notifier).left;
    if (left > Duration.zero) _timer = Timer(left, () => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final step = ref.watch(communityAskProvider);
    if (step == null || ref.read(communityAskProvider.notifier).left <= Duration.zero) return const SizedBox.shrink();
    final color = context.colors.textMuted;
    final (key, text, url) = step == 0
        ? (const Key('line-star'), '⭐ $starUsLabel', starUsUrl)
        : (const Key('line-discord'), 'Join us on Discord', discordUrl);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          InkWell(
            key: key,
            borderRadius: BorderRadius.circular(4),
            onTap: () => openUrl(url),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(text, style: TextStyle(fontSize: 12, color: color)),
                const SizedBox(width: 4),
                Icon(Icons.open_in_new, size: 12, color: color),
              ],
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            key: const Key('line-close'),
            borderRadius: BorderRadius.circular(10),
            onTap: ref.read(communityAskProvider.notifier).close,
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(Icons.close, size: 13, semanticLabel: 'Close', color: color),
            ),
          ),
        ],
      ),
    );
  }
}
