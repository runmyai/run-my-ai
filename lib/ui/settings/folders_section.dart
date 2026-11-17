import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/backend.dart';
import '../../backend/engine_backend.dart';
import '../../state/library.dart';
import '../../state/prefs.dart';
import '../../state/providers.dart';
import '../../system/folders.dart';
import '../../theme.dart';
import '../buttons.dart';

/// Settings' folders: where models are downloaded, the folders models are also read from, the chats, the saved
/// chat states and the engine. Moving one copies its files to the new place and then removes the old ones (on the
/// same drive they are simply moved); the engine is stopped first, and downloads are paused before the models move.
class FoldersSection extends ConsumerStatefulWidget {
  const FoldersSection({super.key});

  @override
  ConsumerState<FoldersSection> createState() => _FoldersSectionState();
}

class _FoldersSectionState extends ConsumerState<FoldersSection> {
  /// The folder being moved (its row's id), and how far: [_done] of [_total] bytes.
  String? _moving;
  var _done = 0, _total = 0;

  /// The last move's failure, by row id.
  String? _failedRow, _failure;

  Future<void> _stopEngine() async {
    final Object backend = ref.read(backendProvider);
    if (backend is EngineControl) await backend.stopEngine();
  }

  /// Moves the folder of row [id] from [from] to a folder the user picks, then [save]s the new place.
  Future<void> _move(String id, String from, Future<void> Function() before, void Function(String to) save) async {
    final to = await getDirectoryPath(initialDirectory: from, confirmButtonText: 'Move here');
    if (to == null || !mounted) return;
    setState(() {
      _moving = id;
      _done = _total = 0;
      _failedRow = _failure = null;
    });
    try {
      await before();
      await moveFolder(
        from,
        to,
        progress: (done, total) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
          });
        },
      );
      save(to);
    } on FolderMoveFailure catch (e) {
      if (mounted) {
        setState(() {
          _failedRow = id;
          _failure = e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _moving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final folders = ref.watch(foldersProvider);
    final notifier = ref.read(foldersProvider.notifier);
    final own = ref.watch(prefsProvider.select((p) => p.engineFolder));
    final engine = EngineBackend.engineFolder(own, folders);
    final busy = _moving != null;

    Widget row(
      String id,
      String title,
      String about,
      String path, {
      required VoidCallback onMove,
      String label = 'Move...',
    }) => _FolderRow(
      id: id,
      title: title,
      about: about,
      path: path,
      button: AppButton(key: Key('folder-move-$id'), label: label, dense: true, onTap: busy ? null : onMove),
      progress: _moving == id ? (_done, _total) : null,
      failure: _failedRow == id ? _failure : null,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Folders',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.text),
        ),
        const SizedBox(height: 2),
        Text(
          'Where Run My AI keeps its files. Moving a folder takes its files along.',
          style: TextStyle(fontSize: 13, color: c.textSecondary),
        ),
        row(
          'models',
          'Models',
          'Downloaded models go here.',
          folders.models,
          onMove: () => _move('models', folders.models, () async {
            await ref.read(libraryProvider.notifier).pauseAll();
            await _stopEngine();
          }, (to) => notifier.set(folders.copyWith(models: to, readFrom: [...folders.readFrom]..remove(to)))),
        ),
        _ReadFolders(
          folders: folders.readFrom,
          enabled: !busy,
          onAdd: () async {
            final dir = await getDirectoryPath(confirmButtonText: 'Read models here');
            if (dir == null || dir == folders.models || folders.readFrom.contains(dir)) return;
            notifier.set(folders.copyWith(readFrom: [...folders.readFrom, dir]));
          },
          onRemove: (dir) => notifier.set(folders.copyWith(readFrom: [...folders.readFrom]..remove(dir))),
        ),
        row(
          'chats',
          'Chats',
          'Your chats, one file each.',
          folders.chats,
          onMove: () => _move('chats', folders.chats, () async {}, (to) => notifier.set(folders.copyWith(chats: to))),
        ),
        row(
          'cache',
          'Saved chat states',
          'What lets a chat continue quickly. The engine stops while it moves.',
          folders.cache,
          onMove: () => _move('cache', folders.cache, _stopEngine, (to) => notifier.set(folders.copyWith(cache: to))),
        ),
        // The engine next to the app is part of the app: another folder is chosen, nothing is moved out of it.
        engine == EngineBackend.defaultEngineFolder
            ? row(
                'engine',
                'Engine',
                'The engine Run My AI runs. A change applies the next time it starts.',
                engine,
                label: 'Choose...',
                onMove: () async {
                  final dir = await getDirectoryPath(initialDirectory: engine);
                  if (dir != null) ref.read(prefsProvider.notifier).setEngineFolder(dir);
                },
              )
            : row(
                'engine',
                'Engine',
                'The engine Run My AI runs. It stops while it moves.',
                engine,
                onMove: () => _move('engine', engine, _stopEngine, ref.read(prefsProvider.notifier).setEngineFolder),
              ),
      ],
    );
  }
}

/// One folder: its name, what it is for, where it is, its button; while it moves, how far; after a failed move, why.
class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.id,
    required this.title,
    required this.about,
    required this.path,
    required this.button,
    this.progress,
    this.failure,
  });

  final String id, title, about, path;
  final Widget button;
  final (int, int)? progress;
  final String? failure;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final progress = this.progress;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.text),
                    ),
                    Text(about, style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                    const SizedBox(height: 2),
                    SelectableText(
                      path,
                      key: Key('folder-path-$id'),
                      style: TextStyle(fontSize: 13, color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              button,
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: progress.$2 > 0 ? progress.$1 / progress.$2 : null,
              minHeight: 5,
              borderRadius: BorderRadius.circular(3),
              color: c.text,
              backgroundColor: c.switchTrack,
            ),
            const SizedBox(height: 4),
            Text(
              'Moving... ${(progress.$1 / 1e9).toStringAsFixed(1)} of ${(progress.$2 / 1e9).toStringAsFixed(1)} GB',
              style: TextStyle(fontSize: 12, color: c.textSecondary),
            ),
          ],
          if (failure != null) ...[
            const SizedBox(height: 6),
            Text(
              failure!,
              key: Key('folder-failure-$id'),
              style: TextStyle(fontSize: 12.5, color: c.danger),
            ),
          ],
        ],
      ),
    );
  }
}

/// The folders models are also read from (used where they are, never changed by the app), with Add and Remove.
class _ReadFolders extends StatelessWidget {
  const _ReadFolders({required this.folders, required this.enabled, required this.onAdd, required this.onRemove});

  final List<String> folders;
  final bool enabled;
  final VoidCallback onAdd;
  final void Function(String folder) onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Also read models from',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.text),
          ),
          Text(
            'Models already on this computer are used where they are.',
            style: TextStyle(fontSize: 12.5, color: c.textMuted),
          ),
          for (final dir in folders)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(dir, style: TextStyle(fontSize: 13, color: c.textSecondary)),
                  ),
                  AppButton(label: 'Remove', dense: true, onTap: enabled ? () => onRemove(dir) : null),
                ],
              ),
            ),
          const SizedBox(height: 6),
          AppButton(
            key: const Key('folder-add-read'),
            label: 'Add folder...',
            icon: Icons.add,
            dense: true,
            onTap: enabled ? onAdd : null,
          ),
        ],
      ),
    );
  }
}
