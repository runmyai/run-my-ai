import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

/// Whether [key] can be the key other programs send: visible ASCII signs, no spaces, and no comma or quote (the engine
/// reads a comma as the start of a second key).
bool validApiKey(String key) => RegExp(r'^[!-~]+$').hasMatch(key) && !key.contains(',') && !key.contains('"');

/// A strong random key: 32 letters, digits, '-' and '_' (192 bits).
String generateApiKey([Random? random]) {
  const signs = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final r = random ?? Random.secure();
  return String.fromCharCodes([for (var i = 0; i < 32; i++) signs.codeUnitAt(r.nextInt(signs.length))]);
}

enum ServePhase { idle, starting, hosting }

/// What is being hosted, as other programs see it.
typedef Hosted = ({String modelId, String alias, int port, String apiKey, int contextLength});

class ServeState {
  const ServeState({
    this.port = defaultServePort,
    this.apiKey = '',
    this.phase = ServePhase.idle,
    this.hosted,
    this.error,
    this.open = false,
  });

  /// The port and the key the user typed or generated (remembered); hosting needs a valid key.
  final int port;
  final String apiKey;
  final ServePhase phase;

  /// What is loaded for hosting or hosted, while [phase] is not idle.
  final Hosted? hosted;

  /// Why the last Host did not work, or why hosting ended.
  final String? error;

  /// The user opened the Serve page (it also shows whenever a model is loading or hosted).
  final bool open;

  /// Another program's server: the app's chats are paused.
  bool get hosting => phase == ServePhase.hosting;

  /// A model is loading for hosting or hosted: it owns the engine, so nothing else may start or use it.
  bool get busy => phase != ServePhase.idle;

  /// The Serve page takes the window.
  bool get pageShown => open || busy;

