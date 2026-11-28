import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/backend.dart';
import '../../backend/engine_backend.dart';
import '../../engine/engine_download.dart';
import '../../state/library.dart';
import '../../state/prefs.dart';
import '../../state/providers.dart';
import '../../system/folders.dart';
import '../../system/relaunch.dart';
import '../../theme.dart';
import '../buttons.dart';
import '../engine_setup.dart';
import 'setting_name.dart';
import 'slow_drive.dart';

/// Settings' folders, in this order: the engine, the chats, the saved chat states (with their disk-space limit in the
/// row) and where models are downloaded, with the folders models are also read from under it. Moving one copies its files to the new place and then removes the old ones (on the
/// same drive they are simply moved); the engine is stopped first, and downloads are paused before the models move.
/// In the engine step of the first start ([firstStart]) it shows the main folder first and the others in the order main,
/// models, chats, saved chat states, engine, and leaves out the folders models are also read from, the disk-space limit
/// and the engine download. In Settings the heading is the drop-down around it, and each folder's
/// description shows as a tooltip on its name; in the first start they are written out.
class FoldersSection extends ConsumerStatefulWidget {
  const FoldersSection({super.key, this.firstStart = false});

  final bool firstStart;

  @override
  ConsumerState<FoldersSection> createState() => _FoldersSectionState();
}

/// What the folders are, under or over the Folders heading.
const foldersAbout = 'Where Run My AI keeps its files. Moving a folder takes its files along.';

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

  /// Moves the folder of row [id] from [from] to a folder the user picks ([target] makes the place from the picked
  /// folder), then [save]s the new place; false when the user picked none (nothing was done).
  Future<bool> _move(
    String id,
    String from,
    Future<void> Function() before,
    void Function(String to) save, {
    String Function(String picked)? target,
    bool holdsModels = false,
  }) async {
    final picked = holdsModels
        ? await pickModelsFolder(context, initialDirectory: from, confirmButtonText: 'Move here')
        : await getDirectoryPath(initialDirectory: from, confirmButtonText: 'Move here');
    if (picked == null || !mounted) return false;
    final to = target?.call(picked) ?? picked;
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
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final folders = ref.watch(foldersProvider);
    final notifier = ref.read(foldersProvider.notifier);
    final own = ref.watch(prefsProvider.select((p) => p.engineFolder));
    final engine = EngineBackend.engineFolder(own, folders);
    final busy = _moving != null;
    final installed = installedEngine(engine);
    final installedLine = installed == null
        ? ''
        : 'TokenWing ${installed.version}, ${engineBuildLabel(installed.build)}. ';
    final download = AppButton(
      key: const Key('engine-download-open'),
      label: 'Download engine...',
      dense: true,
      onTap: busy
          ? null
          : () async {
              await showEngineSetup(context);
              if (mounted) setState(() {});
            },
    );

    Widget row(
      String id,
      String title,
      String about,
      String path, {
      required VoidCallback onMove,
      String label = 'Move...',
      Widget? extra,
    }) => _FolderRow(
      id: id,
      title: title,
      about: about,
      aboutAsTooltip: !widget.firstStart,
      path: path,
      button: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          ?extra,
          AppButton(key: Key('folder-move-$id'), label: label, dense: true, onTap: busy ? null : onMove),
        ],
      ),
      progress: _moving == id ? (_done, _total) : null,
      failure: _failedRow == id ? _failure : null,
    );

    final sep = Platform.pathSeparator;
    // A folder in the main folder moves along with it.
    String rebase(String path, String to) => path == folders.main || path.startsWith('${folders.main}$sep')
        ? '$to${path.substring(folders.main.length)}'
        : path;
    final first = widget.firstStart;

    final mainRow = row(
      'main',
      'Main folder',
      'The folders below are in it, unless moved on their own.',
      folders.main,
      // The open chats are closed first when they move along; the app then starts again on the new folder.
      onMove: () async {
        final chatsMove = rebase(folders.chats, '') != folders.chats;
        final moved = await _move(
          'main',
          folders.main,
          () async {
            await _stopEngine();
            if (chatsMove) await ref.read(chatStoreProvider).close();
          },
          (to) => notifier.set(
            FolderSet(
              main: to,
              models: rebase(folders.models, to),
              chats: rebase(folders.chats, to),
              cache: rebase(folders.cache, to),
              readFrom: [for (final dir in folders.readFrom) rebase(dir, to)],
            ),
          ),
          target: (picked) => picked.split(sep).last == mainFolderName
              ? picked
              : '$picked${picked.endsWith(sep) ? '' : sep}$mainFolderName',
          holdsModels: true,
        );
        if (moved && chatsMove) await relaunchApp();
      },
    );
    final modelsRow = row(
      'models',
      'Models',
      'Downloaded models go here.',
      folders.models,
      onMove: () => _move(
        'models',
        folders.models,
        () async {
          await ref.read(libraryProvider.notifier).pauseAll();
          await _stopEngine();
        },
        (to) => notifier.set(folders.copyWith(models: to, readFrom: [...folders.readFrom]..remove(to))),
        holdsModels: true,
      ),
    );
    final chatsRow = row(
      'chats',
      'Chats',
      'Your chats, one file each.',
      folders.chats,
      // The open chats are saved and closed first; the app then starts again on the new folder (or on the old one if
      // the move failed), so no change is written to the folder the files left.
      onMove: () async {
        final moved = await _move('chats', folders.chats, () async {
          await _stopEngine();
          await ref.read(chatStoreProvider).close();
        }, (to) => notifier.set(folders.copyWith(chats: to)));
        if (moved) await relaunchApp();
      },
    );
    final cacheRow = row(
      'cache',
      'Saved chat states',
      'What lets a chat continue quickly. The engine stops while it moves.',
      folders.cache,
      onMove: () => _move('cache', folders.cache, _stopEngine, (to) => notifier.set(folders.copyWith(cache: to))),
      extra: first ? null : const _StateLimit(),
    );
    // The engine next to the app is part of the app: another folder is chosen, nothing is moved out of it.
    final engineRow = engine == EngineBackend.defaultEngineFolder
        ? row(
            'engine',
            'Engine',
            '${installedLine}The engine Run My AI runs. A change applies the next time it starts.',
            engine,
            label: 'Choose...',
            onMove: () async {
              final dir = await getDirectoryPath(initialDirectory: engine);
              if (dir == null || !mounted) return;
              if (!File('$dir$sep$engineProgram').existsSync()) {
                setState(() {
                  _failedRow = 'engine';
                  _failure = 'There is no engine in this folder ($engineProgram is missing).';
                });
                return;
              }
              setState(() => _failedRow = _failure = null);
              ref.read(prefsProvider.notifier).setEngineFolder(dir);
            },
            extra: first ? null : download,
          )
        : row(
            'engine',
            'Engine',
            '${installedLine}The engine Run My AI runs. It stops while it moves.',
            engine,
            onMove: () => _move('engine', engine, _stopEngine, ref.read(prefsProvider.notifier).setEngineFolder),
            extra: first ? null : download,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: first
          ? [
              Text(foldersAbout, style: TextStyle(fontSize: 13, color: c.textSecondary)),
              mainRow,
              modelsRow,
              chatsRow,
              cacheRow,
              engineRow,
            ]
          : [
              engineRow,
              chatsRow,
              cacheRow,
              modelsRow,
              // The folders models are also read from belong to Models: indented under it.
              Padding(
                padding: const EdgeInsets.only(left: 20),
                child: _ReadFolders(
                  folders: folders.readFrom,
                  enabled: !busy,
                  onAdd: () async {
                    final dir = await pickModelsFolder(context, confirmButtonText: 'Read models here');
                    if (dir == null || dir == folders.models || folders.readFrom.contains(dir)) return;
                    notifier.set(folders.copyWith(readFrom: [...folders.readFrom, dir]));
                  },
                  onRemove: (dir) => notifier.set(folders.copyWith(readFrom: [...folders.readFrom]..remove(dir))),
                ),
              ),
            ],
    );
  }
}

