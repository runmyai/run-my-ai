import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/backend.dart';
import '../../data/models.dart';
import '../../state/benchmark.dart';
import '../../state/chats.dart';
import '../../state/library.dart';
import '../../state/providers.dart';
import '../../state/tuning_runs.dart';
import '../../system/folders.dart';
import '../../theme.dart';
import '../buttons.dart';

/// The Store: selected models, grouped by company / lab.
class StorePage extends ConsumerWidget {
  const StorePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final catalog = ref.watch(catalogProvider).value ?? const <CatalogModel>[];
    final labs = <String, List<CatalogModel>>{};
    for (final m in catalog) {
      labs.putIfAbsent(m.lab, () => []).add(m);
    }

    return ListView(
      // The window's top row is above, so little room is needed here.
      padding: const EdgeInsets.fromLTRB(40, 4, 40, 40),
      children: [
        Text('Store', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: c.text)),
        const SizedBox(height: 6),
        Text(
          catalog.isEmpty ? 'The model catalog is empty for now.' : 'Selected models, ready to run on your computer.',
          style: TextStyle(fontSize: 14, color: c.textSecondary),
        ),
        for (final lab in labs.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 28, 0, 10),
            child: Text(lab.key, style: TextStyle(fontSize: 13, color: c.textMuted)),
          ),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [for (final m in lab.value) _ModelCard(model: m)],
          ),
        ],
      ],
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({required this.model});

  final CatalogModel model;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 400,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(model.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.text)),
          const SizedBox(height: 4),
          Text(model.description, style: TextStyle(fontSize: 14, color: c.textSecondary)),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _Fact('${model.parameters} parameters'),
            _Fact('${model.activeParameters} active'),
          ]),
          const SizedBox(height: 12),
          for (final f in model.files) _FileRow(file: f, model: model),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.switchTrack, borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: TextStyle(fontSize: 12, color: c.textSecondary)),
    );
  }
}

/// One downloadable file: quantization, size, and Download / its download's progress, speed and time left, with
/// Pause / Resume / Cancel / Checking / Tuning for your PC / Downloaded + Tune + Delete.
class _FileRow extends ConsumerWidget {
  const _FileRow({required this.file, required this.model});

  final ModelFile file;
  final CatalogModel model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final downloaded = ref.watch(libraryProvider.select((l) => l.downloaded.contains(file.id)));
    final status = ref.watch(libraryProvider.select((l) => l.downloads[file.id]));
    final folders = ref.watch(foldersProvider);
    final notifier = ref.read(libraryProvider.notifier);
    // Delete only removes what is in the models folder; a model read from another folder stays the user's.
    final deletable = file.repo == null || folders.folderWith(file.parts) == folders.models;
    final tune = ref.watch(
      tuningRunsProvider.select(
        (t) => (now: t.tuning == file.id, waiting: t.waiting.contains(file.id), busy: t.busy.contains(file.id)),
      ),
    );
    final tunable = ref.watch(backendProvider) is TuneControl;
    // (Tune waits while the engine reads a prompt or writes a reply.)
    final engineBusy =
        ref.watch(chatsProvider.select((s) => s.replyingId != null)) ||
        ref.watch(benchmarkProvider.select((s) => s.running));
    final tuning = downloaded && (tune.now || tune.waiting);

