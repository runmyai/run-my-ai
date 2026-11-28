import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/backend.dart';
import '../data/models.dart';
import 'benchmark.dart';
import 'chats.dart';
import 'library.dart';
import 'providers.dart';
import 'serve.dart';

class TuningState {
  const TuningState({this.waiting = const [], this.tuning, this.busy = const {}});

  /// Model files waiting to be tuned, in order: they wait while the engine writes a reply, runs a benchmark or hosts.
  final List<String> waiting;

  /// The model file being tuned now.
  final String? tuning;

  /// Model files just tuned while other programs kept the PC busy: their row says so for [busyNoteTime], then no more.
  final Set<String> busy;

  TuningState copyWith({List<String>? waiting, String? Function()? tuning, Set<String>? busy}) => TuningState(
    waiting: waiting ?? this.waiting,
    tuning: tuning != null ? tuning() : this.tuning,
    busy: busy ?? this.busy,
  );
}

/// How long a model's row says that it was tuned on a busy PC.
const busyNoteTime = Duration(seconds: 30);

/// Measures the PC for each model with the autotuner: by itself once a download is checked (unless a result for that
/// model file and autotuner is kept), and again when the user asks. One tune at a time, never while the engine writes a
/// reply, runs a benchmark or hosts (it waits for them to end); the engine unloads every model it has loaded first and
/// the downloads stand still meanwhile, so the app itself keeps the PC quiet while it measures. Other programs may
/// not: the model is tuned all the same, and its row says so for a short while.
/// A message sent meanwhile waits in the engine until the tune ends.
class TuningRunsNotifier extends Notifier<TuningState> {
  var _running = false;
  final _busyNotes = <String, Timer>{};

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
    ref.onDispose(() {
      for (final t in _busyNotes.values) {
        t.cancel();
      }
    });
    return TuningState(tuning: backend.tuning.value);
  }

  /// The row of [id] says "tuned while the PC was busy" from now for [busyNoteTime], or no more ([on] false).
  void _busyNote(String id, bool on) {
    _busyNotes.remove(id)?.cancel();
    if (on) {
      _busyNotes[id] = Timer(busyNoteTime, () {
        _busyNotes.remove(id);
        if (ref.mounted) state = state.copyWith(busy: {...state.busy}..remove(id));
      });
    }
    state = state.copyWith(busy: on ? {...state.busy, id} : ({...state.busy}..remove(id)));
  }

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
      ref.read(serveProvider).busy;

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
      if (engine is EngineControl && (engine as EngineControl).engineState.value.phase != EnginePhase.stopped) {
        await (engine as EngineControl).stopEngine();
        // A reply that started meanwhile goes first; the tune follows when it ends.
        if (!ref.mounted || _engineBusy) return;
      }
      state = state.copyWith(waiting: [for (final w in state.waiting) if (w != id) w]);
      // The app's own downloads write to the model's drive: they stand still while it is measured.
      final library = ref.read(libraryProvider.notifier);
      await library.holdDownloads();
      final Map<String, dynamic>? result;
      try {
        result = await backend.tune(file);
      } finally {
        if (ref.mounted) library.releaseDownloads();
      }
      if (!ref.mounted) return;
      _busyNote(id, result?['busy'] == true);
    } finally {
      _running = false;
      if (ref.mounted) unawaited(_next());
    }
  }
}

final tuningRunsProvider = NotifierProvider<TuningRunsNotifier, TuningState>(TuningRunsNotifier.new);
