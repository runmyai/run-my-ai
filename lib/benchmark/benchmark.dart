import 'dart:math' as math;

import '../backend/backend.dart' show defaultContextLength;
import '../engine/context_fit.dart';
import 'hardware.dart';
import 'memory_layout.dart';
import 'prompts.dart';
import 'series.dart';

/// Whether a measured message of [promptTokens] fits a context of [contextLength] with room for a reply of
/// [replyLength]: the engine drops the oldest messages when more than this is sent.
bool promptFits(int promptTokens, int replyLength, int contextLength) =>
    promptTokens + replyLength <= contextLength - ContextFit.replyRoom(contextLength);

/// One of the tests the Benchmark tab offers. Every test sends the two warm-up messages first ([warmupMessages]); what
/// follows, and the most tokens of the reply, are fixed here and cannot be edited.
class BenchmarkTest {
  const BenchmarkTest._(this.id, this.label, this.promptTokens, [this.story]);

  final String id;

  /// How the test is named in the setup and in the history.
  final String label;

  /// The tokens of text a prompt test sends; null for the reply-speed test.
  final int? promptTokens;

  /// The asset that holds a prompt test's own story: a little longer than [promptTokens] for every model, and cut at
  /// its end to that many tokens of the running model. Null for the reply-speed test.
  final String? story;

  /// A long reply to a short message: the generation speed.
  static const replySpeed = BenchmarkTest._('reply', 'Reply speed', null);

  /// A long story to read and a short reply: the prompt processing speed. Each size has a story of its own.
  static const prompt25k = BenchmarkTest._('prompt-25k', 'Prompt 25k', 25000, 'assets/benchmark/stories/daisy-miller.txt');
  static const prompts = [
    BenchmarkTest._('prompt-8k', 'Prompt 8k', 8000, 'assets/benchmark/stories/the-fall-of-the-house-of-usher.txt'),
    prompt25k,
    BenchmarkTest._('prompt-50k', 'Prompt 50k', 50000, 'assets/benchmark/stories/a-study-in-scarlet.txt'),
    BenchmarkTest._('prompt-100k', 'Prompt 100k', 100000, 'assets/benchmark/stories/kidnapped.txt'),
  ];

  /// Every test, in the order a run takes them: the reply speed first, then the prompts small to large.
  static const all = [replySpeed, ...prompts];

  /// The test with this id; the reply-speed test for one that is not known (a setup saved by an older version).
  static BenchmarkTest byId(Object? id) => all.firstWhere((t) => t.id == id, orElse: () => replySpeed);

  /// The test with this label (how a run saved by an older version names its one test); null for one not known.
  static BenchmarkTest? byLabel(String label) => all.where((t) => t.label == label).firstOrNull;

  bool get isReplySpeed => promptTokens == null;

  /// The size alone ("25k"), for a prompt test's line in a result.
  String get size => label.replaceFirst('Prompt ', '');

  /// The most tokens the reply may have; it stops sooner when the model stops.
  int get replyCap => promptTokens == null ? replySpeedMaxTokens : promptReviewMaxTokens;

  /// Whether the test fits a context of [contextLength]: its text, the warm-ups' room and its reply, by [promptFits].
  bool fits(int contextLength) => promptTokens == null || promptFits(promptTokens! + warmupRoomTokens, replyCap, contextLength);

  /// What the test sends after the warm-ups, in a few words.
  String get description => promptTokens == null ? 'a long story' : 'a story of ${promptTokens! ~/ 1000}k tokens and a short review';
}

/// A type of the KV cache, named as the Run page names it.
class KvCache {
  const KvCache._(this.id, this.name, this.tag);

  /// The engine's name for the type (the value of `-ctk` and `-ctv`).
  final String id;
  final String name;
  final String tag;

  static const q4 = KvCache._('q4_0', 'Efficient', 'Q4_0');
  static const q8 = KvCache._('q8_0', 'Balanced', 'Q8_0');
  static const fp16 = KvCache._('fp16', 'Full Quality', 'FP16');
  static const all = [q4, q8, fp16];

  /// The type with this id; the 8-bit one for one that is not known.
  static KvCache byId(Object? id) => all.firstWhere((k) => k.id == id, orElse: () => q8);

  String get label => '$name ($tag)';
}

