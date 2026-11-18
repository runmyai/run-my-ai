import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/storage.dart';
import '../backend/backend.dart';
import '../system/chime.dart';
import '../system/downloads.dart';
import '../system/folders.dart';
import 'chats.dart';
import 'download_events.dart';
import 'profiles.dart';
import 'providers.dart';
import 'tuning_runs.dart';
import 'updates.dart';

/// Where a model's download is.
enum DownloadPhase { queued, downloading, paused, checking, failed }

/// A model's download that has not ended: its phase, [done] of [total] bytes, its speed, and why it failed.
class DownloadStatus {
  const DownloadStatus(
    this.phase, {
    this.done = 0,
    this.total = 0,
    this.bytesPerSecond,
    this.message,
    this.broken = false,
  });

  final DownloadPhase phase;
  final int done;
  final int total;
  final double? bytesPerSecond;

  /// Why it failed, for the user.
  final String? message;

  /// A file did not match its checksum (and was deleted): it is downloaded again.
  final bool broken;

  double get fraction => total > 0 ? (done / total).clamp(0, 1).toDouble() : 0;

  /// How long the rest takes at the speed it goes; null while the speed is not known.
  Duration? get timeLeft {
    final speed = bytesPerSecond;
    if (speed == null || speed <= 0 || total <= done) return null;
    return Duration(seconds: ((total - done) / speed).ceil());
  }

  DownloadStatus as(DownloadPhase phase, {String? message, bool broken = false}) =>
      DownloadStatus(phase, done: done, total: total, message: message, broken: broken);
}

class LibraryState {
  const LibraryState({
    this.downloaded = const {},
    this.downloads = const {},
    this.picked,
    this.contextLength = defaultContextLength,
  });

  /// Ids of the downloaded model files.
  final Set<String> downloaded;

  /// Downloads not ended (waiting, going, paused, failed): file id -> where it is.
  final Map<String, DownloadStatus> downloads;

  /// The model file last picked: the one a new chat starts with.
  final String? picked;

  /// The context length last picked: the one a new chat starts with (as far as its model can run it).
  final int contextLength;
}

/// The downloads server (tests use their own).
final downloadServerProvider = Provider<Uri>((ref) => huggingFace);

/// Downloads, deletes and the picked model. Saved to library.json on every change. Models from Hugging Face are
/// downloaded one at a time, the others waiting in order, into the models folder; one counts as downloaded when all
/// its files are in the models folder or a folder models are read from. A download left unfinished (also when the
/// app was closed) shows as paused and continues where it stopped.
class LibraryNotifier extends Notifier<LibraryState> {
  final _queue = <ModelFile>[];
  ModelFile? _active;
  Future<void>? _activeRun;
  void Function()? _stopActive;

  @override
  LibraryState build() {
    ref.onDispose(() => _stopActive?.call());
    final saved = ref.read(storageProvider).readLibrary();
    ref.listen(foldersProvider, (_, _) => _scan());
    unawaited(ref.read(catalogProvider.future).then((_) => _scan(), onError: (Object _) {}));
    return LibraryState(
      downloaded: saved.downloaded,
      picked: saved.picked,
      contextLength: saved.contextLength ?? defaultContextLength,
    );
  }

  List<ModelFile> get _catalogFiles => [
    for (final m in ref.read(catalogProvider).value ?? const <CatalogModel>[]) ...m.files,
  ];

  /// Which Hugging Face models are on this computer, and the unfinished downloads in the models folder (paused).
  void _scan() {
    if (!ref.mounted) return;
    final folders = ref.read(foldersProvider);
    final files = [
      for (final f in _catalogFiles)
        if (f.repo != null) f,
    ];
    final found = {
      for (final f in files)
        if (folders.folderWith(f.parts) != null) f.id,
    };
    final downloads = {...state.downloads};
    for (final f in files) {
      if (found.contains(f.id) || downloads.containsKey(f.id)) continue;
      final bytes = downloadedBytes(folders.models, f);
      if (bytes != null) downloads[f.id] = DownloadStatus(DownloadPhase.paused, done: bytes, total: f.sizeBytes);
    }
    final ids = {for (final f in files) f.id};
    final downloaded = {...state.downloaded.difference(ids), ...found};
    downloads.removeWhere((id, _) => found.contains(id));
    // A picked model whose files are gone: the first one there instead (as after a delete).
    final picked = ids.contains(state.picked) && !found.contains(state.picked) ? downloaded.firstOrNull : state.picked;
    // Nothing changed: no new state, so nothing watching the library builds again.
    if (setEquals(downloaded, state.downloaded) && mapEquals(downloads, state.downloads) && picked == state.picked) return;
    _update(downloaded: downloaded, downloads: downloads, picked: picked);
  }

