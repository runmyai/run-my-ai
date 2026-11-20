import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/backend.dart';
import '../benchmark/benchmark.dart';
import '../benchmark/disturbance.dart';
import '../benchmark/engine_stats.dart';
import '../benchmark/hardware.dart';
import '../benchmark/memory_layout.dart';
import '../benchmark/prompts.dart';
import '../benchmark/series.dart';
import '../benchmark/share.dart';
import '../data/chat_db.dart' show ChatDb;
import '../data/models.dart';
import '../engine/engine_flags.dart';
import '../engine/engine_process.dart';
import 'about.dart';
import 'chats.dart';
import 'prefs.dart';
import 'profiles.dart';
import 'providers.dart';
import 'serve.dart';

enum BenchmarkPhase { idle, loading, warmingUp, measuring }

/// Whether the engine serves its counters while it runs (`GET /moe-stream/stats`): not known until the first answer.
enum EngineCounters { unknown, available, missing }

class BenchmarkState {
  const BenchmarkState({
    this.phase = BenchmarkPhase.idle,
    this.setup = const BenchmarkSetup(),
    this.warmup = 0,
    this.live,
    this.hardware = const HardwareInfo(),
    this.revision = 0,
    this.replyTokens = 0,
    this.promptProgress,
    this.disturbed = const [],
    this.counters = EngineCounters.unknown,
    this.note,
    this.result,
    this.error,
    this.modelId,
    this.profileId,
    this.history = const [],
    this.turns = const [],
    this.turnFirstTokenMillis,
    this.turnStartSeconds,
  });

  final BenchmarkPhase phase;
  final BenchmarkSetup setup;

  /// Which warm-up message is being answered, from 0.
  final int warmup;

  /// The numbers measured so far in this run, on one time axis; it only grows, and [revision] counts its ticks so a
  /// view knows to paint again. It stays after the run ends (stopped or not) until the next run starts.
  final RunSeries? live;
  final int revision;

  /// The computer, once the run's watching of it has begun.
  final HardwareInfo hardware;

  /// The tokens of the measured reply written so far, and how far the engine is in reading its prompt (tokens read,
  /// tokens in all).
  final int replyTokens;
  final (int, int)? promptProgress;

  /// Why this run is not a fair one, as far as it has shown.
  final List<String> disturbed;
  final EngineCounters counters;

  /// What to say about a run that ended without a result (it was stopped).
  final String? note;

  /// The latest run that finished, shown until the next one starts.
  final BenchmarkResult? result;
  final String? error;

  /// The model and profile of the run going on.
  final String? modelId;
  final String? profileId;

  /// Past runs, the newest first.
  final List<BenchmarkResult> history;

  /// The turns of the running (or last) run that have finished, in order: the warm-up messages and then the
  /// measured one, each with its own real numbers. It grows as the turns end and stays until the next run starts.
  final List<TurnRecord> turns;

  /// The TTFT of the turn going on, once its first token has come; null before that and between turns.
  final int? turnFirstTokenMillis;

  /// When the turn going on was sent, in seconds on [live]'s time axis; null while no turn is going on.
  final double? turnStartSeconds;

  bool get running => phase != BenchmarkPhase.idle;

  BenchmarkState copyWith({
    BenchmarkPhase? phase,
    BenchmarkSetup? setup,
    int? warmup,
    RunSeries? Function()? live,
    HardwareInfo? hardware,
    int? revision,
    int? replyTokens,
    (int, int)? Function()? promptProgress,
    List<String>? disturbed,
    EngineCounters? counters,
    String? Function()? note,
    BenchmarkResult? Function()? result,
    String? Function()? error,
    String? Function()? modelId,
    String? Function()? profileId,
    List<BenchmarkResult>? history,
    List<TurnRecord>? turns,
    int? Function()? turnFirstTokenMillis,
    double? Function()? turnStartSeconds,
  }) => BenchmarkState(
    phase: phase ?? this.phase,
    setup: setup ?? this.setup,
    warmup: warmup ?? this.warmup,
    live: live != null ? live() : this.live,
    hardware: hardware ?? this.hardware,
    revision: revision ?? this.revision,
    replyTokens: replyTokens ?? this.replyTokens,
    promptProgress: promptProgress != null ? promptProgress() : this.promptProgress,
    disturbed: disturbed ?? this.disturbed,
    counters: counters ?? this.counters,
    note: note != null ? note() : this.note,
    result: result != null ? result() : this.result,
    error: error != null ? error() : this.error,
    modelId: modelId != null ? modelId() : this.modelId,
    profileId: profileId != null ? profileId() : this.profileId,
    history: history ?? this.history,
    turns: turns ?? this.turns,
    turnFirstTokenMillis: turnFirstTokenMillis != null ? turnFirstTokenMillis() : this.turnFirstTokenMillis,
    turnStartSeconds: turnStartSeconds != null ? turnStartSeconds() : this.turnStartSeconds,
  );
}