/// The context length a setup runs with: the one it saved when the model's preset has it, otherwise the default one
/// (or the closest the preset has below it).
int contextChoice(List<int> presets, int saved) {
  if (presets.isEmpty || presets.contains(saved)) return saved;
  return presets.lastWhere((n) => n <= defaultContextLength, orElse: () => presets.first);
}

/// What the Benchmark tab was last set to: the context length, the KV cache and the tests.
class BenchmarkSetup {
  const BenchmarkSetup({this.contextLength = defaultContextLength, this.kvCache = KvCache.q8, this.tests = defaultTests});

  /// The tests chosen when nothing else was.
  static const defaultTests = [BenchmarkTest.replySpeed, BenchmarkTest.prompt25k];

  /// The context length asked for; a model whose preset lacks it runs the default one ([contextChoice]).
  final int contextLength;

  /// The KV cache type chosen. A placeholder for now: it is kept and shown, and changes nothing in a run (every
  /// preset runs `q8_0`).
  final KvCache kvCache;

  /// The tests chosen, in the order a run takes them ([BenchmarkTest.all]). One that does not fit the context length is
  /// kept chosen for a longer one, and left out of a run ([runnable]).
  final List<BenchmarkTest> tests;

  /// The messages sent before the tests.
  List<String> get warmups => warmupMessages;

  /// The chosen tests that fit a context of [contextLength], in the order they run.
  List<BenchmarkTest> runnable(int contextLength) => [for (final t in tests) if (t.fits(contextLength)) t];

  /// The setup with [test] chosen or no longer chosen.
  BenchmarkSetup toggled(BenchmarkTest test) {
    final on = tests.contains(test);
    return copyWith(tests: [for (final t in BenchmarkTest.all) if (t == test ? !on : tests.contains(t)) t]);
  }

  BenchmarkSetup copyWith({int? contextLength, KvCache? kvCache, List<BenchmarkTest>? tests}) => BenchmarkSetup(
    contextLength: contextLength ?? this.contextLength,
    kvCache: kvCache ?? this.kvCache,
    tests: tests ?? this.tests,
  );

  Map<String, Object?> toJson() => {'contextLength': contextLength, 'kvCache': kvCache.id, 'tests': [for (final t in tests) t.id]};

  /// Reads a saved setup; what it lacks, or what an older version wrote in its place (the one test it ran, the
  /// profile, the prompt, the custom text, the reply length, the warm-ups, the test flags, the memory cap), is the
  /// default.
  factory BenchmarkSetup.fromJson(Map<String, Object?> json) => BenchmarkSetup(
    contextLength: json['contextLength'] is num ? (json['contextLength']! as num).toInt() : defaultContextLength,
    kvCache: KvCache.byId(json['kvCache']),
    tests: json['tests'] is List
        ? [for (final t in BenchmarkTest.all) if ((json['tests']! as List).contains(t.id)) t]
        : defaultTests,
  );
}

/// Where a run happened, for its record: the versions, the model file and the computer.
class RunEnvironment {
  const RunEnvironment({
    this.engineVersion,
    this.appVersion,
    this.modelFileBytes,
    this.modelFileModified,
    this.hardware = const HardwareInfo(),
    this.onBattery,
    this.addedFlags = const [],
    this.profileId,
  });

  final String? engineVersion;
  final String? appVersion;
  final int? modelFileBytes;
  final DateTime? modelFileModified;
  final HardwareInfo hardware;

  /// Whether the computer ran on its battery when the run began; null when it could not be told.
  final bool? onBattery;

  /// Flags the benchmark put on the command itself (they are in the recorded flags too).
  final List<String> addedFlags;
  final String? profileId;

  Map<String, Object?> toJson() => {
    'engineVersion': engineVersion,
    'appVersion': appVersion,
    'modelFileBytes': modelFileBytes,
    'modelFileModified': modelFileModified?.millisecondsSinceEpoch,
    'hardware': hardware.toJson(),
    'onBattery': onBattery,
    'addedFlags': addedFlags,
    'profileId': profileId,
  };

