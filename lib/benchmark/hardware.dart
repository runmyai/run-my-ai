import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'amd_gpu.dart';
import 'nvml.dart';

// Reading the machine while a benchmark runs: what the operating system says in /proc and /sys, and the graphics
// cards through their driver's library. The readings are plain functions on text, so they can be tested without the
// machine; the reading itself happens on another isolate, twice a second, so the window never waits for a file.

/// One look at the machine: [values] by series id (`cpu.load`, `gpu.0.power` ...); a value the machine cannot tell is
/// missing or null.
class SystemSample {
  const SystemSample(this.seconds, this.values);

  /// Since the sampler started.
  final double seconds;
  final Map<String, double?> values;

  bool get onBattery => values['sys.battery'] == 1;
  double? operator [](String id) => values[id];
}

/// What the computer is, for the record of a run.
class HardwareInfo {
  const HardwareInfo({this.cpu = '', this.threads = 0, this.gpus = const [], this.ramGiB = 0, this.os = ''});

  final String cpu;
  final int threads;
  final List<String> gpus;
  final double ramGiB;
  final String os;

  Map<String, Object?> toJson() => {'cpu': cpu, 'threads': threads, 'gpus': gpus, 'ramGiB': ramGiB, 'os': os};

  factory HardwareInfo.fromJson(Map<String, Object?> json) => HardwareInfo(
    cpu: json['cpu'] as String? ?? '',
    threads: json['threads'] as int? ?? 0,
    gpus: ((json['gpus'] as List?) ?? const []).cast<String>(),
    ramGiB: (json['ramGiB'] as num?)?.toDouble() ?? 0,
    os: json['os'] as String? ?? '',
  );
}

// ---- Reading text -----------------------------------------------------------------------------------------------

/// The time spent by the CPU (or one core) as /proc/stat counts it, in jiffies.
class CpuLine {
  const CpuLine(this.busy, this.total);
  final int busy;
  final int total;
}

/// The whole CPU and each core from /proc/stat. Time spent for guests is already in user time and not added again.
({CpuLine all, List<CpuLine> cores}) parseCpuTimes(String stat) {
  CpuLine? all;
  final cores = <CpuLine>[];
  for (final line in stat.split('\n')) {
    final m = RegExp(r'^cpu(\d*)\s+(.*)$').firstMatch(line);
    if (m == null) continue;
    final f = [for (final v in m[2]!.trim().split(RegExp(r'\s+'))) int.tryParse(v) ?? 0];
    if (f.length < 5) continue;
    final total = f.take(8).fold(0, (a, b) => a + b);
    final idle = f[3] + f[4];
    final cpu = CpuLine(total - idle, total);
    if (m[1]!.isEmpty) {
      all = cpu;
    } else {
      cores.add(cpu);
    }
  }
  return (all: all ?? const CpuLine(0, 0), cores: cores);
}

/// The percentage of time a CPU (or core) was busy between two readings; null when no time passed.
double? busyPercent(CpuLine before, CpuLine after) {
  final total = after.total - before.total;
  return total <= 0 ? null : 100 * (after.busy - before.busy) / total;
}

/// The first line of /proc/stat as numbers.
List<int> parseCpuLine(String stat) =>
    [for (final v in stat.split('\n').first.trim().split(RegExp(r'\s+')).skip(1)) int.parse(v)];

/// Busy share of the CPU between two readings of /proc/stat's first line, in percent; null without a difference.
double? cpuBusyPercent(List<int> before, List<int> after) {
  int total(List<int> v) => v.take(8).fold(0, (a, b) => a + b);
  int idle(List<int> v) => v[3] + v[4];
  final all = total(after) - total(before);
  if (all <= 0) return null;
  return 100 * (all - (idle(after) - idle(before))) / all;
}

/// What /proc/meminfo says, in KiB.
class MemInfo {
  const MemInfo({
    required this.total,
    required this.available,
    this.cached = 0,
    this.buffers = 0,
    this.swapTotal = 0,
    this.swapFree = 0,
  });

  final int total;
  final int available;
  final int cached;
  final int buffers;
  final int swapTotal;
  final int swapFree;

  int get used => total - available;
  int get swapUsed => swapTotal - swapFree;
}