/// The flag that makes the engine time the parts of each token.
const timingFlag = '--moe-stream-timing';

/// The story of a prompt test, by its asset (the tests give their own).
final promptCorpusProvider = FutureProvider.family<PromptCorpus, String>((ref, asset) async {
  return PromptCorpus([await rootBundle.loadString(asset)]);
});

/// The versions of the app and the engine, asked when a run starts (the tests give their own).
final runVersionsProvider = Provider<Future<({String? engine, String? app})> Function()>(
  (ref) => () async => (engine: await ref.read(engineVersionProvider.future), app: appVersion),
);

/// Runs one benchmark at a time: the engine starts fresh, the warm-up messages go first and are not counted, then the
/// measured message, all in one conversation. Every reply stops when the model stops. The machine is read twice a
/// second all along, the engine's counters once a second.
class BenchmarkNotifier extends Notifier<BenchmarkState> {
  StreamSubscription<ReplyEvent>? _reply;
  Completer<String>? _replied;
  var _stopped = false;
  EngineControl? _control;

  @override
  BenchmarkState build() {
    final saved = ref.read(storageProvider).readBenchmarkSetup();
    unawaited(_loadHistory());
    return BenchmarkState(setup: saved == null ? const BenchmarkSetup() : BenchmarkSetup.fromJson(saved));
  }

  Future<void> _loadHistory() async {
    final rows = await ref.read(chatStoreProvider).benchmarks();
    if (!ref.mounted) return;
    final runs = <BenchmarkResult>[];
    for (final (id, data) in rows) {
      try {
        runs.add(BenchmarkResult.fromJson((jsonDecode(data) as Map).cast<String, Object?>(), id: id));
      } on Object {
        // A row this version cannot read stays in the database and out of the list.
      }
    }
    state = state.copyWith(history: runs);
  }

  void setSetup(BenchmarkSetup setup) {
    state = state.copyWith(setup: setup);
    ref.read(storageProvider).writeBenchmarkSetup(setup.toJson());
  }

  /// What would stop the run from starting with the present setup at [contextLength]; null when it can start.
  String? problem({required int contextLength}) {
    final test = state.setup.test;
    return test.fits(contextLength) ? null : '${test.label} needs a longer context length.';
  }

  /// Deletes [run] from the history.
  void delete(BenchmarkResult run) {
    if (run.id != null) ref.read(chatStoreProvider).deleteBenchmark(run.id!);
    state = state.copyWith(
      history: [for (final r in state.history) if (!identical(r, run) && (run.id == null || r.id != run.id)) r],
      result: state.result != null && (identical(state.result, run) || (run.id != null && state.result!.id == run.id))
          ? () => null
          : null,
    );
  }

  /// The measured message of the setup's test, and its length in tokens as the engine counts them (null for the short
  /// one of the reply-speed test).
  Future<({String text, int? tokens})> _prompt(EngineInsight? insight) async {
    final test = state.setup.test;
    final tokens = test.promptTokens;
    if (tokens == null) return (text: replySpeedRequest, tokens: null);
    final corpus = await ref.read(promptCorpusProvider(test.story!).future);
    final fitted = await fitPrompt(corpus, tokens, (text) async => await insight?.countTokens(text) ?? text.length ~/ 4);
    return (text: fitted.text, tokens: fitted.tokens);
  }

  /// A prompt for the record: all of a short one, the start of a long one.
  static String _recorded(String text) =>
      text.length <= 20000 ? text : '${text.substring(0, 2000)}\n[… ${text.length} characters in all]';

