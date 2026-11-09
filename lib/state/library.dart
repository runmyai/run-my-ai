import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/storage.dart';
import 'providers.dart';

class LibraryState {
  const LibraryState({this.downloaded = const {}, this.progress = const {}, this.picked});

  /// Ids of the downloaded model files.
  final Set<String> downloaded;

  /// Downloads in progress: file id -> 0..1.
  final Map<String, double> progress;

  /// The model file the chat uses.
  final String? picked;
}

/// Downloads, deletes and the picked model. Saved to library.json on every change.
class LibraryNotifier extends Notifier<LibraryState> {
  final _downloads = <String, StreamSubscription<double>>{};

  @override
  LibraryState build() {
    ref.onDispose(() {
      for (final d in _downloads.values) {
        d.cancel();
      }
    });
    final saved = ref.read(storageProvider).readLibrary();
    return LibraryState(downloaded: saved.downloaded, picked: saved.picked);
  }

  void download(ModelFile file) {
    if (state.downloaded.contains(file.id) || _downloads.containsKey(file.id)) return;
    _setProgress(file.id, 0);
    _downloads[file.id] = ref.read(backendProvider).download(file).listen(
          (p) => _setProgress(file.id, p),
          onError: (Object _) => cancel(file.id),
          onDone: () {
            _downloads.remove(file.id);
            _update(
              downloaded: {...state.downloaded, file.id},
              progress: {...state.progress}..remove(file.id),
              // The first downloaded model is picked, so the chat can start right away.
              picked: state.picked ?? file.id,
            );
          },
        );
  }

  void cancel(String fileId) {
    _downloads.remove(fileId)?.cancel();
    state = LibraryState(
      downloaded: state.downloaded,
      progress: {...state.progress}..remove(fileId),
      picked: state.picked,
    );
  }

  Future<void> delete(ModelFile file) async {
    await ref.read(backendProvider).deleteDownload(file);
    final downloaded = {...state.downloaded}..remove(file.id);
    final picked = state.picked == file.id ? downloaded.firstOrNull : state.picked;
    _update(downloaded: downloaded, progress: state.progress, picked: picked);
  }

  void pick(String fileId) {
    if (!state.downloaded.contains(fileId)) return;
    _update(downloaded: state.downloaded, progress: state.progress, picked: fileId);
  }

  void _setProgress(String fileId, double p) => state = LibraryState(
        downloaded: state.downloaded,
        progress: {...state.progress, fileId: p},
        picked: state.picked,
      );

  void _update({required Set<String> downloaded, required Map<String, double> progress, required String? picked}) {
    state = LibraryState(downloaded: downloaded, progress: progress, picked: picked);
    ref.read(storageProvider).writeLibrary(LibraryData(downloaded: downloaded, picked: picked));
  }
}

final libraryProvider = NotifierProvider<LibraryNotifier, LibraryState>(LibraryNotifier.new);

/// The picked model file, if it is downloaded and in the catalog.
final pickedModelProvider = Provider<CatalogEntry?>((ref) {
  final picked = ref.watch(libraryProvider.select((s) => s.picked));
  return picked == null ? null : ref.watch(catalogFilesProvider)[picked];
});