  /// Downloads [file], or puts it in line behind the one downloading; also continues a paused one.
  void download(ModelFile file) {
    if (state.downloaded.contains(file.id) || _active?.id == file.id || _queue.any((f) => f.id == file.id)) return;
    _queue.add(file);
    _setStatus(
      file.id,
      (state.downloads[file.id] ?? const DownloadStatus(DownloadPhase.queued)).as(DownloadPhase.queued),
    );
    _next();
  }

  /// Stops the download (what is written stays, to be continued), or takes a waiting one out of the line.
  void pause(String fileId) {
    if (_active?.id == fileId) {
      _stopActive?.call();
    } else {
      _queue.removeWhere((f) => f.id == fileId);
      final status = state.downloads[fileId];
      if (status != null) _setStatus(fileId, status.as(DownloadPhase.paused));
    }
  }

  /// Pauses every download (before the models folder moves).
  Future<void> pauseAll() async {
    for (final f in [..._queue]) {
      pause(f.id);
    }
    final running = _activeRun;
    _stopActive?.call();
    await running;
  }

  /// Stops the download and deletes what it wrote.
  Future<void> cancel(String fileId) async {
    _queue.removeWhere((f) => f.id == fileId);
    if (_active?.id == fileId) {
      final running = _activeRun;
      _stopActive?.call();
      await running;
    }
    final file = _catalogFiles.where((f) => f.id == fileId).firstOrNull;
    if (file != null && file.repo != null) deleteModelFiles(ref.read(foldersProvider).models, file);
    _update(downloaded: state.downloaded, downloads: {...state.downloads}..remove(fileId), picked: state.picked);
  }

  void _next() {
    if (_active != null || _queue.isEmpty) return;
    final file = _active = _queue.removeAt(0);
    _setStatus(
      file.id,
      (state.downloads[file.id] ?? const DownloadStatus(DownloadPhase.downloading)).as(DownloadPhase.downloading),
    );
    _activeRun = _run(file);
  }

  Future<void> _run(ModelFile file) async {
    try {
      final done = file.repo == null ? await _runStandIn(file) : await _runHuggingFace(file);
      if (!ref.mounted) return;
      if (done) {
        _finished(file);
      } else if (state.downloads[file.id] case final status?) {
        _setStatus(file.id, status.as(DownloadPhase.paused));
      }
    } on DownloadFailure catch (e) {
      if (!ref.mounted) return;
      final status = state.downloads[file.id] ?? const DownloadStatus(DownloadPhase.failed);
      _setStatus(file.id, status.as(DownloadPhase.failed, message: e.message, broken: e.broken));
    } on Exception catch (e) {
      if (!ref.mounted) return;
      final status = state.downloads[file.id] ?? const DownloadStatus(DownloadPhase.failed);
      _setStatus(file.id, status.as(DownloadPhase.failed, message: 'The download stopped: $e'));
    } finally {
      _active = null;
      _activeRun = null;
      _stopActive = null;
      if (ref.mounted) _next();
    }
  }

  Future<bool> _runHuggingFace(ModelFile file) {
    final download = ModelDownload(
      file,
      ref.read(foldersProvider).models,
      server: ref.read(downloadServerProvider),
      onProgress: (p) => _setStatus(
        file.id,
        DownloadStatus(
          p.checking ? DownloadPhase.checking : DownloadPhase.downloading,
          done: p.done,
          total: p.total,
          bytesPerSecond: p.bytesPerSecond,
        ),
      ),
      // kept, so looking for model updates does not hash the file again
      onVerified: (path, f) {
        if (f.sha256 != null) ref.read(fileHashesProvider).remember(path, f.sha256!);
      },
    );
    _stopActive = download.stop;
    return download.run();
  }

