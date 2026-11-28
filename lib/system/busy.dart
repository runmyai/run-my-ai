import 'dart:async';
import 'dart:io';

import 'win32_busy.dart';

/// Other programs using more than this many cores' worth of CPU time count as busy. Measured with the autotuner under
/// a known load: with 0.4 of a core of background work its picks stay the same run after run; with one more core kept
/// busy its reply-thread count already changes. Counted in cores, so it means the same on a PC with 4 cores and with 32.
const busyCores = 1.0;

/// More than this many bytes a second read or written on the model's drive by other programs counts as busy: the
/// autotuner's SSD reader count starts to change from about 50 MB/s of other traffic.
const busyDiskBytesPerSecond = 40e6;

/// The CPU time of the whole PC from /proc/stat's first line, in clock ticks: all of it, and the part spent idle (idle +
/// waiting for disks). Guest time is left out: it is already counted in user time.
({int total, int idle})? cpuTimes(String procStat) {
  final line = procStat.split('\n').firstWhere((l) => l.startsWith('cpu '), orElse: () => '');
  final f = line.split(RegExp(r'\s+')).skip(1).map(int.tryParse).toList();
  if (f.length < 5 || f.take(5).contains(null)) return null;
  final total = f.take(8).fold(0, (a, n) => a + (n ?? 0));
  return (total: total, idle: f[3]! + f[4]!);
}

/// A process's own CPU time from `/proc/<pid>/stat`, in clock ticks (user + system; its threads are counted in it).
int? processCpu(String pidStat) {
  // The program's name (in brackets) may hold spaces and brackets itself: the fields are counted after the last one.
  final f = pidStat.substring(pidStat.lastIndexOf(')') + 1).trim().split(RegExp(r'\s+'));
  if (f.length < 13) return null;
  final user = int.tryParse(f[11]), system = int.tryParse(f[12]);
  return user == null || system == null ? null : user + system;
}

/// The bytes read and written on drive [name] so far, from /proc/diskstats (its counts are in 512-byte sectors).
int? diskBytes(String diskstats, String name) {
  for (final line in diskstats.split('\n')) {
    final f = line.trim().split(RegExp(r'\s+'));
    if (f.length < 10 || f[2] != name) continue;
    final read = int.tryParse(f[5]), written = int.tryParse(f[9]);
    return read == null || written == null ? null : (read + written) * 512;
  }
  return null;
}

/// The bytes a process made the drives read for it, from `/proc/<pid>/io`.
int? readBytes(String procIo) {
  final m = RegExp(r'^read_bytes:\s*(\d+)', multiLine: true).firstMatch(procIo);
  return m == null ? null : int.parse(m[1]!);
}

/// The device mounted where [path] is (the mount point that is the longest start of it), from /proc/self/mountinfo.
String? mountSource(String mountinfo, String path) {
  String? best;
  var bestLength = -1;
  for (final line in mountinfo.split('\n')) {
    final halves = line.split(' - ');
    if (halves.length < 2) continue;
    final f = halves[0].split(' '), g = halves[1].split(' ');
    if (f.length < 5 || g.length < 2) continue;
    // Spaces and other odd characters in a mount point are written as octal escapes (\040).
    final point = f[4].replaceAllMapped(RegExp(r'\\([0-7]{3})'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)));
    final inside = point == '/' || path == point || path.startsWith('$point/');
    if (inside && point.length > bestLength) {
      best = g[1];
      bestLength = point.length;
    }
  }
  return best;
}

/// One look at the counters: the PC's CPU time over all its processors ([total], and the [idle] part of it), the
/// autotuner's own CPU time ([own], in the same unit), the drive's bytes and the autotuner's own read bytes (each null
/// when it could not be read).
typedef BusySample = ({Duration at, int total, int idle, int own, int? disk, int? ownRead});