  factory RunEnvironment.fromJson(Map<String, Object?> json) => RunEnvironment(
    engineVersion: json['engineVersion'] as String?,
    appVersion: json['appVersion'] as String?,
    modelFileBytes: json['modelFileBytes'] as int?,
    modelFileModified: json['modelFileModified'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(json['modelFileModified']! as int),
    hardware: HardwareInfo.fromJson(((json['hardware'] as Map?) ?? const {}).cast<String, Object?>()),
    onBattery: json['onBattery'] as bool?,
    addedFlags: ((json['addedFlags'] as List?) ?? const []).cast<String>(),
    profileId: json['profileId'] as String?,
  );
}

/// The spread of the token times: the value at 50 %, 90 %, 99 % and the longest, and the mean.
class TokenStats {
  const TokenStats(this.p50, this.p90, this.p99, this.max, this.mean);

  final double p50, p90, p99, max, mean;

  factory TokenStats.of(List<double> tokens) => tokens.isEmpty
      ? const TokenStats(0, 0, 0, 0, 0)
      : TokenStats(
          percentile(tokens, 0.5),
          percentile(tokens, 0.9),
          percentile(tokens, 0.99),
          tokens.reduce(math.max),
          tokens.reduce((a, b) => a + b) / tokens.length,
        );
}

/// One turn of a run: a warm-up message or the measured one, with the numbers of that turn alone. Warm-up turns
/// used to be thrown away; they are kept now (marked warm-up) so the user can see the numbers they would have
/// gotten without a warm-up, and how each turn compares with the next. The engine counters are the turn's own
/// final response (`timings.moe_stream`), not the live endpoint's.
class TurnRecord {
  const TurnRecord({
    required this.warmup,
    required this.firstTokenMillis,
    required this.promptTokens,
    required this.promptMillis,
    required this.replyTokens,
    required this.replyMillis,
    required this.totalMillis,
    this.stopReason,
    this.tokenGaps = const [],
    this.tokenMillis = const [],
    this.engineStats = const {},
    this.startSeconds,
    this.endSeconds,
  });

  /// Whether this turn is a warm-up (the last turn of a run is the measured one).
  final bool warmup;

  /// From sending the turn's message to its first token.
  final int firstTokenMillis;
  final int promptTokens;
  final double promptMillis;
  final int replyTokens;
  final double replyMillis;

  /// From sending the turn's message to the end of its reply.
  final int totalMillis;
  final String? stopReason;

  /// The time before each token after the first as the app saw it, in milliseconds.
  final List<double> tokenGaps;

  /// The time of each token as the engine counted it, in milliseconds.
  final List<double> tokenMillis;

  /// The engine's counters for this turn (`timings.moe_stream` of its final response).
  final Map<String, Object?> engineStats;

  /// When the turn's message was sent and when its reply was complete, in seconds on the run's time axis (the
  /// [RunSeries] clock); null in a run saved before the turns were timed.
  final double? startSeconds;
  final double? endSeconds;

  double get tokensPerSecond => replyMillis > 0 ? replyTokens * 1000 / replyMillis : 0;
  double get promptTokensPerSecond => promptMillis > 0 ? promptTokens * 1000 / promptMillis : 0;

  /// The tokens' times: the engine's own where they were kept.
  List<double> get tokens => tokenMillis.isNotEmpty ? tokenMillis : tokenGaps;
  TokenStats get tokenStats => TokenStats.of(tokens);

  /// One of the engine's counters for the `reply` or `prompt` part; null when it does not say.
  double? engineNumber(String part, String key) {
    final phase = engineStats[part] ?? (part == 'reply' ? engineStats['decode'] : null);
    return phase is Map ? (phase[key] as num?)?.toDouble() : null;
  }

  /// The engine's wait on the SSD per token of the reply; null when it does not say.
  double? get ssdWaitPerToken => engineNumber('reply', 'stall_ms_per_token');

  /// The share of expert uses in the reply that were already in memory (RAM or VRAM).
  double? get hitRate => engineNumber('reply', 'hit_rate_percent') ?? (engineStats['hit_rate_percent'] as num?)?.toDouble();

  /// The shares of the reply's expert uses found in RAM and in VRAM (the engine's own split of [hitRate]).
  double? get ramHitPercent => engineNumber('reply', 'ram_hit_percent');
  double? get vramHitPercent => engineNumber('reply', 'vram_hit_percent');

