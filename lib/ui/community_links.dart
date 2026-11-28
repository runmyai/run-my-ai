import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/chats.dart';
import '../state/prefs.dart';
import '../system/open_url.dart';
import '../theme.dart';
import 'buttons.dart';

const starUsLabel = 'Star us on GitHub';
const starUsUrl = 'https://github.com/runmyai/run-my-ai';
const discordUrl = 'https://discord.gg/BfpvUFp58';
const sponsorUrl = 'https://github.com/sponsors/HarinManiK';

/// The project's accounts, as (name, address) pairs; the About and Community pages show them in this order.
const communityLinks = [
  ('GitHub', 'https://github.com/runmyai'),
  ('Discord', discordUrl),
  ('YouTube', 'https://www.youtube.com/@RunMyAI'),
  ('X', 'https://x.com/runmyai7'),
  ('LinkedIn', 'https://www.linkedin.com/company/run-my-ai'),
  ('Hugging Face', 'https://huggingface.co/runmyai'),
];

/// Opens a link in the browser (replaced in tests, which must not start one).
final linkOpenerProvider = Provider<Future<bool> Function(String)>((_) => openUrl);

const starCardText = 'Enjoying Run My AI? A star on GitHub helps others find it.';

/// RMAI_SHOW_STAR_CARD=1: the star card shows at every start, whatever was counted or saved, for looking at its design.
final starCardForcedProvider = Provider<bool>((_) => Platform.environment['RMAI_SHOW_STAR_CARD'] == '1');

/// The star card was closed in this session.
class _StarClosedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void close() => state = true;
}

final _starClosedProvider = NotifierProvider<_StarClosedNotifier, bool>(_StarClosedNotifier.new);

/// The star card shows: after the [starCardAfter]th finished reply ever until one of its buttons closes it for good,
/// and never while a reply is written.
final starCardProvider = Provider<bool>((ref) {
  if (ref.watch(_starClosedProvider) || ref.watch(chatsProvider.select((s) => s.replyingId != null))) return false;
  if (ref.watch(starCardForcedProvider)) return true;
  final (count, closed) = ref.watch(prefsProvider.select((p) => (p.starReplies, p.starCardClosed)));
  return !closed && count >= starCardAfter;
});

/// A small quiet card asking for a GitHub star, shown once (see [starCardProvider]); it fades in.
class StarCard extends ConsumerWidget {
  const StarCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(starCardProvider)) return const SizedBox.shrink();
    final c = context.colors;
    void close() {
      ref.read(_starClosedProvider.notifier).close();
      if (!ref.read(starCardForcedProvider)) ref.read(prefsProvider.notifier).closeStarCard();
    }

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      builder: (context, opacity, child) => Opacity(opacity: opacity, child: child),
      child: Container(
        key: const Key('star-card'),
        width: 290,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.inputFill,
          border: Border.all(color: c.inputBorder),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(starCardText, style: TextStyle(fontSize: 13, height: 1.4, color: c.textSecondary)),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                AppButton(key: const Key('star-card-later'), label: 'Not now', dense: true, onTap: close),
                MainButton(
                  key: const Key('star-card-star'),
                  label: 'Star on GitHub',
                  dense: true,
                  onTap: () {
                    ref.read(linkOpenerProvider)(starUsUrl);
                    close();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
