import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import '../buttons.dart';
import '../community_links.dart';

/// The Community page: three cards (a GitHub star, the Discord, sponsoring) and the project's accounts.
class CommunityPage extends ConsumerWidget {
  const CommunityPage({super.key});

  /// Below this width the cards stand in a column.
  static const _rowWidth = 640.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final open = ref.read(linkOpenerProvider);
    final cards = [
      _Card(
        id: 'star',
        title: starUsLabel,
        line: 'A star helps more people find Run My AI.',
        button: MainButton(
          key: const Key('community-card-star'),
          label: 'Star on GitHub',
          onTap: () => open(starUsUrl),
        ),
      ),
      _Card(
        id: 'discord',
        title: 'Join the Discord',
        line: 'Get help, share ideas and hear about updates first.',
        button: AppButton(
          key: const Key('community-card-discord'),
          label: 'Join Discord',
          onTap: () => open(discordUrl),
        ),
      ),
      _Card(
        id: 'sponsor',
        title: 'Sponsor',
        line: 'Help keep Run My AI free for everyone.',
        button: AppButton(key: const Key('community-card-sponsor'), label: 'Sponsor', onTap: () => open(sponsorUrl)),
      ),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 40),
      children: [
        Text(
          'Community',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: c.text),
        ),
        const SizedBox(height: 8),
        Text(
          "Run My AI is free and open source. Here's how to follow along and help.",
          style: TextStyle(fontSize: 14, color: c.textMuted),
        ),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, box) => box.maxWidth >= _rowWidth
              ? IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 12,
                    children: [for (final card in cards) Expanded(child: card)],
                  ),
                )
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 12, children: cards),
        ),
        const SizedBox(height: 28),
        Text(
          'Follow us',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.text),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (name, url) in communityLinks)
              InkWell(
                key: Key('follow-$name'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => open(url),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SocialIcon(name.toLowerCase().replaceAll(' ', ''), color: c.textSecondary),
                      const SizedBox(width: 8),
                      Text(name, style: TextStyle(fontSize: 14, color: c.text)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// One of the three cards: its icon, a title, one line and a button at the bottom.
class _Card extends StatelessWidget {
  const _Card({required this.id, required this.title, required this.line, required this.button});

  /// Also the name of its picture in assets/social.
  final String id;
  final String title, line;
  final Widget button;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      key: Key('community-card-$id-box'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: c.inputFill,
        border: Border.all(color: c.inputBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      // (Side by side the cards are as tall as the tallest: the buttons stay level at the bottom.)
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SocialIcon(id, color: c.text, size: 22),
              const SizedBox(height: 12),
              Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: c.text)),
              const SizedBox(height: 6),
              Text(line, style: TextStyle(fontSize: 13, height: 1.4, color: c.textSecondary)),
              const SizedBox(height: 16),
            ],
          ),
          button,
        ],
      ),
    );
  }
}

/// A monochrome picture from assets/social, in [color].
class _SocialIcon extends StatelessWidget {
  const _SocialIcon(this.name, {required this.color, this.size = 16});

  final String name;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/social/$name.png',
    width: size,
    height: size,
    color: color,
    filterQuality: FilterQuality.medium,
  );
}
