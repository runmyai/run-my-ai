import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/backend.dart';
import '../data/models.dart';
import '../engine/engine_process.dart';
import 'benchmark.dart';
import 'chats.dart';
import 'profiles.dart';
import 'providers.dart';

const defaultServePort = 8080;

/// The model name other programs use for [model]: its name as a plain word (lower case, dashes between words).
String serveAlias(CatalogModel model) {
  final plain = model.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9.]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  return plain.isEmpty ? 'model' : plain;
}

/// Whether [port] can be listened on.
bool validPort(int? port) => port != null && port >= 1 && port <= 65535;

enum ServePhase { idle, starting, hosting }

/// What is being hosted, as other programs see it.
typedef Hosted = ({String modelId, String alias, int port, String? apiKey, int contextLength});

class ServeState {
  const ServeState({
    this.port = defaultServePort,
    this.apiKey = '',
    this.phase = ServePhase.idle,
    this.hosted,
    this.error,
  });

  /// The port and the key the user typed (remembered); an empty key means none.
  final int port;
  final String apiKey;
  final ServePhase phase;

  /// What is hosted, while [phase] is hosting.
  final Hosted? hosted;

  /// Why the last Host did not work, or why hosting ended.
  final String? error;

  /// Another program's server: the app's chats are paused.
  bool get hosting => phase == ServePhase.hosting;

  ServeState copyWith({
    int? port,
    String? apiKey,
    ServePhase? phase,
    Hosted? Function()? hosted,
    String? Function()? error,
  }) => ServeState(
    port: port ?? this.port,
    apiKey: apiKey ?? this.apiKey,
    phase: phase ?? this.phase,
    hosted: hosted != null ? hosted() : this.hosted,
    error: error != null ? error() : this.error,
  );
}

/// Hosting a downloaded model for other programs on this computer, and the port and key remembered for it.
class ServeNotifier extends Notifier<ServeState> {
  @override
  ServeState build() {
    final saved = ref.read(storageProvider).readServeSetup();
    final port = saved?['port'];
    return ServeState(
      port: port is int && validPort(port) ? port : defaultServePort,
      apiKey: saved?['apiKey'] is String ? saved!['apiKey']! as String : '',
    );
  }

  void setPort(int port) {
    if (!validPort(port)) return;
    state = state.copyWith(port: port);
    _save();
  }

  void setApiKey(String key) {
    state = state.copyWith(apiKey: key.trim());
    _save();
  }

  void _save() => ref.read(storageProvider).writeServeSetup({'port': state.port, 'apiKey': state.apiKey});

  /// Stops the engine that is running, loads [entry]'s model with [contextLength] and starts answering other programs.
  Future<void> host(CatalogEntry entry, int contextLength) async {
    final backend = ref.read(backendProvider);
    if (state.phase != ServePhase.idle || backend is! ServeControl) return;
    if (ref.read(chatsProvider).replyingId != null || ref.read(benchmarkProvider).running) {
      state = state.copyWith(error: () => 'A reply or a benchmark is running. Wait for it or stop it first.');
      return;
    }
    final run = ref.read(profilesProvider.notifier).runFor(entry.file, contextLength);
    final hosted = (
      modelId: entry.file.id,
      alias: serveAlias(entry.model),
      port: state.port,
      apiKey: state.apiKey.isEmpty ? null : state.apiKey,
      contextLength: run.contextLength,
    );
    state = state.copyWith(phase: ServePhase.starting, error: () => null);
    try {
      await (backend as ServeControl).startServing(
        entry.file,
        run,
        port: hosted.port,
        alias: hosted.alias,
        apiKey: hosted.apiKey,
        onEnded: _ended,
      );
      if (state.phase == ServePhase.starting) state = state.copyWith(phase: ServePhase.hosting, hosted: () => hosted);
    } on EngineStopped {
      // Stopped while it loaded: nothing went wrong.
    } on EngineFailure catch (e) {
      if (state.phase == ServePhase.starting) state = state.copyWith(phase: ServePhase.idle, error: () => _words(e));
    }
  }

  Future<void> stop() async {
    final backend = ref.read(backendProvider);
    if (state.phase == ServePhase.idle || backend is! ServeControl) return;
    state = state.copyWith(phase: ServePhase.idle, hosted: () => null, error: () => null);
    await (backend as ServeControl).stopServing();
  }

  void _ended(EngineFailure ended) {
    if (state.phase != ServePhase.hosting) return;
    state = state.copyWith(
      phase: ServePhase.idle,
      hosted: () => null,
      error: () => 'Hosting stopped. ${_words(ended)}',
    );
  }

  /// A failure in words for the panel: what happened, then the last line the engine wrote.
  static String _words(EngineFailure e) {
    final last = e.log.map((l) => l.trim()).where((l) => l.isNotEmpty).lastOrNull;
    return last == null ? e.message : '${e.message} Last line: $last';
  }
}

final serveProvider = NotifierProvider<ServeNotifier, ServeState>(ServeNotifier.new);