MemInfo? parseMemInfo(String text) {
  int? kb(String name) => int.tryParse(RegExp('^$name:\\s+(\\d+) kB', multiLine: true).firstMatch(text)?[1] ?? '');
  final total = kb('MemTotal');
  final available = kb('MemAvailable');
  if (total == null || available == null) return null;
  return MemInfo(
    total: total,
    available: available,
    cached: kb('Cached') ?? 0,
    buffers: kb('Buffers') ?? 0,
    swapTotal: kb('SwapTotal') ?? 0,
    swapFree: kb('SwapFree') ?? 0,
  );
}

/// Pages swapped in and out so far, from /proc/vmstat.
int parseSwapPages(String vmstat) {
  int pages(String name) => int.tryParse(RegExp('^$name (\\d+)', multiLine: true).firstMatch(vmstat)?[1] ?? '') ?? 0;
  return pages('pswpin') + pages('pswpout');
}

/// What the whole disks have read so far, from /proc/diskstats.
class DiskCounters {
  const DiskCounters({this.sectors = 0, this.reads = 0, this.ioMillis = 0, this.weightedMillis = 0});

  final int sectors;
  final int reads;

  /// Time with at least one request in flight, and the sum over requests of their time in flight.
  final int ioMillis;
  final int weightedMillis;
}

final _wholeDisk = RegExp(r'^(nvme\d+n\d+|sd[a-z]+|vd[a-z]+|mmcblk\d+)$');

DiskCounters parseDiskStats(String text) {
  var sectors = 0, reads = 0, io = 0, weighted = 0;
  for (final line in text.split('\n')) {
    final f = line.trim().split(RegExp(r'\s+'));
    if (f.length > 13 && _wholeDisk.hasMatch(f[2])) {
      reads += int.tryParse(f[3]) ?? 0;
      sectors += int.tryParse(f[5]) ?? 0;
      io += int.tryParse(f[12]) ?? 0;
      weighted += int.tryParse(f[13]) ?? 0;
    }
  }
  return DiskCounters(sectors: sectors, reads: reads, ioMillis: io, weightedMillis: weighted);
}

/// Sectors read so far by the whole disks in /proc/diskstats.
int parseSectorsRead(String diskstats) => parseDiskStats(diskstats).sectors;

/// User plus system time, in jiffies, of the process whose /proc/PID/stat is [stat], with its finished children.
int parseProcessJiffies(String stat) {
  final after = stat.substring(stat.lastIndexOf(')') + 1).trim().split(RegExp(r'\s+'));
  if (after.length < 15) return 0;
  return [for (final i in [11, 12, 13, 14]) int.tryParse(after[i]) ?? 0].fold(0, (a, b) => a + b);
}

/// A value of /proc/PID/status in KiB (`RssAnon`); 0 when it has none.
int parseStatusKiB(String status, String name) =>
    int.tryParse(RegExp('^$name:\\s+(\\d+) kB', multiLine: true).firstMatch(status)?[1] ?? '') ?? 0;

/// The data rate of a PCIe link in GB/s one way: [gigaTransfers] per second and lane (2.5 to 64) over [lanes] lanes.
double pcieGBps(double gigaTransfers, int lanes) {
  final perLane = switch (gigaTransfers) {
    <= 2.5 => 0.25,
    <= 5 => 0.5,
    <= 8 => 0.985,
    <= 16 => 1.969,
    <= 32 => 3.938,
    _ => 7.563,
  };
  return perLane * lanes;
}

/// The transfer rate in a sysfs link speed line ("16.0 GT/s PCIe"); null when there is none.
double? parseLinkSpeed(String text) => double.tryParse(RegExp(r'([\d.]+)\s*GT/s').firstMatch(text)?[1] ?? '');

/// The names of the bits set in a GPU's clock throttle reasons (NVML's list). The idle bit is not a slowdown.
List<String> throttleReasonNames(int mask) => [
  for (final r in _throttleReasons)
    if (mask & r.$1 != 0) r.$2,
];

const _throttleReasons = [
  (0x4, 'software power cap'),
  (0x8, 'hardware slowdown'),
  (0x20, 'software thermal slowdown'),
  (0x40, 'hardware thermal slowdown'),
  (0x80, 'power brake'),
  (0x2, 'clocks set by an application'),
  (0x10, 'sync boost'),
  (0x100, 'display clocks'),
];

/// The reasons that mean the card is held down below what it could do.
const heldDownReasons = 0x4 | 0x8 | 0x20 | 0x40 | 0x80;

