// Reading the machine: the parsers of /proc and /sys text, the reader that turns two ticks of files into values (with
// made-up files), and the graphics library's reading where one exists. Nothing here starts a model.
// Run: flutter test test/hardware_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/benchmark/hardware.dart';
import 'package:runmyai/benchmark/nvml.dart';

class _Files implements FileSource {
  final files = <String, String>{};

  @override
  String? read(String path) => files[path];

  @override
  List<String> list(String folder) => {
    for (final p in files.keys)
      if (p.startsWith('$folder/')) p.substring(folder.length + 1).split('/').first,
  }.toList();
}

class _Gpu implements GpuSource {
  @override
  List<String> get names => const ['Test card'];
  @override
  Map<String, double?> read() => {'gpu.0.load': 50, 'gpu.0.power': 100};
  @override
  void close() {}
}

void main() {
  group('parsing', () {
    test('the CPU and each core from /proc/stat', () {
      final t = parseCpuTimes('cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 50 0 50 400 0 0 0 0 0 0\ncpu1 50 0 50 400 0 0 0 0 0 0\nintr 1');
      expect(t.cores, hasLength(2));
      expect((t.all.busy, t.all.total), (200, 1000));
      final later = parseCpuTimes('cpu  200 0 200 1000 0 0 0 0 0 0\n');
      expect(busyPercent(t.all, later.all), 50);
      expect(busyPercent(t.all, t.all), isNull, reason: 'no time passed');
      expect(cpuBusyPercent(parseCpuLine('cpu  100 0 100 800 0 0 0 0 0 0'), parseCpuLine('cpu  150 0 150 900 0 0 0 0 0 0')), 50);
    });

    test('memory and swap', () {
      final m = parseMemInfo('MemTotal: 2097152 kB\nMemAvailable: 1048576 kB\nCached: 100 kB\nBuffers: 20 kB\nSwapTotal: 1000 kB\nSwapFree: 400 kB\n')!;
      expect((m.used, m.cached, m.buffers, m.swapUsed), (1048576, 100, 20, 600));
      expect(parseMemInfo('nothing'), isNull);
      expect(parseSwapPages('pgfault 5\npswpin 100\npswpout 150\n'), 250);
    });

    test('the whole disks of /proc/diskstats, not their partitions', () {
      const text = ' 259 0 nvme0n1 100 0 2000 5 0 0 0 0 0 100 150\n'
          ' 259 1 nvme0n1p1 5 0 40 0 0 0 0 0 0 1 1\n'
          ' 8 0 sda 1 0 10 0 0 0 0 0 0 2 3';
      final d = parseDiskStats(text);
      expect((d.sectors, d.reads, d.ioMillis, d.weightedMillis), (2010, 101, 102, 153));
      expect(parseSectorsRead(text), 2010);
    });

    test('a process: its jiffies (the name may hold spaces and brackets) and its memory', () {
      const stat = '42 (llama (x) server) S 1 1 1 0 -1 0 0 0 0 0 100 20 3 4 20 0 1 0 5';
      expect(parseProcessJiffies(stat), 127);
      expect(parseProcessJiffies('garbage'), 0);
      expect(parseStatusKiB('Name: x\nRssAnon:\t  1024 kB\nRssFile: 5 kB', 'RssAnon'), 1024);
      expect(parseStatusKiB('Name: x', 'RssAnon'), 0);
    });

    test('a PCIe link, and the reasons a card is slowed', () {
      expect(parseLinkSpeed('16.0 GT/s PCIe'), 16.0);
      expect(parseLinkSpeed('Unknown'), isNull);
      expect(pcieGBps(16, 4), closeTo(7.876, 0.001));
      expect(pcieGBps(8, 8), closeTo(7.88, 0.001));
      expect(throttleReasonNames(0x4 | 0x20), ['software power cap', 'software thermal slowdown']);
      expect(throttleReasonNames(0x1), isEmpty, reason: 'idle is not a slowdown');
      expect(heldDownReasons & 0x8, isNot(0));
    });

    test('on battery only when no outside supply is connected', () {
      const battery = (type: 'Battery', online: null);
      const usbOff = (type: 'USB', online: '0');
      const mainsOn = (type: 'Mains', online: '1');
      const mainsOff = (type: 'Mains', online: '0');
      expect(runningOnBattery(const [battery, mainsOn, usbOff]), isFalse, reason: 'charging, one USB-C port empty');
      expect(runningOnBattery(const [battery, mainsOff, usbOff]), isTrue);
      expect(runningOnBattery(const [mainsOff]), isFalse, reason: 'no battery at all');
    });
  });

  group('the reader', () {
    late _Files files;
    late int clock;
    late SystemReader reader;

    void tick1() {
      files.files.addAll({
        '/proc/stat': 'cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 50 0 50 400 0 0 0 0 0 0\ncpu1 50 0 50 400 0 0 0 0 0 0\n',
        '/proc/42/comm': 'llama-server\n',
        '/proc/42/stat': '42 (llama-server) S 1 1 1 0 -1 0 0 0 0 0 100 20 0 0 20 0 1 0 5',
        '/proc/42/status': 'RssAnon: 524288 kB\nRssShmem: 0 kB\n',
        '/proc/meminfo':
            'MemTotal: 2097152 kB\nMemAvailable: 1048576 kB\nCached: 524288 kB\nBuffers: 0 kB\nSwapTotal: 1048576 kB\nSwapFree: 1048576 kB\n',
        '/proc/vmstat': 'pswpin 0\npswpout 0\n',
        '/proc/diskstats': ' 259 0 nvme0n1 100 0 2000 0 0 0 0 0 0 100 100\n',
        '/sys/class/power_supply/BAT0/type': 'Battery\n',
        '/sys/class/power_supply/AC/type': 'Mains\n',
        '/sys/class/power_supply/AC/online': '0\n',
        '/sys/class/hwmon/hwmon3/name': 'k10temp\n',
        '/sys/class/hwmon/hwmon3/temp1_input': '55000\n',
        '/sys/class/hwmon/hwmon5/name': 'nvme\n',
        '/sys/class/hwmon/hwmon5/temp1_input': '41000\n',
        '/sys/class/hwmon/hwmon5/temp1_crit': '84800\n',
        '/sys/class/nvme/nvme0/device/current_link_speed': '16.0 GT/s PCIe\n',
        '/sys/class/nvme/nvme0/device/current_link_width': '4\n',
        '/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq': '2400000\n',
        '/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq': '5100000\n',
        '/sys/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq': '3600000\n',
        '/sys/devices/system/cpu/cpu1/cpufreq/cpuinfo_max_freq': '5100000\n',
      });
    }

    void tick2() {
      files.files.addAll({
        '/proc/stat': 'cpu  200 0 200 1000 0 0 0 0 0 0\ncpu0 100 0 100 500 0 0 0 0 0 0\ncpu1 100 0 100 500 0 0 0 0 0 0\n',
        '/proc/42/stat': '42 (llama-server) S 1 1 1 0 -1 0 0 0 0 0 150 40 0 0 20 0 1 0 5',
        '/proc/vmstat': 'pswpin 100\npswpout 150\n',
        '/proc/diskstats': ' 259 0 nvme0n1 600 0 12000 0 0 0 0 0 0 600 1600\n',
      });
    }

    setUp(() {
      files = _Files();
      clock = 0;
      reader = SystemReader(files, gpu: _Gpu(), micros: () => clock);
      tick1();
    });

    test('the first tick has the levels; the second adds the rates', () {
      final first = reader.read();
      expect(first['ram.total'], 2.0);
      expect(first['ram.used'], 1.0);
      expect(first['ram.engine'], 0.5);
      expect(first['ram.other'], 0.5);
      expect(first['ram.cache'], 0.5);
      expect(first['ram.swap'], 0.0);
      expect(first['cpu.load'], isNull, reason: 'a load needs two readings');
      expect(first['sys.battery'], 1);
      expect(first['cpu.temp'], 55);
      expect(first['ssd.temp'], 41);
      expect(first['ssd.tempMax'], 84.8);
      expect(first['ssd.readMax'], closeTo(7.876, 0.001));
      expect(first['cpu.core.0.mhz'], 2400);
      expect(first['cpu.core.0.mhzMax'], 5100);
      expect(first['cpu.mhz'], 3000);
      expect(first['gpu.0.load'], 50);

      clock = 1000000;
      tick2();
      final second = reader.read();
      expect(second['cpu.load'], 50);
      expect(second['cpu.core.0.load'], 50);
      expect(second['cpu.core.1.load'], 50);
      // 200 of the 400 jiffies were busy, 70 of those were the engine's.
      expect(second['cpu.other'], closeTo(32.5, 0.001));
      expect(second['ram.swapActivity'], closeTo(1.024, 0.0001));
      expect(second['ssd.read'], closeTo(0.00512, 0.000001));
      expect(second['ssd.iops'], 500);
      expect(second['ssd.queue'], 1.5);
      expect(second['ssd.busy'], 50);
    });

    test('a machine without a file just has no value for it', () {
      files.files.clear();
      final values = reader.read();
      expect(values['cpu.load'], isNull);
      expect(values['ram.total'], isNull);
      expect(values['sys.battery'], 0);
      expect(values['gpu.0.load'], 50, reason: 'the card is read apart from the files');
    });

    test('what the computer is', () {
      files.files['/proc/cpuinfo'] = 'processor : 0\nmodel name\t: Test CPU 9\n';
      files.files['/etc/os-release'] = 'NAME=Fedora\nPRETTY_NAME="Fedora Linux 44"\n';
      files.files['/proc/sys/kernel/osrelease'] = '7.2.7\n';
      final info = reader.info();
      expect((info.cpu, info.threads, info.ramGiB), ('Test CPU 9', 2, 2.0));
      expect(info.gpus, ['Test card']);
      expect(info.os, 'Fedora Linux 44, kernel 7.2.7');
      expect(HardwareInfo.fromJson(info.toJson()).cpu, 'Test CPU 9');
    });
  });

  test('the graphics library: read where there is a card, null where there is none', () {
    final nvml = NvmlReader.open();
    if (nvml == null) return; // No NVIDIA driver here: nothing to read, and that is the answer.
    try {
      expect(nvml.names, isNotEmpty);
      final v = nvml.read();
      expect(v['gpu.0.load'], inInclusiveRange(0, 100));
      expect(v['gpu.0.vramTotal'], greaterThan(0));
      expect(v['gpu.0.power'], greaterThanOrEqualTo(0));
      expect(v['gpu.0.clockMax'], greaterThan(0));
      expect(v['gpu.0.temp'], inInclusiveRange(0, 130));
    } finally {
      nvml.close();
    }
  });
}
