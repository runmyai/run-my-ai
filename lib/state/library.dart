import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/storage.dart';
import '../backend/backend.dart';
import 'chats.dart';
import 'profiles.dart';
import 'providers.dart';

class LibraryState {
  const LibraryState({
    this.downloaded = const {},
    this.progress = const {},
    this.picked,
    this.contextLength = defaultContextLength,
  });

  /// Ids of the downloaded model files.
  final Set<String> downloaded;

  /// Downloads in progress: file id -> 0..1.
  final Map<String, double> progress;

  /// The model file last picked: the one a new chat starts with.
  final String? picked;

  /// The context length last picked: the one a new chat starts with (as far as its model can run it).
  final int contextLength;
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
    return LibraryState(
      downloaded: saved.downloaded,
      picked: saved.picked,
      contextLength: saved.contextLength ?? defaultContextLength,
    );
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
      contextLength: state.contextLength,
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
        contextLength: state.contextLength,
      );

  void pickContext(int contextLength) =>
      _update(downloaded: state.downloaded, progress: state.progress, picked: state.picked, contextLength: contextLength);

  void _update({
    required Set<String> downloaded,
    required Map<String, double> progress,
    required String? picked,
    int? contextLength,
  }) {
    final length = contextLength ?? state.contextLength;
    state = LibraryState(downloaded: downloaded, progress: progress, picked: picked, contextLength: length);
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