/// The most the saved chat states may take on the disk, as a small field in their folder's row. A change applies the
/// next time the engine starts.
class _StateLimit extends ConsumerStatefulWidget {
  const _StateLimit();

  @override
  ConsumerState<_StateLimit> createState() => _StateLimitState();
}

class _StateLimitState extends ConsumerState<_StateLimit> {
  late final _text = TextEditingController(text: _show(ref.read(prefsProvider).stateLimitGiB));

  static String _show(double gib) => gib == gib.roundToDouble() ? '${gib.round()}' : '$gib';

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = TextStyle(fontSize: 13, color: c.textMuted);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        Text('Up to', style: label),
        SizedBox(
          width: 56,
          child: TextField(
            key: const Key('state-limit'),
            controller: _text,
            onChanged: (text) {
              final gib = double.tryParse(text.trim());
              if (gib != null && gib > 0) ref.read(prefsProvider.notifier).setStateLimit(gib);
            },
            style: TextStyle(fontSize: 13, color: c.text),
            cursorColor: c.text,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: c.inputBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: c.text.withValues(alpha: 0.35)),
              ),
            ),
          ),
        ),
        Text('GB', style: label),
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
    required this.aboutAsTooltip,
    required this.path,
    required this.button,
    this.progress,
    this.failure,
  });

  final String id, title, about, path;
  final bool aboutAsTooltip;
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
                    SettingName(title, size: 14, description: aboutAsTooltip ? about : null),
                    if (!aboutAsTooltip) Text(about, style: TextStyle(fontSize: 12.5, color: c.textMuted)),
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
          const SettingName(
            'Also read models from',
            size: 14,
            description: 'Models already on this computer are used where they are.',
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