  Map<String, Object?> toJson() => {
    'warmup': warmup,
    'firstTokenMillis': firstTokenMillis,
    'promptTokens': promptTokens,
    'promptMillis': promptMillis,
    'replyTokens': replyTokens,
    'replyMillis': replyMillis,
    'totalMillis': totalMillis,
    if (stopReason != null) 'stopReason': stopReason,
    // The times rounded to a tenth of a millisecond: every turn can show the same charts later without a
    // format change, and a few hundred numbers stay a few KB.
    'tokenGaps': [for (final g in tokenGaps) double.parse(g.toStringAsFixed(1))],
    if (tokenMillis.isNotEmpty)
      'tokenMillis': [for (final w in tokenMillis) double.parse(w.toStringAsFixed(2))],
    if (engineStats.isNotEmpty) 'engineStats': engineStats,
    if (startSeconds != null) 'startSeconds': double.parse(startSeconds!.toStringAsFixed(3)),
    if (endSeconds != null) 'endSeconds': double.parse(endSeconds!.toStringAsFixed(3)),
  };

  factory TurnRecord.fromJson(Map<String, Object?> j) => TurnRecord(
    warmup: j['warmup']! as bool,
    firstTokenMillis: j['firstTokenMillis']! as int,
    promptTokens: j['promptTokens']! as int,
    promptMillis: (j['promptMillis']! as num).toDouble(),
    replyTokens: j['replyTokens']! as int,
    replyMillis: (j['replyMillis']! as num).toDouble(),
    totalMillis: j['totalMillis']! as int,
    stopReason: j['stopReason'] as String?,
    tokenGaps: [for (final g in (j['tokenGaps'] as List?) ?? const []) (g as num).toDouble()],
    tokenMillis: [for (final w in (j['tokenMillis'] as List?) ?? const []) (w as num).toDouble()],
    engineStats: (j['engineStats'] as Map?)?.cast<String, Object?>() ?? const {},
    startSeconds: (j['startSeconds'] as num?)?.toDouble(),
    endSeconds: (j['endSeconds'] as num?)?.toDouble(),
  );
}

/// One test of a run: its measured message and reply ([turn], with that turn's own numbers and engine counters), the
/// parts of a token's time and each layer's counters over its reply.
class TestResult {
  const TestResult({
    required this.testId,
    required this.label,
    required this.turn,
    this.promptText = '',
    this.replyText = '',
    this.timeParts = const {},
    this.layers = const [],
  });

  /// The test's id and name ([BenchmarkTest]).
  final String testId;
  final String label;
  final TurnRecord turn;

  /// The test's message (all of a short one, the start of a long one) and the start of its reply.
  final String promptText;
  final String replyText;
  final Map<String, double> timeParts;
  final List<Map<String, double>> layers;

  BenchmarkTest get test => BenchmarkTest.byId(testId);
  bool get isReplySpeed => test.isReplySpeed;

  Map<String, Object?> toJson() => {
    'testId': testId,
    'label': label,
    'turn': turn.toJson(),
    if (promptText.isNotEmpty) 'promptText': promptText,
    if (replyText.isNotEmpty) 'replyText': replyText,
    if (timeParts.isNotEmpty) 'timeParts': timeParts,
    if (layers.isNotEmpty) 'layers': layers,
  };

  factory TestResult.fromJson(Map<String, Object?> j) => TestResult(
    testId: j['testId']! as String,
    label: j['label']! as String,
    turn: TurnRecord.fromJson((j['turn']! as Map).cast<String, Object?>()),
    promptText: j['promptText'] as String? ?? '',
    replyText: j['replyText'] as String? ?? '',
    timeParts: {for (final e in ((j['timeParts'] as Map?) ?? const {}).entries) e.key as String: (e.value as num).toDouble()},
    layers: [
      for (final l in (j['layers'] as List?) ?? const [])
        {for (final e in (l as Map).entries) e.key as String: (e.value as num).toDouble()},
    ],
  );
}

/// Everything kept about one finished run. A run takes one or more tests ([tests]); the headline fields carry its main
/// test (the reply speed when it ran, else the first prompt), as they carried the one test of a run saved by an older
/// version.
class BenchmarkResult {
  const BenchmarkResult({
    required this.at,
    required this.modelName,
    required this.contextLength,
    required this.profileName,
    required this.flags,
    required this.memoryCapGiB,
    required this.promptLabel,
    required this.replyLength,
    required this.warmups,
    required this.loadMillis,
    required this.firstTokenMillis,
    required this.promptTokens,
    required this.promptMillis,
    required this.replyTokens,
    required this.replyMillis,
    required this.tokenGaps,
    required this.engineStats,
    required this.log,
    required this.disturbed,
    this.id,
    this.vramHeadroom = const {},
    this.promptText = '',
    this.thinking,
    this.replyText = '',
    this.stopReason,
    this.tokenMillis = const [],
    this.totalMillis = 0,
    this.timeParts = const {},
    this.layers = const [],
    this.turns = const [],
    this.tests = const [],
    this.series,
    this.memory = const MemoryLayout(),
    this.environment = const RunEnvironment(),
  });