  /// Runs the benchmark with [file] at [contextLength], with the model's automatic preset.
  Future<void> start(ModelFile file, String modelName, int contextLength, {ModelThinking? thinking}) async {
    final backend = ref.read(backendProvider);
    if (state.running ||
        backend is! EngineControl ||
        ref.read(chatsProvider).replyingId != null ||
        ref.read(serveProvider).busy) {
      return;
    }
    final control = backend as EngineControl;
    final insight = backend is EngineInsight ? backend as EngineInsight : null;
    _control = control;
    final setup = state.setup;
    final profiles = ref.read(profilesProvider.notifier);
    var run = profiles.runWith(file, autoProfileId, contextLength);
    final profileName = profiles.auto(file).name;

    _stopped = false;
    final series = RunSeries();
    state = state.copyWith(
      phase: BenchmarkPhase.loading,
      warmup: 0,
      live: () => series,
      revision: 0,
      replyTokens: 0,
      promptProgress: () => null,
      disturbed: const [],
      counters: EngineCounters.unknown,
      note: () => null,
      result: () => null,
      error: () => null,
      modelId: () => file.id,
      profileId: () => autoProfileId,
      turns: const [],
      turnStartSeconds: () => null,
    );
    final monitor = ref.read(hardwareMonitorProvider)();
    StreamSubscription<SystemSample>? watching;
    Timer? polling;
    String? chatId;
    try {
      final versions = await ref.read(runVersionsProvider)();
      final fileInfo = await insight?.modelFileInfo(file);

      // The flag that times the parts of a token, only if the engine knows it.
      final added = <String>[];
      if (insight != null &&
          !EngineFlags.parse(run.flags).arguments.any((a) => a == timingFlag) &&
          await insight.acceptsFlag(timingFlag)) {
        run = run.withFlags('${run.flags} $timingFlag 1');
        added.add('$timingFlag 1');
      }
      run = run.forBenchmark();

      // The readings need a moment to arrive, and the CPU's load is the difference between two readings.
      await monitor.start();
      state = state.copyWith(hardware: monitor.info);
      await control.stopEngine();
      await monitor.look();
      final beforeSample = await monitor.look();
      final before = StartState.of(beforeSample);

      final runClock = Stopwatch()..start();
      double now() => runClock.elapsedMicroseconds / 1e6;
      series.beginPhase(PhaseBand.load, 0);

      // What the next tick carries besides the machine's readings.
      var engineValues = const <String, double?>{};
      var engineSeen = Duration.zero;
      double? liveTokens, livePrompt, firstToken;
      var replyTokens = 0;
      var tickCount = 0;
      watching = monitor.samples.listen((s) {
        if (!ref.mounted) return;
        final stale = runClock.elapsed - engineSeen > const Duration(seconds: 4);
        series.add(now(), {
          ...s.values,
          if (!stale) ...engineValues,
          'speed.tokens': liveTokens,
          'speed.prompt': livePrompt,
          'speed.ttft': firstToken,
        });
        state = state.copyWith(
          revision: ++tickCount,
          replyTokens: replyTokens,
          disturbed: disturbances(series, before: before),
        );
      });

      // The engine's counters, once a second, from when it answers.
      final tracker = EngineStatsTracker();
      EngineSnapshot? atReplyStart;
      var missing = 0;
      var asking = false;
      Future<EngineSnapshot?> poll() async {
        final json = await insight?.liveStats();
        final snapshot = json == null ? null : EngineSnapshot.parse(json);
        if (!ref.mounted) return snapshot;
        if (snapshot == null) {
          if (++missing >= 3 && state.counters != EngineCounters.available) {
            polling?.cancel();
            state = state.copyWith(counters: EngineCounters.missing);
          }
          return null;
        }
        missing = 0;
        engineValues = tracker.add(snapshot);
        engineSeen = runClock.elapsed;
        if (state.counters != EngineCounters.available) state = state.copyWith(counters: EngineCounters.available);
        return snapshot;
      }

      final loadClock = Stopwatch()..start();
      await control.startEngine(file, run);
      final loadMillis = loadClock.elapsedMilliseconds;
      if (_stopped) return;
      if (insight != null) {
        polling = Timer.periodic(const Duration(seconds: 1), (_) async {
          if (asking) return;
          asking = true;
          try {
            await poll();
          } finally {
            asking = false;
          }
        });
      }

      chatId = 'benchmark-${DateTime.now().microsecondsSinceEpoch}';
      final thinkingOn = switch (thinking) {
        null || ModelThinking.none => null,
        ModelThinking.always => true,
        ModelThinking.optional => ref.read(prefsProvider).thinking,
      };
      final history = <ChatMessage>[];
      Future<String> say(String text, {required bool warmup, void Function(ReplyEvent)? onEvent}) {
        history.add(ChatMessage(Role.user, text));
        final replied = Completer<String>();
        _replied = replied;
        final written = StringBuffer();
        // This turn's own numbers, kept for every turn — warm-ups included.
        final turnClock = Stopwatch()..start();
        final startSeconds = now();
        state = state.copyWith(turnFirstTokenMillis: () => null, turnStartSeconds: () => startSeconds);
        final gaps = <double>[];
        int? first;
        var last = 0;
        var turnReplyTokens = 0;
        var turnTimings = const <String, Object?>{};
        var turnTokenMillis = const <double>[];
        String? turnStop;
        _reply = backend
            .reply(
              chatId: chatId!,
              model: file,
              messages: [...history],
              run: run,
              thinking: thinkingOn ?? false,
              maxTokens: setup.replyLength,
            )
            .listen(
              (event) {
                switch (event) {
                  case ReplyText():
                    written.write(event.text);
                  case ReplySpeed(:final live?):
                    liveTokens = live;
                  case ReplyProgress(:final processed, :final cached, :final millis):
                    if (millis > 0 && processed > cached) livePrompt = (processed - cached) * 1000 / millis;
                    state = state.copyWith(promptProgress: () => (processed, event.total));
                  default:
                    break;
                }
                switch (event) {
                  case ReplyText() || ReplyThinking():
                    final at = turnClock.elapsedMicroseconds;
                    if (first == null) {
                      first = at;
                      state = state.copyWith(turnFirstTokenMillis: () => at ~/ 1000);
                    } else {
                      gaps.add((at - last) / 1000);
                    }
                    last = at;
                    turnReplyTokens++;
                  case ReplyDone(timings: final done, wordMillis: final wordMillis, finishReason: final reason):
                    turnTimings = done;
                    turnTokenMillis = wordMillis;
                    turnStop = reason;
                  default:
                    break;
                }
                onEvent?.call(event);
              },
              onError: (Object e) {
                if (!replied.isCompleted) replied.completeError(e);
              },
              onDone: () {
                if (!replied.isCompleted) replied.complete(written.toString());
              },
            );
        return replied.future.then((reply) {
          final endSeconds = now();
          history.add(ChatMessage(Role.assistant, reply));
          liveTokens = null;
          livePrompt = null;
          // The turn's record: the engine's own figures for it first, the app's times as the fallback.
          if (!_stopped) {
            double n(String key) => (turnTimings[key] as num?)?.toDouble() ?? 0;
            final promptMillis = n('prompt_ms');
            final record = TurnRecord(
              warmup: warmup,
              firstTokenMillis: turnTokenMillis.isNotEmpty && promptMillis > 0
                  ? (promptMillis + turnTokenMillis.first).round()
                  : (first ?? 0) ~/ 1000,
              promptTokens: n('prompt_n').round(),
              promptMillis: promptMillis,
              replyTokens: n('predicted_n').round() > 0 ? n('predicted_n').round() : turnReplyTokens,
              replyMillis: n('predicted_ms'),
              totalMillis: turnClock.elapsedMilliseconds,
              stopReason: turnStop,
              tokenGaps: gaps,
              tokenMillis: turnTokenMillis,
              // The counters of this turn's own final response (not the live endpoint's).
              engineStats: (turnTimings['moe_stream'] as Map?)?.cast<String, Object?>() ?? const {},
              startSeconds: startSeconds,
              endSeconds: endSeconds,
            );
            state = state.copyWith(turns: [...state.turns, record], turnStartSeconds: () => null);
          }
          return reply;
        });
      }

      if (setup.warmups.isNotEmpty) series.beginPhase(PhaseBand.warmUp, now());
      for (var i = 0; i < setup.warmups.length && !_stopped; i++) {
        state = state.copyWith(phase: BenchmarkPhase.warmingUp, warmup: i, promptProgress: () => null);
        await say(setup.warmups[i], warmup: true);
      }
      if (_stopped) return;

      state = state.copyWith(phase: BenchmarkPhase.measuring, promptProgress: () => null);
      final prompt = await _prompt(insight);
      if (_stopped) return;
      final clock = Stopwatch()..start();
      series.beginPhase(PhaseBand.prompt, now());
      final reply = await say(
        prompt.text,
        warmup: false,
        onEvent: (event) {
          switch (event) {
            case ReplyText() || ReplyThinking():
              // (The prompt's speed keeps its last value through the reply, the way the TTFT does, so the graphs and
              // the number keep showing it.)
              if (firstToken == null) {
                firstToken = clock.elapsedMicroseconds / 1e6;
                series.beginPhase(PhaseBand.reply, now());
                if (insight != null) unawaited(poll().then((s) => atReplyStart ??= s));
              }
              replyTokens++;
            default:
              break;
          }
        },
      );
      if (_stopped) return;
      final turn = state.turns.isEmpty ? null : state.turns.last;
      series.endPhases(now());
      final measured = clock.elapsedMilliseconds;
      polling?.cancel();
      polling = null;
      final end = insight == null ? null : await poll();
      await watching.cancel();
      watching = null;

      final moeStream = turn?.engineStats ?? const {};
      // (The request's own figures first; the counters' difference for an engine that only gives those.)
      var parts = timeParts(moeStream);
      if (parts.isEmpty && atReplyStart != null && end != null) parts = timePartsBetween(atReplyStart!, end);
      var layers = layersOf(moeStream);
      if (layers.isEmpty && atReplyStart != null && end != null) layers = layersBetween(atReplyStart!, end);
      final result = BenchmarkResult(
        at: DateTime.now(),
        modelName: modelName,
        contextLength: run.contextLength,
        profileName: profileName,
        flags: run.flags,
        memoryCapGiB: run.memoryCapGiB,
        vramHeadroom: {
          if (backend is TuneControl)
            for (final c in (backend as TuneControl).cards) c.key: run.vramHeadroom.of(c.key),
        },
        promptLabel: setup.test.label,
        replyLength: setup.replyLength,
        warmups: setup.warmups,
        loadMillis: loadMillis,
        firstTokenMillis: turn?.firstTokenMillis ?? 0,
        promptTokens: turn?.promptTokens ?? 0,
        promptMillis: turn?.promptMillis ?? 0,
        replyTokens: turn?.replyTokens ?? 0,
        replyMillis: turn?.replyMillis ?? 0,
        tokenGaps: turn?.tokenGaps ?? const [],
        engineStats: moeStream,
        log: control.logLines.length > 200 ? control.logLines.sublist(control.logLines.length - 200) : control.logLines,
        disturbed: disturbances(series, before: before),
        promptText: _recorded(prompt.text),
        thinking: thinkingOn,
        replyText: reply.length > 4000 ? reply.substring(0, 4000) : reply,
        stopReason: turn?.stopReason,
        tokenMillis: turn?.tokenMillis ?? const [],
        totalMillis: measured,
        timeParts: parts,
        layers: layers,
        turns: state.turns,
        series: series.shrunk(200),
        memory: MemoryLayout.read(
          control.logLines,
          run.flags,
          memoryCapGiB: run.memoryCapGiB,
          freeRamGiB: beforeSample['ram.available'],
          layout: end?.layout ?? const {},
        ),
        environment: RunEnvironment(
          engineVersion: versions.engine,
          appVersion: versions.app,
          modelFileBytes: fileInfo?.bytes,
          modelFileModified: fileInfo?.modified,
          hardware: monitor.info,
          onBattery: beforeSample.onBattery,
          addedFlags: added,
          profileId: autoProfileId,
        ),
      );
      final id = await ref.read(chatStoreProvider).addBenchmark(jsonEncode(result.toJson()));
      if (!ref.mounted) return;
      final saved = result.withId(id);
      state = state.copyWith(
        result: () => saved,
        history: [saved, ...state.history].take(ChatDb.maxBenchmarks).toList(),
        disturbed: result.disturbed,
      );
      // Shared in the background when the user allows it; it never holds up the page.
      unawaited(ref.read(benchmarkSharerProvider).share(saved, file: file, kvCache: setup.kvCache.id, layout: end?.layout ?? const {}));
    } on EngineFailure catch (failure) {
      state = state.copyWith(error: () => failure.message);
    } on Exception catch (e) {
      state = state.copyWith(error: () => 'The run could not be finished: $e');
    } finally {
      polling?.cancel();
      await watching?.cancel();
      await monitor.stop();
      // A run's conversation is not kept, and the engine is not left running behind it.
      if (chatId != null) await control.eraseChatState(chatId);
      await control.stopEngine();
      _reply = null;
      _replied = null;
      if (ref.mounted) {
        state = state.copyWith(
          phase: BenchmarkPhase.idle,
          modelId: () => null,
          profileId: () => null,
          promptProgress: () => null,
          turnStartSeconds: () => null,
          note: _stopped ? () => 'Stopped. Nothing was saved.' : null,
        );
      }
    }
  }

  /// Stops the run; nothing of it is kept.
  void stop() {
    _stopped = true;
    final replied = _replied;
    unawaited(_reply?.cancel());
    if (replied != null && !replied.isCompleted) replied.complete('');
    // (Still loading: the engine is told to stop, and the load ends.)
    if (state.phase == BenchmarkPhase.loading) unawaited(_control?.stopEngine());
  }
}

/// Makes the watcher of the machine (the tests give their own).
final hardwareMonitorProvider = Provider<HardwareMonitor Function()>((ref) => HardwareMonitor.new);

final benchmarkProvider = NotifierProvider<BenchmarkNotifier, BenchmarkState>(BenchmarkNotifier.new);

/// The Engine page's tab: true for Benchmark.
class EngineTabNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void show({required bool benchmark}) => state = benchmark;
}

final engineTabProvider = NotifierProvider<EngineTabNotifier, bool>(EngineTabNotifier.new);
