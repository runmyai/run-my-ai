import '../engine/engine_flags.dart';
import 'benchmark.dart';

/// One headline number of a run beside the same number of another run.
class RunDelta {
  const RunDelta(this.label, this.unit, this.now, this.other, {required this.higherIsBetter, this.digits = 1});

  final String label;
  final String unit;
  final double? now;
  final double? other;
  final bool higherIsBetter;
  final int digits;

  /// [now] less [other]; null when either is missing.
  double? get change => now == null || other == null ? null : now! - other!;

  /// The change as a share of [other]; null when it cannot be told.
  double? get percent => change == null || other == 0 ? null : 100 * change! / other!;

  /// Whether the change is for the better: true, false, or null when it is none (or not known).
  bool? get better {
    final c = change;
    if (c == null || c.abs() < 0.5 * _unit) return null;
    return (c > 0) == higherIsBetter;
  }

  double get _unit => digits == 0 ? 1 : 1 / _pow10(digits);

  static double _pow10(int n) => n <= 0 ? 1 : 10 * _pow10(n - 1);
}

/// This run's headline numbers against [other]'s.
List<RunDelta> compareRuns(BenchmarkResult run, BenchmarkResult other) {
  double? sec(int ms) => ms > 0 ? ms / 1000 : null;
  RunDelta d(String label, String unit, double? a, double? b, {required bool up, int digits = 1}) =>
      RunDelta(label, unit, a, b, higherIsBetter: up, digits: digits);
  return [
    d('Generation speed', 'tokens/s', run.tokensPerSecond, other.tokensPerSecond, up: true),
    d('Prompt processing', 'tokens/s', run.promptTokensPerSecond, other.promptTokensPerSecond, up: true, digits: 0),
    d('TTFT', 's', sec(run.firstTokenMillis), sec(other.firstTokenMillis), up: false, digits: 2),
    d('Load time', 's', sec(run.loadMillis), sec(other.loadMillis), up: false),
    d('p99', 'ms/token', run.slowestOnePercent, other.slowestOnePercent, up: false, digits: 0),
    d('Slowest token', 'ms/token', run.slowestToken, other.slowestToken, up: false, digits: 0),
    d('Time of the message', 's', run.measuredMillis / 1000, other.measuredMillis / 1000, up: false),
    d('SSD wait per token', 'ms/token', run.ssdWaitPerToken, other.ssdWaitPerToken, up: false),
    d('RAM hit rate', '%', run.hitRate, other.hitRate, up: true),
  ];
}

/// The flags of a command by name (`-c`, `--temp`, or `NAME` for an environment setting) with their values.
Map<String, String> flagMap(String command) {
  final flags = EngineFlags.parse(command);
  final out = {for (final e in flags.environment.entries) e.key: e.value};
  String? name;
  final values = <String>[];
  void flush() {
    if (name != null) out[name] = values.join(' ');
    values.clear();
  }

  for (final word in flags.arguments) {
    final isFlag = word.startsWith('-') && word.length > 1 && !RegExp(r'^-\d').hasMatch(word);
    if (isFlag) {
      flush();
      final eq = word.indexOf('=');
      if (eq > 0) {
        out[word.substring(0, eq)] = word.substring(eq + 1);
        name = null;
      } else {
        name = word;
      }
    } else {
      values.add(word);
    }
  }
  flush();
  return out;
}

/// How the flags of one run differ from another's.
class FlagDiff {
  const FlagDiff({this.added = const {}, this.removed = const {}, this.changed = const {}});

  /// In this run only, in the other only, and in both with another value (the value of this run).
  final Map<String, String> added;
  final Map<String, String> removed;
  final Map<String, String> changed;

  bool get isEmpty => added.isEmpty && removed.isEmpty && changed.isEmpty;

  /// Every flag name that differs.
  Set<String> get names => {...added.keys, ...removed.keys, ...changed.keys};
}

FlagDiff diffFlags(String command, String other) {
  final a = flagMap(command), b = flagMap(other);
  return FlagDiff(
    added: {for (final e in a.entries) if (!b.containsKey(e.key)) e.key: e.value},
    removed: {for (final e in b.entries) if (!a.containsKey(e.key)) e.key: e.value},
    changed: {for (final e in a.entries) if (b.containsKey(e.key) && b[e.key] != e.value) e.key: e.value},
  );
}