    final List<Widget> actions;
    if (tuning) {
      actions = const [];
    } else if (downloaded) {
      actions = [
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check, size: 16, color: Color(0xFF1D9E75)),
            SizedBox(width: 4),
            Text('Downloaded', style: TextStyle(fontSize: 13, color: Color(0xFF1D9E75))),
          ],
        ),
        if (tunable)
          _TextAction(
            key: Key('tune-again-${file.id}'),
            label: 'Tune',
            onTap: engineBusy ? null : () => ref.read(tuningRunsProvider.notifier).tuneAgain(file),
          ),
        if (deletable)
          _TextAction(
            label: 'Delete',
            onTap: () async {
              if (await _confirmDelete(context, model.name, file.sizeBytes) == true) await notifier.delete(file);
            },
          ),
      ];
    } else if (status == null) {
      actions = [AppButton(label: 'Download', icon: Icons.download, dense: true, onTap: () => notifier.download(file))];
    } else {
      actions = [
        switch (status.phase) {
          DownloadPhase.downloading => _TextAction(label: 'Pause', onTap: () => notifier.pause(file.id)),
          DownloadPhase.paused => _TextAction(label: 'Resume', onTap: () => notifier.download(file)),
          DownloadPhase.failed => _TextAction(
            label: status.broken ? 'Download again' : 'Resume',
            onTap: () => notifier.download(file),
          ),
          DownloadPhase.queued || DownloadPhase.checking => const SizedBox.shrink(),
        },
        if (status.phase != DownloadPhase.checking) ...[
          const SizedBox(width: 6),
          _TextAction(label: 'Cancel', onTap: () => notifier.cancel(file.id)),
        ],
      ];
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                file.quantization,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.text),
              ),
              const SizedBox(width: 8),
              Text('${(file.sizeBytes / 1e9).round()} GB', style: TextStyle(fontSize: 13, color: c.textMuted)),
              const SizedBox(width: 8),
              // (The buttons go on a second line when a long quantization name leaves no room.)
              Expanded(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: downloaded ? 8 : 0,
                  runSpacing: 4,
                  children: actions,
                ),
              ),
            ],
          ),
          if (tuning) ...[
            const SizedBox(height: 8),
            if (tune.now)
              LinearProgressIndicator(
                minHeight: 5,
                borderRadius: BorderRadius.circular(3),
                color: c.text,
                backgroundColor: c.switchTrack,
              ),
            const SizedBox(height: 4),
            Text(
              tune.now ? 'Tuning for your PC...' : 'Tuning for your PC when the engine is free...',
              key: Key('tune-status-${file.id}'),
              style: TextStyle(fontSize: 12, color: c.textSecondary),
            ),
          ] else if (downloaded && tune.busy) ...[
            const SizedBox(height: 4),
            Text(
              'Your PC was busy while tuning. Close background apps and tune again for the best speed.',
              key: Key('tune-status-${file.id}'),
              style: TextStyle(fontSize: 12, color: c.textSecondary),
            ),
          ],
          if (status != null && !downloaded) ...[
            const SizedBox(height: 8),
            if (status.phase != DownloadPhase.failed && status.phase != DownloadPhase.queued)
              LinearProgressIndicator(
                value: status.phase == DownloadPhase.checking ? null : status.fraction,
                minHeight: 5,
                borderRadius: BorderRadius.circular(3),
                color: c.text,
                backgroundColor: c.switchTrack,
              ),
            const SizedBox(height: 4),
            Text(
              _statusLine(status),
              key: Key('download-status-${file.id}'),
              style: TextStyle(fontSize: 12, color: c.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

/// What a download's line says under its row.
String _statusLine(DownloadStatus s) {
  final percent = '${(s.fraction * 100).floor()} %';
  switch (s.phase) {
    case DownloadPhase.queued:
      return 'Queued';
    case DownloadPhase.checking:
      return 'Checking...';
    case DownloadPhase.paused:
      return 'Paused · $percent';
    case DownloadPhase.failed:
      return s.message ?? 'The download stopped.';
    case DownloadPhase.downloading:
      final speed = s.bytesPerSecond, left = s.timeLeft;
      return [
        percent,
        if (speed != null) '${(speed / 1e6).toStringAsFixed(1)} MB/s',
        if (left != null) '${_duration(left)} left',
      ].join(' · ');
  }
}

String _duration(Duration d) => d.inHours > 0
    ? '${d.inHours} h ${d.inMinutes % 60} min'
    : d.inMinutes > 0
    ? '${d.inMinutes} min'
    : '${d.inSeconds} s';

/// "Delete (the model)?" with Cancel (chosen when it opens) and Delete.
Future<bool?> _confirmDelete(BuildContext context, String name, int bytes) => showDialog<bool>(
  context: context,
  builder: (context) {
    final c = context.colors;
    return AlertDialog(
      constraints: const BoxConstraints(maxWidth: 400),
      content: Text(
        'Delete $name? Its ${(bytes / 1e9).round()} GB will have to be downloaded again to use it.',
        style: TextStyle(fontSize: 15, height: 1.5, color: c.text),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      actions: [
        AppButton(label: 'Cancel', autofocus: true, ringAlways: true, onTap: () => Navigator.pop(context, false)),
        AppButton(
          key: const Key('delete-model-confirm'),
          label: 'Delete',
          danger: true,
          onTap: () => Navigator.pop(context, true),
        ),
      ],
    );
  },
);

class _TextAction extends StatelessWidget {
  const _TextAction({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => AppButton(label: label, dense: true, onTap: onTap);
}
