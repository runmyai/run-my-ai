/// One part of a run on the shared time axis: the engine loads, the warm-up messages, the measured prompt, the reply.
class PhaseBand {
  PhaseBand(this.name, this.start, [double? end]) : end = end ?? start;

  static const load = 'Load';
  static const warmUp = 'Warm-up';
  static const prompt = 'Prompt';
  static const reply = 'Reply';

  final String name;

  /// Seconds since the run began.
  final double start;
  double end;

  List<Object> toJson() => [name, _round(start), _round(end)];

  factory PhaseBand.fromJson(List<Object?> json) =>
      PhaseBand(json[0]! as String, (json[1]! as num).toDouble(), (json[2]! as num).toDouble());
}

/// The numbers measured while a run went on, as columns on one time axis: a tick (about twice a second) is one entry
/// in [times] and one value, or a gap, in each series. A series is named by an id such as `gpu.0.power`.
///
/// It only ever grows while a run is going on, so the live view reads the same object each time it paints.
class RunSeries {
  RunSeries();

  /// Series whose value is a set of flag bits: shrinking them keeps every flag that was set in the group.
  static bool isBitmask(String id) => id.endsWith('.reasons');

  /// Seconds since the run began, one per tick.
  final times = <double>[];
  final _columns = <String, List<double?>>{};
  final phases = <PhaseBand>[];

  int get length => times.length;
  bool get isEmpty => times.isEmpty;
  double get end => times.isEmpty ? 0 : times.last;
  Iterable<String> get ids => _columns.keys;

  List<double?>? series(String id) => _columns[id];

  /// The value of series [id] at tick [index]; null if there is none.
  double? at(String id, int index) {
    final column = _columns[id];
    return column == null || index < 0 || index >= column.length ? null : column[index];
  }

  /// Adds a tick at [seconds] with the [values] known then; a series not in [values] gets a gap.
  void add(double seconds, Map<String, double?> values) {
    final index = times.length;
    times.add(seconds);
    for (final entry in values.entries) {
      final column = _columns.putIfAbsent(entry.key, () => List<double?>.filled(index, null, growable: true));
      column.add(entry.value);
    }
    for (final column in _columns.values) {
      if (column.length <= index) column.add(null);
    }
  }

  /// A new phase begins at [seconds] (the one before it ends there).
  void beginPhase(String name, double seconds) {
    if (phases.isNotEmpty) phases.last.end = seconds;
    phases.add(PhaseBand(name, seconds));
  }

  /// The present phase ends at [seconds].
  void endPhases(double seconds) {
    if (phases.isNotEmpty) phases.last.end = seconds;
  }

  /// The phase at [seconds]; null before the first.
  PhaseBand? phaseAt(double seconds) {
    PhaseBand? found;
    for (final p in phases) {
      if (p.start <= seconds) found = p;
    }
    return found;
  }

  /// The tick nearest to [seconds]; -1 without ticks.
  int indexAt(double seconds) {
    if (times.isEmpty) return -1;
    var low = 0;
    var high = times.length - 1;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (times[mid] < seconds) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (low > 0 && (seconds - times[low - 1]) < (times[low] - seconds)) low--;
    return low;
  }

  /// The values of series [id] from [from] to [to] (seconds) that exist.
  Iterable<double> valuesBetween(String id, double from, double to) sync* {
    final column = _columns[id];
    if (column == null) return;
    for (var i = 0; i < column.length; i++) {
      final v = column[i];
      if (v != null && times[i] >= from && times[i] <= to) yield v;
    }
  }

  double? average(String id, {double? from, double? to}) {
    final values = valuesBetween(id, from ?? double.negativeInfinity, to ?? double.infinity).toList();
    return values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;
  }

  double? peak(String id, {double? from, double? to}) {
    final values = valuesBetween(id, from ?? double.negativeInfinity, to ?? double.infinity).toList();
    return values.isEmpty ? null : values.reduce((a, b) => a > b ? a : b);
  }

  /// At most [limit] ticks: neighbouring ticks are merged (their values averaged; the flag bits of a bitmask series
  /// combined), so a long run costs little to keep.
  RunSeries shrunk(int limit) {
    final out = RunSeries();
    for (final p in phases) {
      out.phases.add(PhaseBand(p.name, p.start, p.end));
    }
    if (times.length <= limit) {
      out.times.addAll(times);
      for (final e in _columns.entries) {
        out._columns[e.key] = [...e.value];
      }
      return out;
    }
    final groups = limit;
    for (var g = 0; g < groups; g++) {
      final from = g * times.length ~/ groups;
      final to = (g + 1) * times.length ~/ groups;
      if (to <= from) continue;
      var time = 0.0;
      for (var i = from; i < to; i++) {
        time += times[i];
      }
      out.times.add(time / (to - from));
      for (final e in _columns.entries) {
        double? merged;
        var count = 0;
        var bits = 0;
        for (var i = from; i < to; i++) {
          final v = e.value[i];
          if (v == null) continue;
          count++;
          if (isBitmask(e.key)) {
            bits |= v.toInt();
          } else {
            merged = (merged ?? 0) + v;
          }
        }
        final column = out._columns.putIfAbsent(e.key, () => <double?>[]);
        column.add(count == 0 ? null : (isBitmask(e.key) ? bits.toDouble() : merged! / count));
      }
    }
    return out;
  }

  Map<String, Object?> toJson() => {
    't': [for (final t in times) _round(t)],
    's': {
      for (final e in _columns.entries)
        if (e.value.any((v) => v != null)) e.key: _compact(e.value),
    },
    'p': [for (final p in phases) p.toJson()],
  };

  factory RunSeries.fromJson(Map<String, Object?> json) {
    final out = RunSeries();
    out.times.addAll([for (final t in json['t']! as List) (t as num).toDouble()]);
    for (final e in (json['s']! as Map).entries) {
      final value = e.value;
      out._columns[e.key as String] = value is List
          ? [for (final v in value) (v as num?)?.toDouble()]
          : List<double?>.filled(out.times.length, (value as num).toDouble(), growable: true);
    }
    for (final p in json['p']! as List) {
      out.phases.add(PhaseBand.fromJson((p as List).cast<Object?>()));
    }
    return out;
  }
}

/// A column as it is kept: one number when every tick has the same value, else the list.
Object _compact(List<double?> column) {
  final first = column.first;
  if (first != null && column.every((v) => v == first)) return _round(first);
  return [for (final v in column) v == null ? null : _round(v)];
}

/// [value] with two decimals, and a whole number as an integer (smaller to keep).
num _round(double value) {
  final rounded = double.parse(value.toStringAsFixed(2));
  return rounded == rounded.roundToDouble() ? rounded.round() : rounded;
}
