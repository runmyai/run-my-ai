import 'dart:math' as math;

import '../backend/backend.dart' show defaultContextLength;
import '../engine/context_fit.dart';
import 'hardware.dart';
import 'memory_layout.dart';
import 'series.dart';

/// What a benchmark's measured message is.
class BenchmarkPrompt {
  const BenchmarkPrompt(this.id, this.label);

  final String id;
  final String label;

  static const story = BenchmarkPrompt('story', 'Story chat');
  static const custom = BenchmarkPrompt('custom', 'My own text');
  static const sized = [
    BenchmarkPrompt('1k', '1k'),
    BenchmarkPrompt('4k', '4k'),
    BenchmarkPrompt('16k', '16k'),
    BenchmarkPrompt('32k', '32k'),
  ];
  static const all = [story, ...sized, custom];

  /// The prompt with this id; the story chat for one that is not known (a setup saved by an older version).
  static BenchmarkPrompt byId(String id) => all.firstWhere((p) => p.id == id, orElse: () => story);

  /// The tokens of a built-in long prompt; null for the others.
  int? get tokens => sized.contains(this) ? int.parse(id.substring(0, id.length - 1)) * 1000 : null;
}

/// Whether a measured message of [promptTokens] fits a context of [contextLength] with room for a reply of
/// [replyLength]: the engine drops the oldest messages when more than this is sent.
bool promptFits(int promptTokens, int replyLength, int contextLength) =>
    promptTokens + replyLength <= contextLength - ContextFit.replyRoom(contextLength);

/// What the Benchmark tab was last set to.
class BenchmarkSetup {
  const BenchmarkSetup({
    this.profileId = 'auto',
    this.contextLength = defaultContextLength,
    this.promptId = 'story',
    this.customText = '',
    this.replyLength = defaultReplyLength,
    this.warmups = defaultWarmups,
    this.testFlags = '',
    this.testMemoryCapGiB,
  });

  static const testProfileId = 'test';
  static const defaultReplyLength = 1024;
  static const storyRequest = 'Write me a long story about a lighthouse keeper who finds a message in a bottle.';

  static const defaultWarmups = [
    'I am planning to change how I spend my weekday evenings, and I would like some honest advice. At the moment I get '
        'home from work at about six, cook something simple, and then spend most of the night looking at my phone until '
        'I feel tired. I do not feel rested by it, and I keep telling myself that I should read more, go for walks, and '
        'call my family more often, but it never quite happens. I have tried making long lists of habits and they last '
        'about a week. I live alone in a small flat near a park, I have a bicycle I rarely use, and I have about three '
        'free hours every evening. I am not looking for a perfect routine, and I do not want an app or anything I have '
        'to buy. What would you change first, and how would you keep it going once the first week is over and the '
        'novelty has worn off? Please also tell me what I should stop trying to do, because I suspect that part of the '
        'problem is that I keep trying to do too many things at once.',
    'I have a small coding task in Python and I would like you to write it carefully. I have a folder of text files '
        'where every line is a date, a shop name and an amount of money, separated by commas, like this: 2024-03-01, '
        'Corner Bakery, 4.50. Some lines are broken: the amount can be missing, the date can be in the wrong form, or '
        'the line can be empty. I want a function that reads every file in the folder, skips the broken lines while '
        'counting how many it skipped, and adds up the money spent in each shop and in each month. It should return '
        'both totals, and the months should be sorted from oldest to newest. Please use only the standard library, '
        'keep the money exact rather than using floating point numbers, and do not read the whole of a file into '
        'memory at once. After the function, write three short tests that show it handles a normal file, a file '
        'with broken lines, and an empty folder, and explain in two sentences why you chose the data types you used.',
  ];

  final String profileId;

  /// The context length asked for; a profile that lacks it runs the closest one it has (not used by Test mode, whose
  /// flags set it).
  final int contextLength;
  final String promptId;
  final String customText;

  /// The most tokens a reply may have; it stops sooner when the model stops.
  final int replyLength;
  final List<String> warmups;
  final String testFlags;
  final double? testMemoryCapGiB;

  BenchmarkSetup copyWith({
    String? profileId,
    int? contextLength,
    String? promptId,
    String? customText,
    int? replyLength,
    List<String>? warmups,
    String? testFlags,
    double? Function()? testMemoryCapGiB,
  }) => BenchmarkSetup(
    profileId: profileId ?? this.profileId,
    contextLength: contextLength ?? this.contextLength,
    promptId: promptId ?? this.promptId,
    customText: customText ?? this.customText,
    replyLength: replyLength ?? this.replyLength,
    warmups: warmups ?? this.warmups,
    testFlags: testFlags ?? this.testFlags,
    testMemoryCapGiB: testMemoryCapGiB != null ? testMemoryCapGiB() : this.testMemoryCapGiB,
  );

