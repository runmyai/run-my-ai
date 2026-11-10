import 'benchmark.dart';
import 'disturbance.dart';
import 'metrics.dart';
import 'series.dart';

// Words for what a finished run holds: where a word fell on the graphs' time axis, the hardware over the run, and the
// ending of the reply.

/// When the reply began, in seconds on the run's time axis; null for a run kept without graphs.
double? replyStartSeconds(BenchmarkResult run) =>
    run.series?.phases.where((p) => p.name == PhaseBand.reply).firstOrNull?.start;

/// When word [index] of the reply was written on the graphs' time axis (the reply's start and the times of the words
/// before it, as the engine counted them); null when the run has no graphs or no such word.
double? wordTimeSeconds(BenchmarkResult run, int index) {
  final start = replyStartSeconds(run);
  final words = run.words;
  if (start == null || index < 0 || index >= words.length) return null;
  var millis = 0.0;
  for (var i = 0; i <= index; i++) {
    millis += words[i];
  }
  return start + millis / 1000;
}

/// The word that was being written at [seconds] of the run's time axis; null when there are none.
int? wordAtSeconds(BenchmarkResult run, double seconds) {
  final start = replyStartSeconds(run);
  final words = run.words;
  if (start == null || words.isEmpty || seconds < start) return null;
  var millis = (seconds - start) * 1000;
  for (var i = 0; i < words.length; i++) {
    millis -= words[i];
    if (millis <= 0) return i;
  }
  return words.length - 1;
}

/// How a reply ended, in words.
String stopReasonText(String? reason) => switch (reason) {
  'stop' => 'The model stopped by itself.',
  'length' => 'It reached the longest reply allowed.',
  null => 'Not recorded.',
  final other => other,
};

/// A size as "70.1 GB".
String formatBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  return '${v.toStringAsFixed(u < 2 ? 0 : 1)} ${units[u]}';
}

/// The context length of a run as "65,536 tokens".
String formatTokens(int n) => '${formatNumber(n.toDouble(), 0)} tokens';

/// One line about a part of the hardware over the run.
typedef HardwareFact = ({String label, String text});

/// The averages and peaks of the machine over the run, and the moments a card was slowed.
List<HardwareFact> hardwareFacts(RunSeries series) {
  String range(String id, int digits, String unit, {String? limit}) {
    final avg = series.average(id), peak = series.peak(id);
    if (avg == null || peak == null) return '';
    final max = limit == null ? null : series.peak(limit);
    final peakText = max == null ? formatNumber(peak, digits) : '${formatNumber(peak, digits)} of ${formatNumber(max, digits)}';
    return 'average ${formatNumber(avg, digits)}, highest $peakText $unit';
  }

  String peakOnly(String id, int digits, String unit, {String? limit}) {
    final peak = series.peak(id);
    if (peak == null) return '';
    final max = limit == null ? null : series.peak(limit);
    return 'highest ${formatNumber(peak, digits)}${max == null ? '' : ' of ${formatNumber(max, digits)}'} $unit';
  }

  final facts = <HardwareFact>[];
  void add(String label, List<(String, String)> parts) {
    final text = [for (final (name, value) in parts) if (value.isNotEmpty) '$name: $value'].join('\n');
    if (text.isNotEmpty) facts.add((label: label, text: text));
  }

  final cards = {
    for (final id in series.ids)
      if (RegExp(r'^gpu\.(\d+)\.load$').firstMatch(id) case final m?) int.parse(m[1]!),
  }.toList()..sort();
  for (final n in cards) {
    final p = 'gpu.$n';
    add(cards.length > 1 ? 'GPU ${n + 1}' : 'GPU', [
      ('Load', range('$p.load', 0, '%')),
      ('Power', range('$p.power', 0, 'W', limit: '$p.powerLimit')),
      ('Clock', range('$p.clock', 0, 'MHz', limit: '$p.clockMax')),
      ('Temperature', peakOnly('$p.temp', 0, '°C', limit: '$p.tempMax')),
      ('Video memory', peakOnly('$p.vram', 1, 'GB', limit: '$p.vramTotal')),
      ('PCIe traffic', peakOnly('$p.pcieRx', 0, 'MB/s received', limit: '$p.pcieMax')),
    ]);
  }
  add('CPU', [
    ('Load', range('cpu.load', 0, '%')),
    ('Other programs', range('cpu.other', 0, '%')),
    ('Clock', range('cpu.mhz', 0, 'MHz', limit: 'cpu.mhzMax')),
    ('Package power', range('cpu.power', 1, 'W', limit: 'cpu.powerLimit')),
    ('Temperature', peakOnly('cpu.temp', 0, '°C')),
  ]);
  add('RAM', [
    ('Used', peakOnly('ram.used', 1, 'GB', limit: 'ram.total')),
    ('Engine', peakOnly('ram.engine', 1, 'GB')),
    ('Swap', peakOnly('ram.swap', 1, 'GB', limit: 'ram.swapTotal')),
    ('Swap activity', peakOnly('ram.swapActivity', 1, 'MB/s')),
  ]);
  add('SSD', [
    ('Read speed', range('ssd.read', 2, 'GB/s', limit: 'ssd.readMax')),
    ('Busy', range('ssd.busy', 0, '%')),
    ('Temperature', peakOnly('ssd.temp', 0, '°C')),
  ]);
  final slow = slowdownMoments(series);
  add('Slowdowns', [
    (
      'GPU slowed by the driver',
      slow.isEmpty
          ? 'none'
          : [for (final m in slow) '${_clock(m.from)} to ${_clock(m.to)}: ${m.reasons.join(', ')}'].join('\n'),
    ),
  ]);
  return facts;
}

String _clock(double seconds) {
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
