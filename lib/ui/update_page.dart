import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/updates.dart';
import '../system/open_url.dart';
import '../system/updater.dart';
import '../theme.dart';
import 'buttons.dart';
import 'markdown/md_view.dart';

/// The download arrow in the title bar, there only when something newer is out; a click opens the update page.
class UpdateButton extends ConsumerWidget {
  const UpdateButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(updatesProvider.select((s) => s.any))) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: AppIconButton(
        key: const Key('update-button'),
        icon: Icons.download_rounded,
        tooltip: 'Updates are ready',
        onTap: () => showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const UpdatePage()),
        size: 32,
      ),
    );
  }
}

String _size(int? bytes) => bytes == null
    ? ''
    : bytes >= 1e9
    ? '${(bytes / 1e9).toStringAsFixed(1)} GB'
    : '${(bytes / 1e6).toStringAsFixed(bytes >= 1e7 ? 0 : 1)} MB';

/// What is newer, with the notes of every version since the one on this PC (newest first) and the download sizes, and
/// one Update button for all of it; while it updates, "Updating..." with its progress.
class UpdatePage extends ConsumerWidget {
  const UpdatePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final s = ref.watch(updatesProvider);
    final small = TextStyle(fontSize: 13, height: 1.4, color: c.textSecondary);
    final notesStyle = TextStyle(fontSize: 14, height: 1.5, color: c.text);

    Widget heading(String title, String size) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Text(
        [title, size].where((t) => t.isNotEmpty).join(' · '),
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.text),
      ),
    );

    Widget version(String name, String notes) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: small.copyWith(fontWeight: FontWeight.w600)),
          if (notes.trim().isNotEmpty) ...[
            const SizedBox(height: 2),
            MarkdownView(text: notes.trim(), style: notesStyle),
          ],
        ],
      ),
    );

    final app = s.app, engine = s.engine;
    final list = <Widget>[
      if (app != null) ...[
        heading('Run My AI ${app.newest.tag}', app.manual == null ? _size(app.size) : ''),
        if (app.manual != null) ...[
          Text(app.manual!, key: const Key('update-app-manual'), style: small),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(label: 'Open the website', dense: true, onTap: () => openUrl(websiteUrl)),
          ),
        ],
        for (final r in app.releases) version(r.tag, r.notes),
      ],
      if (engine != null) ...[
        heading('TokenWing engine ${engine.newest.tag}', _size(engine.size)),
        for (final r in engine.releases) version(r.tag, r.notes),
      ],
      for (final m in s.models) ...[
        heading(m.name, _size(m.size)),
        for (final v in m.versions) version(v.version, v.notes),
      ],
    ];

    final progress = s.progress;
    final body = s.updating
        ? <Widget>[
            Text(s.step ?? 'Updating...', key: const Key('update-step'), style: small),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: progress == null || progress.checking || progress.total == 0
                  ? null
                  : progress.done / progress.total,
              minHeight: 5,
              borderRadius: BorderRadius.circular(3),
              color: c.text,
              backgroundColor: c.switchTrack,
            ),
            const SizedBox(height: 6),
            Text(
              progress == null
                  ? ''
                  : progress.checking
                  ? 'Checking...'
                  : '${(progress.done * 100 / (progress.total == 0 ? 1 : progress.total)).floor()} % of ${_size(progress.total)}',
              style: small,
            ),
          ]
        : <Widget>[
            Flexible(
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: list),
              ),
            ),
            if (s.message != null) ...[
              const SizedBox(height: 12),
              Text(
                s.message!,
                key: const Key('update-message'),
                style: TextStyle(fontSize: 13, color: s.failed ? c.danger : c.textSecondary),
              ),
            ],
          ];

    return Dialog(
      backgroundColor: c.page,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            key: const Key('update-page'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.updating ? 'Updating...' : 'Updates',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: c.text),
              ),
              const SizedBox(height: 10),
              ...body,
              if (!s.updating) ...[
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  spacing: 8,
                  children: [
                    AppButton(key: const Key('update-close'), label: 'Close', onTap: () => Navigator.pop(context)),
                    if (s.updatable)
                      MainButton(
                        key: const Key('update-now'),
                        label: 'Update',
                        autofocus: true,
                        onTap: ref.read(updatesProvider.notifier).update,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