  Map<String, Object?> toJson() => {
    'profileId': profileId,
    'contextLength': contextLength,
    'promptId': promptId,
    'customText': customText,
    'replyLength': replyLength,
    'warmups': warmups,
    'testFlags': testFlags,
    'testMemoryCapGiB': testMemoryCapGiB,
  };

  factory BenchmarkSetup.fromJson(Map<String, Object?> json) => BenchmarkSetup(
    profileId: json['profileId'] as String? ?? 'auto',
    contextLength: json['contextLength'] as int? ?? defaultContextLength,
    promptId: BenchmarkPrompt.byId(json['promptId'] as String? ?? 'story').id,
    customText: json['customText'] as String? ?? '',
    replyLength: json['replyLength'] as int? ?? defaultReplyLength,
    warmups: (json['warmups'] as List?)?.cast<String>() ?? defaultWarmups,
    testFlags: json['testFlags'] as String? ?? '',
    testMemoryCapGiB: (json['testMemoryCapGiB'] as num?)?.toDouble(),
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

/// The spread of the word times: the value at 50 %, 90 %, 99 % and the longest, and the mean.
class WordStats {
  const WordStats(this.p50, this.p90, this.p99, this.max, this.mean);

  final double p50, p90, p99, max, mean;

  factory WordStats.of(List<double> words) => words.isEmpty
      ? const WordStats(0, 0, 0, 0, 0)
      : WordStats(
          percentile(words, 0.5),
          percentile(words, 0.9),
          percentile(words, 0.99),
          words.reduce(math.max),
          words.reduce((a, b) => a + b) / words.length,
        );
}

/// Everything kept about one finished run.
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
    required this.firstWordMillis,
    required this.promptTokens,
    required this.promptMillis,
    required this.replyTokens,
    required this.replyMillis,
    required this.wordGaps,
    required this.engineStats,
    required this.log,
    required this.disturbed,
    this.id,
    this.promptText = '',
    this.thinking,
    this.replyText = '',
    this.stopReason,
    this.wordMillis = const [],
    this.totalMillis = 0,
    this.timeParts = const {},
    this.layers = const [],
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
  final String promptLabel;
  final int replyLength;
  final List<String> warmups;
  final int loadMillis;

  /// From sending the measured message to its first word.
  final int firstWordMillis;
  final int promptTokens;
  final double promptMillis;
  final int replyTokens;
  final double replyMillis;

  /// The time before each word after the first as the app saw the words arrive (kept for runs made before the engine's
  /// own times were used), in milliseconds.
  final List<double> wordGaps;

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

  /// The time of each word of the reply as the engine counted it, in milliseconds.
  final List<double> wordMillis;

  /// From sending the measured message to the end of its reply.
  final int totalMillis;

  /// The milliseconds a word took, by part (SSD wait, CPU, GPU, hand-off), as far as the engine says.
  final Map<String, double> timeParts;

  /// Each streamed layer's counters over the reply (`hits`, `misses`, `stall_ms`), when the engine gives them.
  final List<Map<String, double>> layers;

  /// The machine's numbers over the run, on one time axis, shrunk to keep little.
  final RunSeries? series;
  final MemoryLayout memory;
  final RunEnvironment environment;

  double get tokensPerSecond => replyMillis > 0 ? replyTokens * 1000 / replyMillis : 0;
  double get promptTokensPerSecond => promptMillis > 0 ? promptTokens * 1000 / promptMillis : 0;
  double get millisPerWord => replyTokens > 0 ? replyMillis / replyTokens : 0;

  /// The words' times: the engine's own where they were kept.
  List<double> get words => wordMillis.isNotEmpty ? wordMillis : wordGaps;
  WordStats get wordStats => WordStats.of(words);

  /// The slowest 1 % of the words: the time of the word at that edge.
  double get slowestOnePercent => percentile(words, 0.99);

  double get slowestWord => words.isEmpty ? 0 : words.reduce(math.max);

  /// The time of the measured message from its sending to the end of its reply, in milliseconds.
  double get measuredMillis => totalMillis > 0 ? totalMillis.toDouble() : promptMillis + replyMillis;

  /// One of the engine's counters for the `reply` or `prompt` part; null when it does not say.
  double? engineNumber(String part, String key) {
    final phase = engineStats[part] ?? (part == 'reply' ? engineStats['decode'] : null);
    return phase is Map ? (phase[key] as num?)?.toDouble() : null;
  }

  /// The engine's wait on the SSD per word of the reply; null when it does not say.
  double? get ssdWaitPerWord => engineNumber('reply', 'stall_ms_per_token');

  /// The share of expert uses in the reply that were already in RAM.
  double? get hitRate => engineNumber('reply', 'hit_rate_percent') ?? (engineStats['hit_rate_percent'] as num?)?.toDouble();

  BenchmarkResult withId(int id) => BenchmarkResult(
    id: id,
    at: at,
    modelName: modelName,
    contextLength: contextLength,
    profileName: profileName,
    flags: flags,
    memoryCapGiB: memoryCapGiB,
    promptLabel: promptLabel,
    replyLength: replyLength,
    warmups: warmups,
    loadMillis: loadMillis,
    firstWordMillis: firstWordMillis,
    promptTokens: promptTokens,
    promptMillis: promptMillis,
    replyTokens: replyTokens,
    replyMillis: replyMillis,
    wordGaps: wordGaps,
    engineStats: engineStats,
    log: log,
    disturbed: disturbed,
    promptText: promptText,
    thinking: thinking,
    replyText: replyText,
    stopReason: stopReason,
    wordMillis: wordMillis,
    totalMillis: totalMillis,
    timeParts: timeParts,
    layers: layers,
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
    'promptLabel': promptLabel,
    'replyLength': replyLength,
    'warmups': warmups,
    'loadMillis': loadMillis,
    'firstWordMillis': firstWordMillis,
    'promptTokens': promptTokens,
    'promptMillis': promptMillis,
    'replyTokens': replyTokens,
    'replyMillis': replyMillis,
    'wordGaps': wordGaps,
    'engineStats': engineStats,
    'log': log,
    'disturbed': disturbed,
    if (promptText.isNotEmpty) 'promptText': promptText,
    if (thinking != null) 'thinking': thinking,
    if (replyText.isNotEmpty) 'replyText': replyText,
    if (stopReason != null) 'stopReason': stopReason,
    if (wordMillis.isNotEmpty) 'wordMillis': [for (final w in wordMillis) double.parse(w.toStringAsFixed(2))],
    if (totalMillis > 0) 'totalMillis': totalMillis,
    if (timeParts.isNotEmpty) 'timeParts': timeParts,
    if (layers.isNotEmpty) 'layers': layers,
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
    promptLabel: j['promptLabel']! as String,
    replyLength: j['replyLength']! as int,
    warmups: (j['warmups']! as List).cast<String>(),
    loadMillis: j['loadMillis']! as int,
    firstWordMillis: j['firstWordMillis']! as int,
    promptTokens: j['promptTokens']! as int,
    promptMillis: (j['promptMillis']! as num).toDouble(),
    replyTokens: j['replyTokens']! as int,
    replyMillis: (j['replyMillis']! as num).toDouble(),
    wordGaps: [for (final g in j['wordGaps']! as List) (g as num).toDouble()],
    engineStats: (j['engineStats'] as Map?)?.cast<String, Object?>() ?? const {},
    log: (j['log']! as List).cast<String>(),
    disturbed: (j['disturbed']! as List).cast<String>(),
    promptText: j['promptText'] as String? ?? '',
    thinking: j['thinking'] as bool?,
    replyText: j['replyText'] as String? ?? '',
    stopReason: j['stopReason'] as String?,
    wordMillis: [for (final w in (j['wordMillis'] as List?) ?? const []) (w as num).toDouble()],
    totalMillis: j['totalMillis'] as int? ?? 0,
    timeParts: {
      // A result saved before the rename names this part 'Hand-off'.
      for (final e in ((j['timeParts'] as Map?) ?? const {}).entries)
        (e.key == 'Hand-off' ? 'CPU-GPU sync' : e.key as String): (e.value as num).toDouble(),
    },
    layers: [
      for (final l in (j['layers'] as List?) ?? const [])
        {for (final e in (l as Map).entries) e.key as String: (e.value as num).toDouble()},
    ],
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

/// How many words of [values] fall in each of [bins] equal steps from 0 to [top]; a word above [top] counts in the last
/// step. For the spread chart.
List<int> histogram(List<double> values, double top, int bins) {
  final counts = List.filled(bins, 0);
  if (top <= 0) return counts;
  for (final v in values) {
    counts[(v / top * bins).floor().clamp(0, bins - 1)]++;
  }
  return counts;
}
