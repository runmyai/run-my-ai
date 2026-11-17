import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/backend.dart';
import '../data/models.dart';
import 'benchmark.dart';
import 'chats.dart';
import 'providers.dart';
import 'serve.dart';

class TuningState {
  const TuningState({this.waiting = const [], this.tuning, this.busy = const {}});

  /// Model files waiting to be tuned, in order: they wait while the engine writes a reply, runs a benchmark or hosts.
  final List<String> waiting;

  /// The model file being tuned now.
  final String? tuning;

  /// Model files whose kept result was measured while other programs kept the PC busy.
  final Set<String> busy;

  TuningState copyWith({List<String>? waiting, String? Function()? tuning, Set<String>? busy}) => TuningState(
    waiting: waiting ?? this.waiting,
    tuning: tuning != null ? tuning() : this.tuning,
    busy: busy ?? this.busy,
  );
}

/// Measures the PC for each model with the autotuner: by itself once a download is checked (unless a result for that
/// model file and autotuner is kept), and again when the user asks. One tune at a time, never while the engine writes a
/// reply, runs a benchmark or hosts (it waits for them to end); the engine unloads the model first if it has it loaded.
/// A message sent meanwhile waits in the engine until the tune ends.
class TuningRunsNotifier extends Notifier<TuningState> {
  var _running = false;

  TuneControl? get _backend {
    final backend = ref.read(backendProvider);
    return backend is TuneControl ? backend as TuneControl : null;
  }

  @override
  TuningState build() {
    final backend = _backend;
    if (backend == null) return const TuningState();
    void tuning() => state = state.copyWith(tuning: () => backend.tuning.value);
    backend.tuning.addListener(tuning);
    ref.onDispose(() => backend.tuning.removeListener(tuning));
    // The engine becoming free lets a waiting tune go.
    ref.listen(chatsProvider.select((s) => s.replyingId), (_, _) => _next());
    ref.listen(benchmarkProvider.select((s) => s.running), (_, _) => _next());
    ref.listen(serveProvider.select((s) => s.phase), (_, _) => _next());
    ref.listen(catalogFilesProvider, (_, files) => state = state.copyWith(busy: _keptBusy(files)));
    return TuningState(tuning: backend.tuning.value, busy: _keptBusy(ref.read(catalogFilesProvider)));
  }

  /// The model files whose kept result says the PC was busy.
  Set<String> _keptBusy(Map<String, CatalogEntry> files) => {
    for (final e in files.values)
      if (_backend?.savedTune(e.file)?['busy'] == true) e.file.id,
  };

  /// A download of [file] has been checked: it is tuned, unless a result for it is kept.
  void afterDownload(ModelFile file) {
    if (_backend?.savedTune(file) == null) tuneAgain(file);
  }

  /// Tunes [file] (again), as soon as the engine is free.
  void tuneAgain(ModelFile file) {
    if (_backend == null || state.waiting.contains(file.id) || state.tuning == file.id) return;
    state = state.copyWith(waiting: [...state.waiting, file.id]);
    unawaited(_next());
  }

  bool get _engineBusy =>
      ref.read(chatsProvider).replyingId != null ||
      ref.read(benchmarkProvider).running ||
      ref.read(serveProvider).phase != ServePhase.idle;

  Future<void> _next() async {
    final backend = _backend;
    if (_running || backend == null || state.waiting.isEmpty || _engineBusy) return;
    final id = state.waiting.first;
    final file = ref.read(catalogFilesProvider)[id]?.file;
    if (file == null) {
      state = state.copyWith(waiting: state.waiting.sublist(1));
      return _next();
    }
    _running = true;
    try {
      final engine = ref.read(backendProvider);
      if (engine is EngineControl && (engine as EngineControl).engineState.value.modelId == id) {
        await (engine as EngineControl).stopEngine();
        // A reply that started meanwhile goes first; the tune follows when it ends.
        if (!ref.mounted || _engineBusy) return;
      }
      state = state.copyWith(waiting: [for (final w in state.waiting) if (w != id) w]);
      final result = await backend.tune(file);
      if (!ref.mounted) return;
      final busy = {...state.busy}..remove(id);
      if (result?['busy'] == true) busy.add(id);
      state = state.copyWith(busy: busy);
    } finally {
      _running = false;
      if (ref.mounted) unawaited(_next());
    }
  }
}

final tuningRunsProvider = NotifierProvider<TuningRunsNotifier, TuningState>(TuningRunsNotifier.new);
