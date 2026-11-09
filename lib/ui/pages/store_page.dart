import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/library.dart';
import '../../state/providers.dart';
import '../../theme.dart';

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
          for (final f in model.files) _FileRow(file: f),
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

/// One downloadable file: quantization, size, and Download / progress / Downloaded.
class _FileRow extends ConsumerWidget {
  const _FileRow({required this.file});

  final ModelFile file;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final library = ref.watch(libraryProvider);
    final notifier = ref.read(libraryProvider.notifier);
    final progress = library.progress[file.id];

    final Widget action;
    if (library.downloaded.contains(file.id)) {
      action = Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.check, size: 16, color: Color(0xFF1D9E75)),
        const SizedBox(width: 4),
        const Text('Downloaded', style: TextStyle(fontSize: 13, color: Color(0xFF1D9E75))),
        const SizedBox(width: 8),
        _TextAction(label: 'Delete', onTap: () => notifier.delete(file)),
      ]);
    } else if (progress != null) {
      action = Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 110,
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 5,
            borderRadius: BorderRadius.circular(3),
            color: c.text,
            backgroundColor: c.switchTrack,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 36,
          child: Text('${(progress * 100).round()} %', style: TextStyle(fontSize: 12, color: c.textSecondary)),
        ),
        _TextAction(label: 'Cancel', onTap: () => notifier.cancel(file.id)),
      ]);
    } else {
      action = OutlinedButton.icon(
        onPressed: () => notifier.download(file),
        icon: const Icon(Icons.download, size: 16),
        label: const Text('Download'),
        style: OutlinedButton.styleFrom(
          foregroundColor: c.text,
          side: BorderSide(color: c.inputBorder),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          visualDensity: VisualDensity.compact,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        Text(file.quantization, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.text)),
        const SizedBox(width: 8),
        Text('${(file.sizeBytes / 1e9).round()} GB', style: TextStyle(fontSize: 13, color: c.textMuted)),
        const Spacer(),
        action,
      ]),
    );
  }
}

class _TextAction extends StatelessWidget {
  const _TextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: context.colors.textSecondary,
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 13),
      ),
      child: Text(label),
    );
  }
}
