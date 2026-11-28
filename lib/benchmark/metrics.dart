import 'hardware.dart';
import 'series.dart';

// The lines of the live view: which series each row of graphs draws, the limit each is shown against, and how a value
// is written. A value is always written with its limit where there is one ("112 of 140 W").

/// One line of a row: a series, and what it is measured against.
class MetricLine {
  const MetricLine(
    this.id,
    this.label,
    this.unit, {
    this.limit,
    this.fixedMax,
    this.digits = 0,
    this.bitmask = false,
    this.showLimit = true,
    this.second,
  });

  /// The series.
  final String id;
  final String label;
  final String unit;

  /// The series that holds its limit (the power limit, the highest clock ...), or a [fixedMax] such as 100 for a
  /// percentage. A line with neither is drawn against its own highest value so far.
  final String? limit;
  final double? fixedMax;
  final int digits;

  /// The value is a set of flag bits (the reasons a card is slowed): it is written out in words, not drawn.
  final bool bitmask;

  /// Whether to show "of [limit]" in the formatted text string when a limit is present.
  final bool showLimit;

  /// A second series drawn after this one in the same bar, against the same limit (the RAM's file cache after what the
  /// programs use).
  final String? second;

  /// [v] as it is shown, with its limit at tick [index] if the line has one and [showLimit] is true.
  String text(RunSeries series, int index) {
    final v = series.at(id, index);
    if (v == null) return '–';
    if (bitmask) {
      final names = throttleReasonNames(v.toInt());
      return names.isEmpty ? 'none' : names.join(', ');
    }
    final max = limitAt(series, index);
    return max == null || !showLimit ? '${formatNumber(v, digits)} $unit'.trim() : '${formatNumber(v, digits)} of ${formatNumber(max, digits)} $unit'.trim();
  }

  /// The limit at tick [index]; null when the line has none.
  double? limitAt(RunSeries series, int index) {
    if (fixedMax != null) return fixedMax;
    final v = limit == null ? null : series.at(limit!, index) ?? _lastKnown(series, limit!, index);
    return v != null && v > 0 ? v : null;
  }

  /// The top of the line's own scale over the run: its limit, or its highest value.
  double scale(RunSeries series) {
    final max = fixedMax ?? (limit == null ? null : series.peak(limit!));
    if (max != null && max > 0) return max;
    final peak = series.peak(id);
    return peak != null && peak > 0 ? peak : 1;
  }

  static double? _lastKnown(RunSeries series, String id, int index) {
    final column = series.series(id);
    if (column == null) return null;
    for (var i = (index < column.length ? index : column.length - 1); i >= 0; i--) {
      if (column[i] != null) return column[i];
    }
    return null;
  }
}

/// One row of the live view: a few lines that belong together.
class MetricRow {
  const MetricRow(this.id, this.title, this.lines, {this.note, this.subtitle});

  final String id;
  final String title;
  final List<MetricLine> lines;

  /// More about the row (a card's name).
  final String? subtitle;

  /// What to say when none of the row's series has a value ("not available").
  final String? note;

  /// Whether any line of the row has a value in [series].
  bool hasData(RunSeries series) => lines.any((l) => series.series(l.id)?.any((v) => v != null) ?? false);

  /// The row's first few values at tick [index], for its header.
  String summary(RunSeries series, int index, {int count = 3}) {
    final parts = <String>[];
    for (final line in lines) {
      if (line.bitmask || series.at(line.id, index) == null) continue;
      parts.add(line.text(series, index));
      if (parts.length == count) break;
    }
    return parts.isEmpty ? '–' : parts.join('  ·  ');
  }
}

/// A number with [digits] decimals and a space between thousands.
String formatNumber(double v, int digits) {
  final text = v.toStringAsFixed(digits);
  final dot = text.contains('.') ? text.indexOf('.') : text.length;
  final whole = text.substring(0, dot);
  if (whole.replaceAll('-', '').length < 5) return text;
  final grouped = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0 && whole[i - 1] != '-') grouped.write(' ');
    grouped.write(whole[i]);
  }
  return '$grouped${text.substring(dot)}';
}

/// The rows to show for [series]: speed, one row per graphics card found, CPU, RAM and SSD. A line has a limit only
/// where the PC reports one. [speed] is the speed line to show (`speed.prompt` while a prompt is read, `speed.tokens`
/// while a reply is written); none during the warm-ups.
List<MetricRow> metricRows(RunSeries series, {List<String> gpuNames = const [], String? speed}) {
  final cards = {
    for (final id in series.ids)
      if (RegExp(r'^gpu\.(\d+)\.').firstMatch(id) case final m?) int.parse(m[1]!),
  }.toList()..sort();
  return [
    MetricRow('speed', 'Speed', [
      if (speed == 'speed.prompt') const MetricLine('speed.prompt', 'Prompt processing', 'tokens/s'),
      if (speed == 'speed.tokens') const MetricLine('speed.tokens', 'Generation', 'tokens/s', digits: 1),
    ]),
    for (final n in cards)
      MetricRow('gpu.$n', cards.length > 1 ? 'GPU ${n + 1}' : 'GPU', subtitle: n < gpuNames.length ? gpuNames[n] : null, [
        MetricLine('gpu.$n.load', 'Load', '%', fixedMax: 100),
        // (The top is the highest power limit the card has been given on this PC, not the limit of the mode it is in.)
        MetricLine('gpu.$n.power', 'Power', 'W', limit: 'gpu.$n.powerTop'),
        MetricLine('gpu.$n.clock', 'Clock', 'MHz'),
        MetricLine('gpu.$n.temp', 'Temperature', '°C', limit: 'gpu.$n.tempMax'),
        MetricLine('gpu.$n.vram', 'Video memory', 'GB', limit: 'gpu.$n.vramTotal', digits: 1),
      ]),
    const MetricRow('cpu', 'CPU', [
      MetricLine('cpu.load', 'Load', '%', fixedMax: 100),
      MetricLine('cpu.mhz', 'Clock (average)', 'MHz'),
      MetricLine('cpu.power', 'Power', 'W', limit: 'cpu.powerLimit', digits: 1),
      MetricLine('cpu.temp', 'Temperature', '°C', limit: 'cpu.tempMax'),
    ]),
    const MetricRow('ram', 'RAM', [
      MetricLine('ram.used', 'In use / file cache', 'GB', limit: 'ram.total', digits: 1, second: 'ram.cache'),
      MetricLine('ram.swap', 'Swap', 'GB', limit: 'ram.swapTotal', digits: 1),
    ]),
    const MetricRow('ssd', 'SSD', [
      MetricLine('ssd.read', 'Read speed', 'GB/s', digits: 2),
      MetricLine('ssd.busy', 'Busy', '%', fixedMax: 100),
      MetricLine('ssd.iops', 'Reads', 'per second'),
      MetricLine('ssd.queue', 'Queue', 'requests', digits: 1),
      MetricLine('ssd.temp', 'Temperature', '°C', limit: 'ssd.tempMax'),
    ]),
  ];
}
