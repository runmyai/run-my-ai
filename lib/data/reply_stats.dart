/// How a reply went, from the engine's own numbers for it: what the card under the reply shows. A number the engine
/// did not give is null and is left out.
class ReplyStats {
  const ReplyStats({
    this.wordsPerSecond,
    this.promptTokensPerSecond,
    this.firstWordMillis,
    this.promptTokens,
    this.replyTokens,
    this.totalMillis,
    this.ssdWaitPerWord,
    this.hitRate,
    this.modelName,
    this.profileName,
    this.contextLength,
  });

  final double? wordsPerSecond;
  final double? promptTokensPerSecond;

  /// From the end of the sent message to the first word.
  final double? firstWordMillis;

  /// The tokens the model was given (read now and kept from before) and the ones it wrote.
  final int? promptTokens;
  final int? replyTokens;
  final double? totalMillis;

  /// The engine's wait on the SSD per word, and the share of the experts it found in RAM.
  final double? ssdWaitPerWord;
  final double? hitRate;

  /// What wrote it: the model, the profile and the context length.
  final String? modelName;
  final String? profileName;
  final int? contextLength;

  bool get isEmpty =>
      wordsPerSecond == null &&
      promptTokensPerSecond == null &&
      firstWordMillis == null &&
      promptTokens == null &&
      replyTokens == null &&
      totalMillis == null &&
      ssdWaitPerWord == null &&
      hitRate == null;

  /// From the `timings` of a reply's final response, with the time of each word ([wordMillis]) when it came with
  /// them.
  factory ReplyStats.fromTimings(
    Map<String, Object?> timings, {
    List<double> wordMillis = const [],
    String? modelName,
    String? profileName,
    int? contextLength,
  }) {
    double? number(String key) => (timings[key] as num?)?.toDouble();
    final replyTokens = number('predicted_n');
    final replyMillis = number('predicted_ms');
    final promptTokens = number('prompt_n');
    final promptMillis = number('prompt_ms');
    final cached = number('cache_n') ?? 0;
    final stream = timings['moe_stream'];
    double? streamNumber(String key) {
      if (stream is! Map) return null;
      final reply = stream['reply'];
      final v = (reply is Map ? reply[key] : null) ?? stream[key];
      return v is num ? v.toDouble() : null;
    }

    final words = replyTokens != null && replyMillis != null && replyMillis > 0
        ? replyTokens * 1000 / replyMillis
        : number('predicted_per_second');
    return ReplyStats(
      wordsPerSecond: words != null && words > 0 ? words : null,
      promptTokensPerSecond: promptTokens != null && promptTokens > 0 && promptMillis != null && promptMillis > 0
          ? promptTokens * 1000 / promptMillis
          : null,
      firstWordMillis: promptMillis == null ? null : promptMillis + (wordMillis.isEmpty ? 0 : wordMillis.first),
      promptTokens: promptTokens == null ? null : (promptTokens + cached).round(),
      replyTokens: replyTokens?.round(),
      totalMillis: promptMillis == null && replyMillis == null ? null : (promptMillis ?? 0) + (replyMillis ?? 0),
      ssdWaitPerWord: streamNumber('stall_ms_per_token'),
      hitRate: streamNumber('hit_rate_percent'),
      modelName: modelName,
      profileName: profileName,
      contextLength: contextLength,
    );
  }

  ReplyStats withBasis({String? modelName, String? profileName, int? contextLength}) => ReplyStats(
    wordsPerSecond: wordsPerSecond,
    promptTokensPerSecond: promptTokensPerSecond,
    firstWordMillis: firstWordMillis,
    promptTokens: promptTokens,
    replyTokens: replyTokens,
    totalMillis: totalMillis,
    ssdWaitPerWord: ssdWaitPerWord,
    hitRate: hitRate,
    modelName: modelName ?? this.modelName,
    profileName: profileName ?? this.profileName,
    contextLength: contextLength ?? this.contextLength,
  );

  Map<String, Object?> toJson() => {
    'wordsPerSecond': ?wordsPerSecond,
    'promptTokensPerSecond': ?promptTokensPerSecond,
    'firstWordMillis': ?firstWordMillis,
    'promptTokens': ?promptTokens,
    'replyTokens': ?replyTokens,
    'totalMillis': ?totalMillis,
    'ssdWaitPerWord': ?ssdWaitPerWord,
    'hitRate': ?hitRate,
    'modelName': ?modelName,
    'profileName': ?profileName,
    'contextLength': ?contextLength,
  };

  factory ReplyStats.fromJson(Map<String, Object?> json) => ReplyStats(
    wordsPerSecond: (json['wordsPerSecond'] as num?)?.toDouble(),
    promptTokensPerSecond: (json['promptTokensPerSecond'] as num?)?.toDouble(),
    firstWordMillis: (json['firstWordMillis'] as num?)?.toDouble(),
    promptTokens: (json['promptTokens'] as num?)?.toInt(),
    replyTokens: (json['replyTokens'] as num?)?.toInt(),
    totalMillis: (json['totalMillis'] as num?)?.toDouble(),
    ssdWaitPerWord: (json['ssdWaitPerWord'] as num?)?.toDouble(),
    hitRate: (json['hitRate'] as num?)?.toDouble(),
    modelName: json['modelName'] as String?,
    profileName: json['profileName'] as String?,
    contextLength: (json['contextLength'] as num?)?.toInt(),
  );
}
