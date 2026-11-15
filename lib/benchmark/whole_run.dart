import 'dart:math' as math;

import 'benchmark.dart';
import 'engine_stats.dart';

// The numbers of all the turns of a run taken together. Every rate is worked out over all the tokens and all the time of the
// turns (the sum of the tokens over the sum of the times), never as an average of the turns' own rates; only the TTFT, which
// is one number a turn, is the mean of the turns' TTFTs.

/// When token [index] of the turn's [TurnRecord.tokens] was written, in seconds on the run's clock; null when the turn was
/// saved without times or has no such token. The engine's own times start with the first token (it is written when the
/// turn's TTFT is over); the app's gaps are the times before each token after the first.
double? turnTokenSeconds(TurnRecord turn, int index) {
  final start = turn.startSeconds;
  final tokens = turn.tokens;
  if (start == null || index < 0 || index >= tokens.length) return null;
  var millis = turn.firstTokenMillis.toDouble();
  for (var i = turn.tokenMillis.isNotEmpty ? 1 : 0; i <= index; i++) {
    millis += tokens[i];
  }
  return start + millis / 1000;
}

/// The turns of a run as one: its tokens, its time and its rates.
class WholeRun {
  WholeRun(this.turns);

  final List<TurnRecord> turns;

  bool get isEmpty => turns.isEmpty;

  /// The mean of the turns' TTFTs, in milliseconds.
  late final double ttftMillis = turns.isEmpty ? 0 : turns.fold(0.0, (a, t) => a + t.firstTokenMillis) / turns.length;

  late final int promptTokens = turns.fold(0, (a, t) => a + t.promptTokens);
  late final double promptMillis = turns.fold(0.0, (a, t) => a + t.promptMillis);
  late final int replyTokens = turns.fold(0, (a, t) => a + t.replyTokens);
  late final double replyMillis = turns.fold(0.0, (a, t) => a + t.replyMillis);

  /// From the sending of each message to the end of its reply, added up over the turns, in milliseconds.
  late final int messagesMillis = turns.fold(0, (a, t) => a + t.totalMillis);

  /// All the prompt tokens over all the time spent on prompts.
  double get promptTokensPerSecond => promptMillis > 0 ? promptTokens * 1000 / promptMillis : 0;

  /// All the reply tokens over all the time spent on replies.
  double get tokensPerSecond => replyMillis > 0 ? replyTokens * 1000 / replyMillis : 0;

  /// The time of every token of every turn, in order.
  late final List<double> tokens = [for (final t in turns) ...t.tokens];
  late final TokenStats tokenStats = TokenStats.of(tokens);

  /// The time under which 99 % of all the tokens of the run were written, in milliseconds.
  double get p99 => tokenStats.p99;

  /// The engine's numbers over the turns together.
  late final EngineNumbers engine = engineNumbers(turns);

  /// How long the run took, in seconds: the run's own clock when it was kept ([clockEnd]), else the load and the messages
  /// added up.
  double totalSeconds({double? clockEnd, int loadMillis = 0}) =>
      clockEnd != null && clockEnd > 0 ? clockEnd : (loadMillis + messagesMillis) / 1000;

  /// When token [index] of [tokens] was written on the run's clock; null when its turn has no times.
  double? tokenSeconds(int index) {
    if (index < 0) return null;
    var before = 0;
    for (final t in turns) {
      final n = t.tokens.length;
      if (index < before + n) return turnTokenSeconds(t, index - before);
      before += n;
    }
    return null;
  }
}

/// The engine's streaming numbers over one or more turns: the replies' (and, for the reads, the prompts'). A number the
/// engine did not give for any turn is null.
class EngineNumbers {
  const EngineNumbers({
    this.ramHitPercent,
    this.vramHitPercent,
    this.missPercent,
    this.misses,
    this.missesPerToken,
    this.mibRead,
    this.mibPerToken,
    this.ssdWaitPerToken,
    this.guesses = const {},
  });

  /// The share of all the expert uses of the replies found in RAM, and in VRAM.
  final double? ramHitPercent;
  final double? vramHitPercent;

  /// The share of expert uses that were misses.
  final double? missPercent;

  /// The reads from the SSD that the replies had to wait for, and per reply token.
  final double? misses;
  final double? missesPerToken;

  /// All that was read from the SSD (prompts and replies), in MB, and per reply token (the replies' reads only).
  final double? mibRead;
  final double? mibPerToken;

  /// The time the replies waited on the SSD, per reply token, in milliseconds.
  final double? ssdWaitPerToken;

  /// The guesses of the replies by kind (the ids of [guessKinds]): how many there were of each the engine counted.
  final Map<String, double> guesses;