  ServeState copyWith({
    int? port,
    String? apiKey,
    ServePhase? phase,
    Hosted? Function()? hosted,
    String? Function()? error,
    bool? open,
  }) => ServeState(
    port: port ?? this.port,
    apiKey: apiKey ?? this.apiKey,
    phase: phase ?? this.phase,
    hosted: hosted != null ? hosted() : this.hosted,
    error: error != null ? error() : this.error,
    open: open ?? this.open,
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

  /// Opens the Serve page (an old message from the last time is dropped).
  void openPage() => state = state.copyWith(open: true, error: state.busy ? null : () => null);

  /// Back to the app; not while a model is loading or hosted.
  void closePage() {
    if (state.busy) return;
    state = state.copyWith(open: false, error: () => null);
  }

  void _save() => ref.read(storageProvider).writeServeSetup({'port': state.port, 'apiKey': state.apiKey});

  /// Stops the engine that is running, loads [entry]'s model with [contextLength] and starts answering other programs.
  Future<void> host(CatalogEntry entry, int contextLength) async {
    final backend = ref.read(backendProvider);
    if (state.phase != ServePhase.idle || backend is! ServeControl) return;
    if (!validApiKey(state.apiKey)) {
      state = state.copyWith(error: () => 'Set an API key first: other apps use it to connect.');
      return;
    }
    if (ref.read(chatsProvider).replyingId != null || ref.read(benchmarkProvider).running) {
      state = state.copyWith(error: () => 'A reply or a benchmark is running. Wait for it or stop it first.');
      return;
    }
    final run = ref.read(profilesProvider.notifier).runFor(entry.file, contextLength);
    final hosted = (
      modelId: entry.file.id,
      alias: serveAlias(entry.model),
      port: state.port,
      apiKey: state.apiKey,
      contextLength: run.contextLength,
    );
    state = state.copyWith(phase: ServePhase.starting, hosted: () => hosted, error: () => null);
    try {
      await (backend as ServeControl).startServing(
        entry.file,
        run,
        port: hosted.port,
        alias: hosted.alias,
        apiKey: hosted.apiKey,
        onEnded: _ended,
      );
      if (state.phase == ServePhase.starting) state = state.copyWith(phase: ServePhase.hosting);
    } on EngineStopped {
      // Stop hosting while it loaded is not a failure (the phase is idle already); anything else that stopped the
      // engine is said.
      if (state.phase == ServePhase.starting) {
        state = state.copyWith(
          phase: ServePhase.idle,
          hosted: () => null,
          error: () => 'The model stopped loading: something else stopped the engine. Host it again.',
        );
      }
    } on EngineFailure catch (e) {
      if (state.phase == ServePhase.starting) {
        state = state.copyWith(phase: ServePhase.idle, hosted: () => null, error: () => _words(e));
      }
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

  /// A failure in words for the Serve page: what happened, then the last line the engine wrote.
  static String _words(EngineFailure e) {
    final last = e.log.map((l) => l.trim()).where((l) => l.isNotEmpty).lastOrNull;
    return last == null ? e.message : '${e.message} Last line: $last';
  }
}

final serveProvider = NotifierProvider<ServeNotifier, ServeState>(ServeNotifier.new);

/// What the hosted model is doing now.
enum HostActivity { idle, reading, writing }

/// One slot of the engine, as GET /slots tells it: whether it is answering, the request it answers (or answered
/// last), the prompt tokens read so far and the tokens written so far for that request.
typedef SlotReading = ({int id, bool processing, int? task, int promptRead, int written});

/// GET /slots' answer as [SlotReading]s; null when it is not one.
List<SlotReading>? parseSlots(String body) {
  try {
    final json = jsonDecode(body);
    if (json is! List) return null;
    return [
      for (final slot in json.whereType<Map<String, dynamic>>())
        (
          id: (slot['id'] as num?)?.toInt() ?? 0,
          processing: slot['is_processing'] == true,
          task: (slot['id_task'] as num?)?.toInt(),
          promptRead: (slot['n_prompt_tokens_processed'] as num?)?.toInt() ?? 0,
          written: switch (slot['next_token']) {
            [final Map<String, dynamic> next, ...] => (next['n_decoded'] as num?)?.toInt() ?? 0,
            _ => 0,
          },
        ),
    ];
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}

/// GET /metrics' Prometheus text as name -> value, without the `llamacpp:` prefix (labelled lines are left out).
Map<String, double> parseMetrics(String body) => {
  for (final line in const LineSplitter().convert(body))
    if (RegExp(r'^llamacpp:([A-Za-z_]\w*) (\S+)$').firstMatch(line.trim()) case final m?)
      m[1]!: ?double.tryParse(m[2]!),
};

/// The hosting screen's numbers: what the model does now, its speed, and the totals since hosting started.
class HostStats {
  const HostStats({
    this.activity = HostActivity.idle,
    this.speed,
    this.requests = 0,
    this.generated = 0,
    this.promptRead = 0,
    this.slots = const {},
    this.at,
  });

  final HostActivity activity;

  /// Tokens per second now: the writing speed while writing, the prompt speed while reading; null when not known.
  final double? speed;

  /// Since hosting started: requests answered or being answered, tokens written, prompt tokens read (cached ones
  /// left out).
  final int requests;
  final int generated;
  final int promptRead;

  /// Each slot as last read, and when: the next reading's speed and new requests are counted from them.
  final Map<int, SlotReading> slots;
  final DateTime? at;

  /// The stats after reading [slots] (null: the engine did not answer in time) and [metrics] (null: same) at [now].
  HostStats next(List<SlotReading>? slots, Map<String, double>? metrics, DateTime now) {
    // The engine answers between two steps of its work; a prompt read in one long step keeps it from answering
    // until the step ends, so no answer while it was idle or reading means it is reading.
    if (slots == null) {
      return HostStats(
        activity: activity == HostActivity.writing ? activity : HostActivity.reading,
        speed: speed,
        requests: requests,
        generated: generated,
        promptRead: promptRead,
        slots: this.slots,
        at: at,
      );
    }
    final seconds = at == null ? 0.0 : now.difference(at!).inMicroseconds / 1e6;
    var newRequests = 0, read = 0, written = 0, liveWritten = 0;
    var doingNow = HostActivity.idle;
    for (final slot in slots) {
      final before = this.slots[slot.id];
      final same = before != null && before.task == slot.task;
      // shortcut: two requests that both start and end between two readings count as one; fine at one reading a second.
      if (slot.task != null && !same) newRequests++;
      if (!slot.processing) continue;
      liveWritten += slot.written;
      read += slot.promptRead - (same ? before.promptRead : 0);
      written += slot.written - (same ? before.written : 0);
      final doing = slot.written > 0 ? HostActivity.writing : HostActivity.reading;
      if (doing.index > doingNow.index) doingNow = doing;
    }
    final done = doingNow == HostActivity.writing ? written : read;
    final double? speedNow = doingNow == HostActivity.idle
        ? null
        : seconds > 0 && done > 0
        ? done / seconds
        // Nothing new since the last reading (one long step): the last speed of the same kind stays.
        : (doingNow == activity ? speed : null);
    // The engine adds a reply's tokens to its total when the reply ends; until then they are counted from the slot.
    final generatedNow = metrics == null ? generated : (metrics['tokens_predicted_total'] ?? 0).round() + liveWritten;
    final promptNow = metrics == null ? promptRead : (metrics['prompt_tokens_total'] ?? 0).round();
    return HostStats(
      activity: doingNow,
      speed: speedNow,
      requests: requests + newRequests,
      generated: max(generated, generatedNow),
      promptRead: max(promptRead, promptNow),
      slots: {for (final slot in slots) slot.id: slot},
      at: now,
    );
  }
}

/// Reads one page of the hosting engine with its key; the body, or null when it did not answer (in time) or refused.
typedef HostFetch = Future<String?> Function(Uri uri, String apiKey);

final hostFetchProvider = Provider<HostFetch>((ref) => _fetch);

Future<String?> _fetch(Uri uri, String apiKey) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    final response = await request.close().timeout(const Duration(seconds: 2));
    final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 2));
    return response.statusCode == 200 ? body : null;
  } on Exception {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// The hosting screen's numbers, read from the engine about once a second while a model is hosted (GET /slots and
/// GET /metrics; every page but /health needs the key).
class HostStatsNotifier extends Notifier<HostStats> {
  @override
  HostStats build() {
    // Read only once the model is loaded (the engine does not answer while it loads).
    final hosted = ref.watch(serveProvider.select((s) => s.hosting ? s.hosted : null));
    if (hosted == null) return const HostStats();
    final fetch = ref.read(hostFetchProvider);
    Uri page(String path) => Uri(scheme: 'http', host: '127.0.0.1', port: hosted.port, path: path);
    var live = true, busy = false;
    Future<void> read() async {
      if (busy) return;
      busy = true;
      try {
        // Metrics first: a reply that ends between the two readings is then counted late, never twice.
        final metrics = await fetch(page('/metrics'), hosted.apiKey);
        final slots = await fetch(page('/slots'), hosted.apiKey);
        if (live) {
          state = state.next(
            slots == null ? null : parseSlots(slots),
            metrics == null ? null : parseMetrics(metrics),
            DateTime.now(),
          );
        }
      } finally {
        busy = false;
      }
    }

    final timer = Timer.periodic(const Duration(seconds: 1), (_) => read());
    ref.onDispose(() {
      live = false;
      timer.cancel();
    });
    unawaited(read());
    return const HostStats();
  }
}

final hostStatsProvider = NotifierProvider<HostStatsNotifier, HostStats>(HostStatsNotifier.new);