  /// Its place in the history; null until it is saved.
  final int? id;
  final DateTime at;
  final String modelName;
  final int contextLength;
  final String profileName;
  final String flags;
  final double? memoryCapGiB;

  /// The graphics card memory left free on each card, by the card's key; empty when there was no card or the run was saved
  /// before it was recorded.
  final Map<String, double> vramHeadroom;
  final String promptLabel;
  final int replyLength;
  final List<String> warmups;
  final int loadMillis;

  /// From sending the measured message to its first token.
  final int firstTokenMillis;
  final int promptTokens;
  final double promptMillis;
  final int replyTokens;
  final double replyMillis;

  /// The time before each token after the first as the app saw the tokens arrive (kept for runs made before the engine's
  /// own times were used), in milliseconds.
  final List<double> tokenGaps;

  /// The engine's own counters for the measured message.
  final Map<String, Object?> engineStats;
  final List<String> log;

  /// Why the run was not fair; empty when it was.
  final List<String> disturbed;

  /// The measured message's text (what the prompt label stands for), and whether the model thought first.
  final String promptText;
  final bool? thinking;

  /// The start of the reply, and why it ended (`stop`, `length`).
  final String replyText;
  final String? stopReason;

  /// The time of each token of the reply as the engine counted it, in milliseconds.
  final List<double> tokenMillis;

  /// From sending the measured message to the end of its reply.
  final int totalMillis;

  /// The milliseconds a token took, by part (SSD wait, CPU, GPU, hand-off), as far as the engine says.
  final Map<String, double> timeParts;

  /// Each streamed layer's counters over the reply (`hits`, `misses`, `stall_ms`), when the engine gives them.
  final List<Map<String, double>> layers;

  /// Every turn of the run in order: the warm-up messages and then the measured one, each with its own real
  /// numbers (a run saved by an older app version has none; the headline stays the measured turn).
  final List<TurnRecord> turns;

  /// Each test of the run in the order it ran; empty in a run saved before a run could take several ([testResults]
  /// stands in).
  final List<TestResult> tests;

  /// The machine's numbers over the run, on one time axis, shrunk to keep little.
  final RunSeries? series;
  final MemoryLayout memory;
  final RunEnvironment environment;

  double get tokensPerSecond => replyMillis > 0 ? replyTokens * 1000 / replyMillis : 0;
  double get promptTokensPerSecond => promptMillis > 0 ? promptTokens * 1000 / promptMillis : 0;
  double get millisPerToken => replyTokens > 0 ? replyMillis / replyTokens : 0;

  /// The tokens' times: the engine's own where they were kept.
  List<double> get tokens => tokenMillis.isNotEmpty ? tokenMillis : tokenGaps;
  TokenStats get tokenStats => TokenStats.of(tokens);

  /// The slowest 1 % of the tokens: the time of the token at that edge.
  double get slowestOnePercent => percentile(tokens, 0.99);

  double get slowestToken => tokens.isEmpty ? 0 : tokens.reduce(math.max);

  /// The time of the measured message from its sending to the end of its reply, in milliseconds.
  double get measuredMillis => totalMillis > 0 ? totalMillis.toDouble() : promptMillis + replyMillis;

  /// One of the engine's counters for the `reply` or `prompt` part; null when it does not say.
  double? engineNumber(String part, String key) {
    final phase = engineStats[part] ?? (part == 'reply' ? engineStats['decode'] : null);
    return phase is Map ? (phase[key] as num?)?.toDouble() : null;
  }