  bool get isEmpty =>
      ramHitPercent == null &&
      vramHitPercent == null &&
      misses == null &&
      mibRead == null &&
      ssdWaitPerToken == null &&
      guessShares.isEmpty;

  double? get cacheHitPercent {
    if (ramHitPercent == null && vramHitPercent == null) return null;
    return (ramHitPercent ?? 0) + (vramHitPercent ?? 0);
  }

  double? get calculatedMissPercent {
    if (missPercent != null) return missPercent;
    if (cacheHitPercent != null) return math.max(0.0, 100.0 - cacheHitPercent!);
    return null;
  }

  double? get totalPredictions {
    final issued = guesses['gIssued'];
    if (issued != null && issued > 0) return issued;
    final inTime = guesses['gInTime'] ?? 0;
    final late = guesses['gLate'] ?? 0;
    final wasted = guesses['gWasted'] ?? 0;
    final cancelled = guesses['gCancelled'] ?? 0;
    final sum = inTime + late + wasted + cancelled;
    return sum > 0 ? sum : null;
  }

  double? get wastedPercent {
    final tot = totalPredictions;
    if (tot == null || tot <= 0) return null;
    return 100.0 * (guesses['gWasted'] ?? 0) / tot;
  }

  double? get cancelledPercent {
    final tot = totalPredictions;
    if (tot == null || tot <= 0) return null;
    return 100.0 * (guesses['gCancelled'] ?? 0) / tot;
  }

  double? get totalWastedPercent {
    final tot = totalPredictions;
    if (tot == null || tot <= 0) return null;
    final wasted = (guesses['gWasted'] ?? 0) + (guesses['gCancelled'] ?? 0);
    return 100.0 * wasted / tot;
  }

  /// What became of the guesses as shares of those that were in time, late or missed: (label, percent); empty when the
  /// engine counted none.
  List<(String, double)> get guessShares {
    const ids = ['gInTime', 'gLate', 'gMissed'];
    final all = ids.fold(0.0, (a, id) => a + (guesses[id] ?? 0));
    if (all <= 0) return const [];
    return [
      for (final (id, label, _) in guessKinds)
        if (ids.contains(id) && guesses.containsKey(id)) (label, 100 * guesses[id]! / all),
    ];
  }
}

/// The engine's numbers over [turns] together. A share is each turn's share weighted by that turn's expert uses (so it is
/// the share of all the uses); a rate per token is the sum over the sum of the reply tokens of the turns that gave it.
EngineNumbers engineNumbers(List<TurnRecord> turns) {
  double? share(String key) {
    var uses = 0.0, hits = 0.0;
    for (final t in turns) {
      final u = t.engineNumber('reply', 'expert_uses'), p = t.engineNumber('reply', key);
      if (u == null || p == null || u <= 0) continue;
      uses += u;
      hits += p * u;
    }
    return uses > 0 ? hits / uses : null;
  }

  // A counter of the replies summed over the turns that have it, and the reply tokens of those turns.
  (double, int)? sum(double? Function(TurnRecord t) of) {
    double? total;
    var tokens = 0;
    for (final t in turns) {
      final v = of(t);
      if (v == null) continue;
      total = (total ?? 0) + v;
      tokens += t.replyTokens;
    }
    return total == null ? null : (total, tokens);
  }

  double perToken((double, int)? s) => s == null || s.$2 <= 0 ? 0 : s.$1 / s.$2;

  final misses = sum((t) => t.engineNumber('reply', 'misses'));
  final reads = sum((t) => t.engineNumber('reply', 'mib_read'));
  final stall = sum((t) {
    final total = t.engineNumber('reply', 'stall_ms');
    if (total != null) return total;
    final each = t.ssdWaitPerToken;
    return each == null ? null : each * t.replyTokens;
  });
  final promptReads = turns.fold<double?>(null, (a, t) {
    final v = t.engineNumber('prompt', 'mib_read');
    return v == null ? a : (a ?? 0) + v;
  });
  final guesses = <String, double>{};
  for (final (id, _, names) in guessKinds) {
    for (final t in turns) {
      final v = pickNumber(t.engineStats, names);
      if (v != null) guesses[id] = (guesses[id] ?? 0) + v;
    }
  }

  return EngineNumbers(
    ramHitPercent: share('ram_hit_percent'),
    vramHitPercent: share('vram_hit_percent'),
    missPercent: share('miss_percent'),
    misses: misses?.$1,
    missesPerToken: misses == null || misses.$2 <= 0 ? null : perToken(misses),
    mibRead: reads == null && promptReads == null ? null : (reads?.$1 ?? 0) + (promptReads ?? 0),
    mibPerToken: reads == null || reads.$2 <= 0 ? null : perToken(reads),
    ssdWaitPerToken: stall == null || stall.$2 <= 0 ? null : perToken(stall),
    guesses: guesses,
  );
}