/// How busy other programs kept the PC between [first] and [last]: the cores' worth of CPU time they used (on a PC
/// with [processors] processors) and their bytes a second on the drive, the autotuner's own part taken out of both.
({double cores, double? diskBytesPerSecond, bool busy}) busyBetween(
  BusySample first,
  BusySample last, {
  required int processors,
}) {
  final total = last.total - first.total;
  final used = total - (last.idle - first.idle);
  final cores = total <= 0 ? 0.0 : ((used - (last.own - first.own)) / total).clamp(0.0, 1.0) * processors;
  final seconds = (last.at - first.at).inMicroseconds / 1e6;
  double? disk;
  if (seconds > 0 && first.disk != null && last.disk != null) {
    final own = first.ownRead != null && last.ownRead != null ? last.ownRead! - first.ownRead! : 0;
    disk = (last.disk! - first.disk! - own).clamp(0, 1 << 62) / seconds;
  }
  return (cores: cores, diskBytesPerSecond: disk, busy: cores > busyCores || (disk ?? 0) > busyDiskBytesPerSecond);
}

/// Watches how busy other programs keep the PC while the process [pid] (the autotuner) runs: the counters are read
/// every quarter second while it can be seen, and [stop] compares the first look with the last. On Linux (/proc) and
/// Windows (the system's own counters); on other systems [start] gives null and the result counts as measured on a
/// quiet PC.
class BusyMeter {
  BusyMeter._(this._pid, this._drive, [this._win32]) {
    _first = _look();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _last = _look() ?? _last);
  }

  /// Starts watching the process [pid]; [modelPath]: the file it reads, whose drive is watched.
  static BusyMeter? start(int pid, String modelPath) {
    if (Platform.isLinux) return BusyMeter._(pid, _driveOf(modelPath));
    if (Platform.isWindows) {
      final counters = Win32BusyCounters.open(pid, modelPath);
      return counters == null ? null : BusyMeter._(pid, null, counters);
    }
    return null;
  }

  final int _pid;
  final String? _drive;
  final Win32BusyCounters? _win32;
  final _clock = Stopwatch()..start();
  late final Timer _timer;
  BusySample? _first, _last;

  /// Whether other programs kept the PC busy; null when it could not be told (the process ended too soon).
  bool? stop() {
    _timer.cancel();
    _win32?.close();
    final first = _first, last = _last;
    if (first == null || last == null) return null;
    return busyBetween(first, last, processors: Platform.numberOfProcessors).busy;
  }

  BusySample? _look() {
    final win32 = _win32;
    if (win32 == null) return _sample();
    final c = win32.read();
    return c == null
        ? null
        : (at: _clock.elapsed, total: c.total, idle: c.idle, own: c.own, disk: c.disk, ownRead: c.ownRead);
  }

  BusySample? _sample() {
    try {
      final cpu = cpuTimes(File('/proc/stat').readAsStringSync());
      final own = processCpu(File('/proc/$_pid/stat').readAsStringSync());
      if (cpu == null || own == null) return null;
      final drive = _drive;
      int? ownRead;
      try {
        ownRead = readBytes(File('/proc/$_pid/io').readAsStringSync());
      } on FileSystemException {
        ownRead = null;
      }
      return (
        at: _clock.elapsed,
        total: cpu.total,
        idle: cpu.idle,
        own: own,
        disk: drive == null ? null : diskBytes(File('/proc/diskstats').readAsStringSync(), drive),
        ownRead: ownRead,
      );
    } on FileSystemException {
      return null;   // the process has ended
    }
  }

  /// The drive (the whole disk, not its partition) that holds [path], as /proc/diskstats names it; null when unknown.
  static String? _driveOf(String path) {
    try {
      final source = mountSource(File('/proc/self/mountinfo').readAsStringSync(), File(path).absolute.path);
      if (source == null || !source.startsWith('/dev/')) return null;
      // /dev/mapper/... names are links to /dev/dm-N
      final name = File(source).resolveSymbolicLinksSync().split('/').last;
      final block = Directory('/sys/class/block/$name');
      if (!block.existsSync()) return null;
      if (!File('${block.path}/partition').existsSync()) return name;
      return block.resolveSymbolicLinksSync().split('/').reversed.elementAt(1);
    } on FileSystemException {
      return null;
    }
  }
}