  /// The engine's wait on the SSD per token of the reply; null when it does not say.
  double? get ssdWaitPerToken => engineNumber('reply', 'stall_ms_per_token');

  /// The share of expert uses in the reply that were already in memory (RAM or VRAM).
  double? get hitRate => engineNumber('reply', 'hit_rate_percent') ?? (engineStats['hit_rate_percent'] as num?)?.toDouble();

  /// The shares of the reply's expert uses found in RAM and in VRAM (the engine's own split of [hitRate]).
  double? get ramHitPercent => engineNumber('reply', 'ram_hit_percent');
  double? get vramHitPercent => engineNumber('reply', 'vram_hit_percent');

  /// Each test of the run: [tests], or for a run saved by an older version its one test, made from the headline fields.
  List<TestResult> get testResults {
    if (tests.isNotEmpty) return tests;
    final test = BenchmarkTest.byLabel(promptLabel) ?? BenchmarkTest.replySpeed;
    final measured = turns.where((t) => !t.warmup).lastOrNull;
    return [
      TestResult(
        testId: test.id,
        label: promptLabel,
        turn: measured ??
            TurnRecord(
              warmup: false,
              firstTokenMillis: firstTokenMillis,
              promptTokens: promptTokens,
              promptMillis: promptMillis,
              replyTokens: replyTokens,
              replyMillis: replyMillis,
              totalMillis: totalMillis,
              stopReason: stopReason,
              tokenGaps: tokenGaps,
              tokenMillis: tokenMillis,
              engineStats: engineStats,
            ),
        promptText: promptText,
        replyText: replyText,
        timeParts: timeParts,
        layers: layers,
      ),
    ];
  }

  BenchmarkResult withId(int id) => BenchmarkResult(
    id: id,
    at: at,
    modelName: modelName,
    contextLength: contextLength,
    profileName: profileName,
    flags: flags,
    memoryCapGiB: memoryCapGiB,
    vramHeadroom: vramHeadroom,
    promptLabel: promptLabel,
    replyLength: replyLength,
    warmups: warmups,
    loadMillis: loadMillis,
    firstTokenMillis: firstTokenMillis,
    promptTokens: promptTokens,
    promptMillis: promptMillis,
    replyTokens: replyTokens,
    replyMillis: replyMillis,
    tokenGaps: tokenGaps,
    engineStats: engineStats,
    log: log,
    disturbed: disturbed,
    promptText: promptText,
    thinking: thinking,
    replyText: replyText,
    stopReason: stopReason,
    tokenMillis: tokenMillis,
    totalMillis: totalMillis,
    timeParts: timeParts,
    layers: layers,
    turns: turns,
    tests: tests,
    series: series,
    memory: memory,
    environment: environment,
  );

  Map<String, Object?> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'modelName': modelName,
    'contextLength': contextLength,
    'profileName': profileName,
    'flags': flags,
    'memoryCapGiB': memoryCapGiB,
    if (vramHeadroom.isNotEmpty) 'vramHeadroom': vramHeadroom,
    'promptLabel': promptLabel,
    'replyLength': replyLength,
    'warmups': warmups,
    'loadMillis': loadMillis,
    'firstTokenMillis': firstTokenMillis,
    'promptTokens': promptTokens,
    'promptMillis': promptMillis,
    'replyTokens': replyTokens,
    'replyMillis': replyMillis,
    'tokenGaps': tokenGaps,
    'engineStats': engineStats,
    'log': log,
    'disturbed': disturbed,
    if (promptText.isNotEmpty) 'promptText': promptText,
    if (thinking != null) 'thinking': thinking,
    if (replyText.isNotEmpty) 'replyText': replyText,
    if (stopReason != null) 'stopReason': stopReason,
    if (tokenMillis.isNotEmpty) 'tokenMillis': [for (final w in tokenMillis) double.parse(w.toStringAsFixed(2))],
    if (totalMillis > 0) 'totalMillis': totalMillis,
    if (timeParts.isNotEmpty) 'timeParts': timeParts,
    if (layers.isNotEmpty) 'layers': layers,
    if (turns.isNotEmpty) 'turns': [for (final t in turns) t.toJson()],
    if (tests.isNotEmpty) 'tests': [for (final t in tests) t.toJson()],
    if (series != null) 'series': series!.toJson(),
    if (!memory.isEmpty) 'memory': memory.toJson(),
    'environment': environment.toJson(),
  };

