import 'package:flutter/material.dart';

import '../../theme.dart';

/// The Code section: a placeholder until Milestone 3.
class CodePage extends StatelessWidget {
  const CodePage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.code, size: 32, color: c.textMuted),
          const SizedBox(height: 12),
          Text('Code', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: c.text)),
          const SizedBox(height: 4),
          Text('Coming soon', style: TextStyle(fontSize: 14, color: c.textSecondary)),
        ],
      ),
    );
  }
}

/// A page with only a title and one line: Store and Settings in step 1.
class EmptyPage extends StatelessWidget {
  const EmptyPage({super.key, required this.title, required this.note});

  final String title;
  final String note;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 36, 40, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: c.text)),
            const SizedBox(height: 6),
            Text(note, style: TextStyle(fontSize: 14, color: c.textSecondary)),
          ],
        ),
      ),
    );
  }
}