/// Whether the machine runs on its battery, from its power supplies: it has a battery, and no outside supply is
/// connected. A laptop lists several outside supplies (one per USB-C port), most of them not connected at any time.
bool runningOnBattery(List<({String? type, String? online})> supplies) {
  final hasBattery = supplies.any((s) => s.type == 'Battery');
  final connected = supplies.any((s) => s.type != 'Battery' && s.online == '1');
  return hasBattery && !connected;
}

// ---- Reading files ----------------------------------------------------------------------------------------------

/// Where text comes from: the real files, or a test's.
abstract interface class FileSource {
  /// The text of the file; null when it cannot be read.
  String? read(String path);

  /// The names in the folder; empty when it cannot be read.
  List<String> list(String folder);
}

class DiskFiles implements FileSource {
  const DiskFiles();

  @override
  String? read(String path) {
    try {
      return File(path).readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  List<String> list(String folder) {
    try {
      return [for (final e in Directory(folder).listSync(followLinks: false)) e.path.split(Platform.pathSeparator).last];
    } on FileSystemException {
      return const [];
    }
  }
}

/// Reads every value the machine gives, one tick at a time; the rates come from the difference with the tick before.
class SystemReader {
  SystemReader(this.files, {this.gpu, int Function()? micros})
    : _micros = micros ?? (() => DateTime.now().microsecondsSinceEpoch);

  final FileSource files;
  final GpuSource? gpu;
  final int Function() _micros;

  var _tick = 0;
  int? _before;
  ({CpuLine all, List<CpuLine> cores})? _cpu;
  DiskCounters? _disk;
  int? _swapPages;
  int? _engineJiffies;
  int? _energy;
  List<int> _enginePids = const [];
  String? _packageTemperature;
  String? _packagePower;
  String? _ssdTemperature;
  var _hwmonLooked = false;
  double? _ssdLimit;
  var _limitsLooked = false;
  final _coreMax = <int, double?>{};

  static const _proc = '/proc';
  static const _sys = '/sys';

  /// One tick: the values at this moment.
  Map<String, double?> read() {
    final now = _micros();
    final seconds = _before == null ? 0.0 : (now - _before!) / 1e6;
    _before = now;
    final out = <String, double?>{};
    _cpuValues(out, seconds);
    _memoryValues(out, seconds);
    _diskValues(out, seconds);
    _packageValues(out, seconds);
    out['sys.battery'] = _onBattery() ? 1 : 0;
    out.addAll(gpu?.read() ?? const {});
    _tick++;
    return out;
  }

  /// The pids of the engine's processes (found by name now and then: the engine starts and stops with each run).
  List<int> _engines() {
    if (_tick % 4 != 0 && _enginePids.isNotEmpty) return _enginePids;
    _enginePids = [
      for (final name in files.list(_proc))
        if (int.tryParse(name) case final pid? when files.read('$_proc/$name/comm')?.trim() == 'llama-server') pid,
    ];
    return _enginePids;
  }

  void _cpuValues(Map<String, double?> out, double seconds) {
    final text = files.read('$_proc/stat');
    if (text == null) return;
    final now = parseCpuTimes(text);
    final before = _cpu;
    _cpu = now;

    var engine = 0;
    for (final pid in _engines()) {
      final stat = files.read('$_proc/$pid/stat');
      if (stat != null) engine += parseProcessJiffies(stat);
    }
    final engineBefore = _engineJiffies;
    _engineJiffies = engine;

    if (before != null) {
      out['cpu.load'] = busyPercent(before.all, now.all);
      final total = now.all.total - before.all.total;
      if (total > 0 && engineBefore != null) {
        // Everything busy that was not the engine: the share of the whole CPU other programs took.
        final other = (now.all.busy - before.all.busy) - (engine - engineBefore);
        out['cpu.other'] = (100 * other / total).clamp(0, 100).toDouble();
      }
      for (var i = 0; i < now.cores.length && i < before.cores.length; i++) {
        out['cpu.core.$i.load'] = busyPercent(before.cores[i], now.cores[i]);
      }
    }
    var sum = 0.0, count = 0;
    double? top;
    for (var i = 0; i < now.cores.length; i++) {
      final cur = files.read('$_sys/devices/system/cpu/cpu$i/cpufreq/scaling_cur_freq');
      final mhz = cur == null ? null : (double.tryParse(cur.trim()) ?? double.nan) / 1000;
      if (mhz == null || mhz.isNaN) continue;
      out['cpu.core.$i.mhz'] = mhz;
      final max = _coreMax.putIfAbsent(i, () {
        final text = files.read('$_sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq');
        final v = text == null ? null : double.tryParse(text.trim());
        return v == null ? null : v / 1000;
      });
      out['cpu.core.$i.mhzMax'] = max;
      sum += mhz;
      count++;
      if (max != null && (top == null || max > top)) top = max;
    }
    if (count > 0) {
      out['cpu.mhz'] = sum / count;
      out['cpu.mhzMax'] = top;
    }
  }

  void _memoryValues(Map<String, double?> out, double seconds) {
    final text = files.read('$_proc/meminfo');
    final mem = text == null ? null : parseMemInfo(text);
    if (mem == null) return;
    const gib = 1048576.0;
    var engine = 0;
    for (final pid in _enginePids) {
      final status = files.read('$_proc/$pid/status');
      if (status != null) engine += parseStatusKiB(status, 'RssAnon') + parseStatusKiB(status, 'RssShmem');
    }
    out['ram.total'] = mem.total / gib;
    out['ram.used'] = mem.used / gib;
    out['ram.engine'] = engine / gib;
    out['ram.other'] = (mem.used - engine).clamp(0, mem.total) / gib;
    out['ram.cache'] = (mem.cached + mem.buffers) / gib;
    out['ram.available'] = mem.available / gib;
    if (mem.swapTotal > 0) {
      out['ram.swap'] = mem.swapUsed / gib;
      out['ram.swapTotal'] = mem.swapTotal / gib;
    }
    final vm = files.read('$_proc/vmstat');
    if (vm != null) {
      final pages = parseSwapPages(vm);
      final before = _swapPages;
      _swapPages = pages;
      if (before != null && seconds > 0) out['ram.swapActivity'] = (pages - before) * 4096 / 1e6 / seconds;
    }
  }

  void _diskValues(Map<String, double?> out, double seconds) {
    final text = files.read('$_proc/diskstats');
    if (text == null) return;
    final now = parseDiskStats(text);
    final before = _disk;
    _disk = now;
    if (before != null && seconds > 0) {
      out['ssd.read'] = (now.sectors - before.sectors) * 512 / 1e9 / seconds;
      out['ssd.iops'] = (now.reads - before.reads) / seconds;
      out['ssd.queue'] = (now.weightedMillis - before.weightedMillis) / (seconds * 1000);
      out['ssd.busy'] = (100 * (now.ioMillis - before.ioMillis) / (seconds * 1000)).clamp(0, 100).toDouble();
    }
    if (!_limitsLooked) {
      _limitsLooked = true;
      for (final name in files.list('$_sys/class/nvme')) {
        final speed = files.read('$_sys/class/nvme/$name/device/current_link_speed');
        final width = files.read('$_sys/class/nvme/$name/device/current_link_width');
        final gts = speed == null ? null : parseLinkSpeed(speed);
        final lanes = width == null ? null : int.tryParse(width.trim());
        if (gts != null && lanes != null) {
          _ssdLimit = pcieGBps(gts, lanes);
          break;
        }
      }
    }
    out['ssd.readMax'] = _ssdLimit;
  }

  /// The package's temperature and power, and the drive's temperature, where the machine gives them.
  void _packageValues(Map<String, double?> out, double seconds) {
    if (!_hwmonLooked) {
      _hwmonLooked = true;
      for (final name in files.list('$_sys/class/hwmon')) {
        final dir = '$_sys/class/hwmon/$name';
        switch (files.read('$dir/name')?.trim()) {
          case 'k10temp' || 'coretemp' || 'zenpower':
            _packageTemperature ??= dir;
          case 'nvme':
            _ssdTemperature ??= dir;
          case 'amdgpu':
            // An APU's graphics part reports the power of the whole chip.
            if (files.read('$dir/power1_average') != null || files.read('$dir/power1_input') != null) _packagePower ??= dir;
        }
      }
    }
    double? milli(String? dir, String file) {
      final text = dir == null ? null : files.read('$dir/$file');
      final v = text == null ? null : double.tryParse(text.trim());
      return v == null ? null : v / 1000;
    }

    out['cpu.temp'] = milli(_packageTemperature, 'temp1_input');
    out['cpu.tempMax'] = milli(_packageTemperature, 'temp1_crit');
    out['ssd.temp'] = milli(_ssdTemperature, 'temp1_input');
    out['ssd.tempMax'] = milli(_ssdTemperature, 'temp1_crit');
    final energy = files.read('$_sys/class/powercap/intel-rapl:0/energy_uj');
    final joules = energy == null ? null : int.tryParse(energy.trim());
    if (joules != null) {
      final before = _energy;
      _energy = joules;
      if (before != null && seconds > 0 && joules >= before) out['cpu.power'] = (joules - before) / 1e6 / seconds;
      final cap = files.read('$_sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw');
      out['cpu.powerLimit'] = cap == null ? null : (double.tryParse(cap.trim()) ?? double.nan) / 1e6;
    } else if (_packagePower != null) {
      final dir = _packagePower!;
      final watts = milli(dir, files.read('$dir/power1_average') != null ? 'power1_average' : 'power1_input');
      out['cpu.power'] = watts == null ? null : watts / 1000;
      final cap = milli(dir, 'power1_cap');
      out['cpu.powerLimit'] = cap == null ? null : cap / 1000;
    }
  }

  bool _onBattery() {
    final supplies = [
      for (final name in files.list('$_sys/class/power_supply'))
        (
          type: files.read('$_sys/class/power_supply/$name/type')?.trim(),
          online: files.read('$_sys/class/power_supply/$name/online')?.trim(),
        ),
    ];
    return runningOnBattery(supplies);
  }

  /// What the computer is.
  HardwareInfo info() {
    final cpuInfo = files.read('$_proc/cpuinfo') ?? '';
    final model = RegExp(r'^model name\s*:\s*(.+)$', multiLine: true).firstMatch(cpuInfo)?[1]?.trim() ?? '';
    final mem = parseMemInfo(files.read('$_proc/meminfo') ?? '');
    final release = files.read('/etc/os-release') ?? '';
    final pretty = RegExp(r'^PRETTY_NAME="?([^"\n]*)"?', multiLine: true).firstMatch(release)?[1];
    final kernel = files.read('$_proc/sys/kernel/osrelease')?.trim();
    return HardwareInfo(
      cpu: model,
      threads: parseCpuTimes(files.read('$_proc/stat') ?? '').cores.length,
      gpus: gpu?.names ?? const [],
      ramGiB: mem == null ? 0 : mem.total / 1048576,
      os: [pretty ?? Platform.operatingSystem, if (kernel != null) 'kernel $kernel'].join(', '),
    );
  }
}

// ---- Looking twice a second --------------------------------------------------------------------------------------

/// Looks at the machine twice a second on its own isolate while a benchmark runs.
class HardwareMonitor {
  static const every = Duration(milliseconds: 500);

  final _samples = StreamController<SystemSample>.broadcast();
  SendPort? _control;
  ReceivePort? _port;
  HardwareInfo _info = const HardwareInfo();

  Stream<SystemSample> get samples => _samples.stream;

  /// What the computer is; known once [start] has returned.
  HardwareInfo get info => _info;

  Future<void> start() async {
    final port = _port = ReceivePort();
    final ready = Completer<void>();
    port.listen((message) {
      if (message is SystemSample) {
        if (!_samples.isClosed) _samples.add(message);
      } else if (message is List) {
        _control = message[0] as SendPort;
        _info = message[1] as HardwareInfo;
        if (!ready.isCompleted) ready.complete();
      }
    });
    await Isolate.spawn(_run, port.sendPort);
    await ready.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  }

  /// The next reading (about half a second away).
  Future<SystemSample> look() => samples.first;

  Future<void> stop() async {
    _control?.send('stop');
    _port?.close();
    await _samples.close();
  }
}

/// The sampler's isolate: reads every [HardwareMonitor.every] until told to stop.
void _run(SendPort out) {
  final control = ReceivePort();
  // The cards of every kind this computer has: NVIDIA's through its library, AMD's through sysfs.
  final nvidia = NvmlReader.open();
  final amd = AmdGpuReader.open(const DiskFiles(), firstIndex: nvidia?.names.length ?? 0);
  final cards = <GpuSource>[?nvidia, ?amd];
  final reader = SystemReader(const DiskFiles(), gpu: cards.isEmpty ? null : GpuSources(cards));
  final clock = Stopwatch()..start();
  out.send([control.sendPort, reader.info()]);
  late final Timer timer;
  timer = Timer.periodic(HardwareMonitor.every, (_) {
    out.send(SystemSample(clock.elapsedMicroseconds / 1e6, reader.read()));
  });
  control.listen((message) {
    if (message == 'stop') {
      timer.cancel();
      reader.gpu?.close();
      control.close();
    }
  });
}