  /// The stand-in model's pretend download (from the start again after a pause).
  Future<bool> _runStandIn(ModelFile file) {
    final ended = Completer<bool>();
    final sub = ref
        .read(backendProvider)
        .download(file)
        .listen(
          (p) => _setStatus(
            file.id,
            DownloadStatus(DownloadPhase.downloading, done: (p * file.sizeBytes).round(), total: file.sizeBytes),
          ),
          onError: (Object e) => ended.completeError(e is DownloadFailure ? e : DownloadFailure('$e')),
          onDone: () => ended.complete(true),
        );
    _stopActive = () {
      unawaited(sub.cancel());
      if (!ended.isCompleted) ended.complete(false);
    };
    return ended.future;
  }

  void _finished(ModelFile file) {
    _update(
      downloaded: {...state.downloaded, file.id},
      downloads: {...state.downloads}..remove(file.id),
      // The first downloaded model is picked, so the chat can start right away.
      picked: state.picked ?? file.id,
    );
    // The notification sound, when the bell is on (as for a finished reply).
    ref.read(chimeProvider).replyDone();
    unawaited(ref.read(downloadEventsProvider).model(file.id));
    // The PC is measured for it right away, so its first load does not wait for that.
    ref.read(tuningRunsProvider.notifier).afterDownload(file);
  }

  Future<void> delete(ModelFile file) async {
    await ref.read(backendProvider).deleteDownload(file);
    final downloaded = {...state.downloaded}..remove(file.id);
    final picked = state.picked == file.id ? downloaded.firstOrNull : state.picked;
    _update(downloaded: downloaded, downloads: state.downloads, picked: picked);
    // (Still downloaded when it is also in a folder models are read from.)
    if (file.repo != null) _scan();
  }

  void pick(String fileId) {
    if (!state.downloaded.contains(fileId)) return;
    _update(downloaded: state.downloaded, downloads: state.downloads, picked: fileId);
  }

  void _setStatus(String fileId, DownloadStatus status) {
    if (ref.mounted) _setStatusNow(fileId, status);
  }

  void _setStatusNow(String fileId, DownloadStatus status) => state = LibraryState(
    downloaded: state.downloaded,
    downloads: {...state.downloads, fileId: status},
    picked: state.picked,
    contextLength: state.contextLength,
  );

  void pickContext(int contextLength) => _update(
    downloaded: state.downloaded,
    downloads: state.downloads,
    picked: state.picked,
    contextLength: contextLength,
  );

  void _update({
    required Set<String> downloaded,
    required Map<String, DownloadStatus> downloads,
    required String? picked,
    int? contextLength,
  }) {
    final length = contextLength ?? state.contextLength;
    state = LibraryState(downloaded: downloaded, downloads: downloads, picked: picked, contextLength: length);
    ref.read(storageProvider).writeLibrary(LibraryData(downloaded: downloaded, picked: picked, contextLength: length));
  }
}

final libraryProvider = NotifierProvider<LibraryNotifier, LibraryState>(LibraryNotifier.new);

/// The model file last picked, if it is downloaded and in the catalog: the one a new chat starts with.
final pickedModelProvider = Provider<CatalogEntry?>((ref) {
  final library = ref.watch(libraryProvider);
  if (library.picked == null) return null;
  final files = ref.watch(catalogFilesProvider);
  // (A picked model that has left the catalog: the first one the user has.)
  return files[library.picked] ?? [for (final id in library.downloaded) ?files[id]].firstOrNull;
});

/// The model the chat window shows: the open chat's own, else the one last picked.
final shownModelProvider = Provider<CatalogEntry?>((ref) {
  final own = ref.watch(chatsProvider.select((s) => s.byId(s.openId)?.modelId));
  return ref.watch(catalogFilesProvider)[own] ?? ref.watch(pickedModelProvider);
});

/// The context lengths the shown model offers, and the one the chat window shows.
final shownContextProvider = Provider<({List<int> options, int value})?>((ref) {
  final model = ref.watch(shownModelProvider);
  if (model == null) return null;
  ref.watch(profilesProvider);
  final options = ref.read(profilesProvider.notifier).active(model.file).lengths;
  final own = ref.watch(chatsProvider.select((s) => s.byId(s.openId)?.contextLength));
  return (options: options, value: closestContext(options, own ?? ref.watch(libraryProvider.select((s) => s.contextLength))));
});
