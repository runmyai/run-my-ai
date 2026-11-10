// AMD graphics cards read from sysfs: the clock file, the PCI names, and the reader with made-up files for an
// integrated card with everything, a card that exposes little, and cards that are not AMD's.
// Run: flutter test test/amd_gpu_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/benchmark/amd_gpu.dart';
import 'package:runmyai/benchmark/disturbance.dart';
import 'package:runmyai/benchmark/hardware.dart';
import 'package:runmyai/benchmark/nvml.dart';
import 'package:runmyai/benchmark/series.dart';

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

const _ids = '''
# A made-up piece of the PCI id list
10de  NVIDIA Corporation
\t2705  AD103 [GeForce RTX 4070 Ti SUPER]
1002  Advanced Micro Devices, Inc. [AMD/ATI]
\t150e  Strix [Radeon 880M / 890M]
\t\t1002 0001  A sub-entry that is not a device
\t73bf  Navi 21 [Radeon RX 6800/6800 XT / 6900 XT]
\t9999  Plain Name Without Brackets
''';

class _Nvidia implements GpuSource {
  @override
  List<String> get names => const ['NVIDIA card'];
  @override
  Map<String, double?> read() => {'gpu.0.load': 10};
  @override
  void close() {}
}

void main() {
  group('the clock file', () {
    test('the starred level is now, the highest level is the limit', () {
      final d = parseDpm('0: 400Mhz\n1: 1200Mhz *\n2: 2900Mhz\n');
      expect((d.current, d.max), (1200.0, 2900.0));
    });

    test('a file with no star or no levels says what it can', () {
      expect(parseDpm('0: 500Mhz\n1: 800Mhz\n').current, isNull);
      expect(parseDpm('0: 500Mhz\n1: 800Mhz\n').max, 800);
      final none = parseDpm('nothing here');
      expect((none.current, none.max), (null, null));
    });
  });

  group('names', () {
    test('a device is named from the PCI id list, by its marketing name when it has one', () {
      expect(pciDeviceName(_ids, '0x1002', '0x150e'), 'AMD Radeon 880M / 890M');
      expect(pciDeviceName(_ids, '0x1002', '150E'), 'AMD Radeon 880M / 890M', reason: 'the case of the digits does not matter');
      expect(pciDeviceName(_ids, '0x1002', '0x73bf'), 'AMD Radeon RX 6800/6800 XT / 6900 XT');
      expect(pciDeviceName(_ids, '0x1002', '0x9999'), 'AMD Plain Name Without Brackets');
      expect(pciDeviceName(_ids, '0x10de', '0x2705'), 'NVIDIA Corporation GeForce RTX 4070 Ti SUPER');
    });

    test('a device that is not listed has no name', () {
      expect(pciDeviceName(_ids, '0x1002', '0xffff'), isNull);
      expect(pciDeviceName(_ids, '0x1234', '0x150e'), isNull, reason: 'the device of another vendor');
      expect(pciDeviceName('', '0x1002', '0x150e'), isNull);
    });
  });

  group('the reader', () {
    late _Files files;

    void integrated(String card) {
      final d = '/sys/class/drm/$card/device';
      files.files.addAll({
        '$d/vendor': '0x1002\n',
        '$d/device': '0x150e\n',
        '$d/gpu_busy_percent': '37\n',
        '$d/mem_info_vram_used': '${2 * 1073741824}\n',
        '$d/mem_info_vram_total': '${4 * 1073741824}\n',
        '$d/pp_dpm_sclk': '0: 600Mhz\n1: 1800Mhz *\n2: 2900Mhz\n',
        '$d/hwmon/hwmon4/power1_average': '25000000\n',
        '$d/hwmon/hwmon4/power1_cap': '54000000\n',
        '$d/hwmon/hwmon4/power1_cap_max': '65000000\n',
        '$d/hwmon/hwmon4/temp1_input': '61000\n',
        '$d/hwmon/hwmon4/temp1_crit': '100000\n',
      });
    }

    setUp(() {
      files = _Files();
      files.files['/usr/share/hwdata/pci.ids'] = _ids;
    });

    test('a card gives load, memory, clock, power with its limit, and temperature', () {
      integrated('card1');
      final reader = AmdGpuReader.open(files)!;
      expect(reader.names, ['AMD Radeon 880M / 890M']);
      final v = reader.read();
      expect(v['gpu.0.load'], 37);
      expect((v['gpu.0.vram'], v['gpu.0.vramTotal']), (2.0, 4.0));
      expect((v['gpu.0.clock'], v['gpu.0.clockMax']), (1800.0, 2900.0));
      expect((v['gpu.0.power'], v['gpu.0.powerLimit'], v['gpu.0.powerMax']), (25.0, 54.0, 65.0));
      expect((v['gpu.0.temp'], v['gpu.0.tempMax']), (61.0, 100.0));
      expect(v['gpu.0.clockFollowsLoad'], 1);
    });

    test('power from power1_input stands in for power1_average', () {
      integrated('card1');
      final base = '/sys/class/drm/card1/device/hwmon/hwmon4';
      files.files.remove('$base/power1_average');
      files.files['$base/power1_input'] = '31000000\n';
      expect(AmdGpuReader.open(files)!.read()['gpu.0.power'], 31);
    });

    test('a card that exposes little gives little, and no file is an error', () {
      files.files['/sys/class/drm/card0/device/vendor'] = '0x1002\n';
      files.files['/sys/class/drm/card0/device/gpu_busy_percent'] = '5\n';
      final reader = AmdGpuReader.open(files)!;
      expect(reader.names, ['AMD graphics']);
      final v = reader.read();
      expect(v.keys, ['gpu.0.load']);
      expect(v['gpu.0.load'], 5);
    });

    test('a card with no listed name is named by its ids', () {
      files.files.addAll({
        '/sys/class/drm/card0/device/vendor': '0x1002\n',
        '/sys/class/drm/card0/device/device': '0xffff\n',
        '/sys/class/drm/card0/device/mem_info_vram_total': '1073741824\n',
      });
      expect(AmdGpuReader.open(files)!.names, ['AMD graphics (1002:ffff)']);
    });

    test('a name the card gives itself wins', () {
      integrated('card1');
      files.files['/sys/class/drm/card1/device/product_name'] = 'AMD Instinct MI300\n';
      expect(AmdGpuReader.open(files)!.names, ['AMD Instinct MI300']);
    });

    test('only AMD cards with the driver\'s files count; connectors and other makers are left out', () {
      integrated('card1');
      files.files['/sys/class/drm/card0/device/vendor'] = '0x10de\n';
      files.files['/sys/class/drm/card0/device/gpu_busy_percent'] = '9\n';
      files.files['/sys/class/drm/card2/device/vendor'] = '0x1002\n'; // an AMD card with another driver
      files.files['/sys/class/drm/card1-DP-1/device/vendor'] = '0x1002\n';
      files.files['/sys/class/drm/card1-DP-1/device/gpu_busy_percent'] = '1\n';
      final reader = AmdGpuReader.open(files)!;
      expect(reader.names, hasLength(1));
      expect(reader.read().keys.every((k) => k.startsWith('gpu.0.')), isTrue);
    });

    test('no AMD card at all gives no reader; a computer without sysfs too', () {
      expect(AmdGpuReader.open(files), isNull);
      files.files['/sys/class/drm/card0/device/vendor'] = '0x8086\n';
      expect(AmdGpuReader.open(files), isNull);
    });

    test('cards follow those another source gave first, each its own line', () {
      integrated('card1');
      integrated('card2');
      final amd = AmdGpuReader.open(files, firstIndex: 1)!;
      final all = GpuSources([_Nvidia(), amd]);
      expect(all.names, ['NVIDIA card', 'AMD Radeon 880M / 890M', 'AMD Radeon 880M / 890M']);
      final v = all.read();
      expect((v['gpu.0.load'], v['gpu.1.load'], v['gpu.2.load']), (10, 37, 37));
      all.close();
    });
  });

  test('a card whose clock follows its load is not called held down for a low clock, but its power limit is judged', () {
    RunSeries ticks(Map<String, double?> values) {
      final s = RunSeries();
      for (var i = 0; i < 10; i++) {
        s.add(i * 0.5, values);
      }
      return s;
    }

    final light = ticks({'gpu.0.load': 60, 'gpu.0.clock': 600, 'gpu.0.clockMax': 2900, 'gpu.0.clockFollowsLoad': 1});
    expect(disturbances(light), isEmpty);
    final capped = ticks({
      'gpu.0.load': 60,
      'gpu.0.clock': 2800,
      'gpu.0.clockMax': 2900,
      'gpu.0.powerLimit': 15,
      'gpu.0.powerMax': 65,
      'gpu.0.clockFollowsLoad': 1,
    });
    expect(disturbances(capped).single, contains('held down'));
  });
}
