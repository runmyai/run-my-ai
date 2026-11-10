import 'hardware.dart';
import 'series.dart';

// Why a run cannot be compared fairly. Checked on every tick of the run, so the reasons show while it goes on and the
// result carries them: a run is never refused for them, only marked.

/// Other programs' average use of the CPU (share of the whole CPU) above which a run is marked.
const otherCpuAverage = 10.0;

/// Their use in a stretch that long (seconds) at this share counts too.
const otherCpuBurst = 30.0;
const otherCpuBurstSeconds = 6.0;

/// A card is working when its load is at least this (percent); only then are its clocks and power judged.
const gpuWorkingLoad = 30.0;

/// Working ticks needed before a card can be called held down.
const gpuMinimumTicks = 4;

/// Below this share of its power limit a working card is drawing far less than it may.
const gpuPowerShare = 0.6;

/// Below this share of its highest clock a working card is held down.
const gpuClockShare = 0.5;

/// A power limit under this share of what the card can be given is a limit set down.
const gpuLimitShare = 0.7;

/// What was going on before the run began, for the "busy when it started" rule: the first looks at the machine.
class StartState {
  const StartState({this.cpuPercent, this.gpuPercent, this.onBattery = false});

  /// The machine's CPU use and its busiest card's load, with no engine running.
  final double? cpuPercent;
  final double? gpuPercent;
  final bool onBattery;

  factory StartState.of(SystemSample sample) {
    double? busiest;
    for (final e in sample.values.entries) {
      if (e.key.endsWith('.load') && e.key.startsWith('gpu.') && e.value != null && (busiest == null || e.value! > busiest)) {
        busiest = e.value;
      }
    }
    return StartState(cpuPercent: sample['cpu.load'], gpuPercent: busiest, onBattery: sample.onBattery);
  }
}

/// The reasons the ticks of [series] (and the state before them) give; empty when nothing got in the way.
List<String> disturbances(RunSeries series, {StartState? before}) {
  final reasons = <String>[];
  final battery = series.series('sys.battery');
  if ((before?.onBattery ?? false) || (battery != null && battery.any((v) => v == 1))) {
    reasons.add('The computer was on battery.');
  }
  if ((before?.cpuPercent ?? 0) > 25 || (before?.gpuPercent ?? 0) > 30) {
    reasons.add('Other programs were busy when it started.');
  }
  final other = _otherPrograms(series);
  if (other != null) reasons.add(other);
  reasons.addAll(_gpuHeldDown(series));
  return reasons;
}

String? _otherPrograms(RunSeries series) {
  final column = series.series('cpu.other');
  if (column == null) return null;
  var sum = 0.0, count = 0;
  double top = 0;
  double? burstStart;
  var burst = false;
  for (var i = 0; i < column.length; i++) {
    final v = column[i];
    if (v == null) continue;
    sum += v;
    count++;
    if (v > top) top = v;
    if (v >= otherCpuBurst) {
      burstStart ??= series.times[i];
      if (series.times[i] - burstStart >= otherCpuBurstSeconds) burst = true;
    } else {
      burstStart = null;
    }
  }
  if (count == 0) return null;
  final average = sum / count;
  if (average <= otherCpuAverage && !burst) return null;
  return 'Other programs used the CPU (${average.round()} % on average, up to ${top.round()} %).';
}

Iterable<String> _gpuHeldDown(RunSeries series) sync* {
  final cards = {
    for (final id in series.ids)
      if (RegExp(r'^gpu\.(\d+)\.load$').firstMatch(id) case final m?) int.parse(m[1]!),
  }.toList()..sort();
  for (final n in cards) {
    final p = 'gpu.$n';
    final load = series.series('$p.load')!;
    final working = [
      for (var i = 0; i < load.length; i++)
        if ((load[i] ?? 0) >= gpuWorkingLoad) i,
    ];
    if (working.length < gpuMinimumTicks) continue;
    double? at(String id, int i) => series.at('$p.$id', i);
    final text = cards.length > 1 ? 'GPU ${n + 1}' : 'The GPU';

    // The power limit itself set far below what the card can be given.
    final limit = [for (final i in working) at('powerLimit', i)].whereType<double>();
    // (What the card can be given when the driver tells; else the highest limit it had during the run.)
    final most = series.peak('$p.powerMax') ?? series.peak('$p.powerLimit');
    if (limit.isNotEmpty && most != null) {
      final lowest = limit.reduce((a, b) => a < b ? a : b);
      if (lowest < most * gpuLimitShare) {
        yield '$text was held down: its power limit was set to ${lowest.round()} W (it was ${most.round()} W).';
        continue;
      }
    }

    // Drawing far less than its limit while the driver says it is slowing down.
    var low = 0, slowed = 0;
    for (final i in working) {
      final power = at('power', i), cap = at('powerLimit', i);
      if (power == null || cap == null || cap <= 0 || power >= cap * gpuPowerShare) continue;
      low++;
      if ((at('reasons', i)?.toInt() ?? 0) & heldDownReasons != 0) slowed++;
    }
    if (slowed >= gpuMinimumTicks && slowed * 2 >= working.length) {
      yield '$text was held down: it drew far less than its power limit while the driver slowed it ($low of ${working.length} busy moments).';
      continue;
    }

    // Clocks well under the highest it has (not for a card whose driver sets its clock by the load).
    if (series.peak('$p.clockFollowsLoad') == 1) continue;
    final clocks = [for (final i in working) at('clock', i)].whereType<double>().toList()..sort();
    final max = series.peak('$p.clockMax');
    if (clocks.length >= gpuMinimumTicks && max != null && max > 0) {
      final median = clocks[clocks.length ~/ 2];
      if (median < max * gpuClockShare) {
        yield '$text was held down: its clock was ${median.round()} of ${max.round()} MHz.';
      }
    }
  }
}

/// The moments a card was slowed by the driver (a heavy slowdown reason set while it was busy), as stretches in
/// seconds with the reason names: for the hardware summary.
List<({double from, double to, List<String> reasons})> slowdownMoments(RunSeries series) {
  final out = <({double from, double to, List<String> reasons})>[];
  for (final id in series.ids.where((id) => id.endsWith('.reasons')).toList()..sort()) {
    final column = series.series(id)!;
    double? from;
    var mask = 0;
    for (var i = 0; i < column.length; i++) {
      final bits = (column[i]?.toInt() ?? 0) & heldDownReasons;
      if (bits != 0) {
        from ??= series.times[i];
        mask |= bits;
      }
      if ((bits == 0 || i == column.length - 1) && from != null) {
        out.add((from: from, to: series.times[i], reasons: throttleReasonNames(mask)));
        from = null;
        mask = 0;
      }
    }
  }
  out.sort((a, b) => a.from.compareTo(b.from));
  return out;
}