  factory BenchmarkResult.fromJson(Map<String, Object?> j, {int? id}) => BenchmarkResult(
    id: id,
    at: DateTime.fromMillisecondsSinceEpoch(j['at']! as int),
    modelName: j['modelName']! as String,
    contextLength: j['contextLength']! as int,
    profileName: j['profileName']! as String,
    flags: j['flags']! as String,
    memoryCapGiB: (j['memoryCapGiB'] as num?)?.toDouble(),
    vramHeadroom: {
      for (final MapEntry(:key, :value) in (j['vramHeadroom'] as Map? ?? const {}).entries)
        if (value is num) '$key': value.toDouble(),
    },
    promptLabel: j['promptLabel']! as String,
    replyLength: j['replyLength']! as int,
    warmups: (j['warmups']! as List).cast<String>(),
    loadMillis: j['loadMillis']! as int,
    // A run saved by an older app version keeps these under their old names.
    firstTokenMillis: (j['firstTokenMillis'] ?? j['firstWordMillis'])! as int,
    promptTokens: j['promptTokens']! as int,
    promptMillis: (j['promptMillis']! as num).toDouble(),
    replyTokens: j['replyTokens']! as int,
    replyMillis: (j['replyMillis']! as num).toDouble(),
    tokenGaps: [for (final g in ((j['tokenGaps'] ?? j['wordGaps'])! as List)) (g as num).toDouble()],
    engineStats: (j['engineStats'] as Map?)?.cast<String, Object?>() ?? const {},
    log: (j['log']! as List).cast<String>(),
    disturbed: (j['disturbed']! as List).cast<String>(),
    promptText: j['promptText'] as String? ?? '',
    thinking: j['thinking'] as bool?,
    replyText: j['replyText'] as String? ?? '',
    stopReason: j['stopReason'] as String?,
    tokenMillis: [for (final w in ((j['tokenMillis'] ?? j['wordMillis']) as List?) ?? const []) (w as num).toDouble()],
    totalMillis: j['totalMillis'] as int? ?? 0,
    timeParts: {
      // Results saved by earlier app versions name this part 'Hand-off' or 'Waiting for the GPU'; 'CPU-GPU sync' is
      // its name here.
      for (final e in ((j['timeParts'] as Map?) ?? const {}).entries)
        (e.key == 'Hand-off' || e.key == 'Waiting for the GPU' ? 'CPU-GPU sync' : e.key as String): (e.value as num).toDouble(),
    },
    layers: [
      for (final l in (j['layers'] as List?) ?? const [])
        {for (final e in (l as Map).entries) e.key as String: (e.value as num).toDouble()},
    ],
    // Runs saved by older app versions have no per-turn list; the headline fields carry the measured turn.
    turns: [for (final t in (j['turns'] as List?) ?? const []) TurnRecord.fromJson((t as Map).cast<String, Object?>())],
    tests: [for (final t in (j['tests'] as List?) ?? const []) TestResult.fromJson((t as Map).cast<String, Object?>())],
    series: j['series'] == null ? null : RunSeries.fromJson((j['series']! as Map).cast<String, Object?>()),
    memory: j['memory'] == null ? const MemoryLayout() : MemoryLayout.fromJson((j['memory']! as Map).cast<String, Object?>()),
    environment: j['environment'] == null
        ? const RunEnvironment()
        : RunEnvironment.fromJson((j['environment']! as Map).cast<String, Object?>()),
  );
}

/// The value at share [p] (0..1) of the sorted [values]; 0 without values.
double percentile(List<double> values, double p) {
  if (values.isEmpty) return 0;
  final sorted = [...values]..sort();
  return sorted[((sorted.length - 1) * p).round()];
}

/// How many tokens of [values] fall in each of [bins] equal steps from 0 to [top]; a token above [top] counts in the last
/// step. For the spread chart.
List<int> histogram(List<double> values, double top, int bins) {
  final counts = List.filled(bins, 0);
  if (top <= 0) return counts;
  for (final v in values) {
    counts[(v / top * bins).floor().clamp(0, bins - 1)]++;
  }
  return counts;
}
