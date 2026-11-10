import 'hardware.dart';
import 'nvml.dart';

// AMD graphics cards (the amdgpu driver, discrete and integrated) read from sysfs on Linux: each file a card does not
// have is skipped, and a card gives only what it exposes.

/// The current clock and the highest level, in MHz, from a `pp_dpm_sclk` file: lines such as `1: 1200Mhz *`, the
/// current level marked with a star. A value is null when the file does not give it.
({double? current, double? max}) parseDpm(String text) {
  double? current, max;
  for (final line in text.split('\n')) {
    final m = RegExp(r'(\d+(?:\.\d+)?)\s*mhz\s*(\*)?', caseSensitive: false).firstMatch(line);
    if (m == null) continue;
    final mhz = double.parse(m[1]!);
    if (max == null || mhz > max) max = mhz;
    if (m[2] != null) current = mhz;
  }
  return (current: current, max: max);
}

/// The name of PCI device [device] of vendor [vendor] (four hex digits each, as in `0x1002`) in the text of a
/// `pci.ids` file; null when it is not listed. A name with a marketing name in brackets ("Strix [Radeon 880M / 890M]")
/// gives that part, with the vendor's short name before it.
String? pciDeviceName(String ids, String vendor, String device) {
  String hex(String v) => v.trim().toLowerCase().replaceFirst('0x', '').padLeft(4, '0');
  final vendorId = hex(vendor), deviceId = hex(device);
  var inVendor = false;
  String? vendorName;
  for (final line in ids.split('\n')) {
    if (line.isEmpty || line.startsWith('#')) continue;
    if (!line.startsWith('\t')) {
      inVendor = line.startsWith(vendorId) && line.length > 5 && line[4] == ' ';
      if (inVendor) vendorName = line.substring(5).trim();
      continue;
    }
    if (inVendor && !line.startsWith('\t\t') && line.startsWith('\t$deviceId ')) {
      final name = line.substring(6).trim();
      final bracket = RegExp(r'\[(.+)\]').firstMatch(name)?[1];
      final short = switch (vendorName) {
        final v? when v.contains('Advanced Micro Devices') || v.contains('AMD') => 'AMD',
        final v? => v,
        null => '',
      };
      return '$short ${bracket ?? name}'.trim();
    }
  }
  return null;
}

/// Reads the amdgpu cards under /sys/class/drm. Series ids are `gpu.<n>.<name>` from [firstIndex] on, so they follow the
/// cards another source (the NVIDIA driver's library) gave first.
class AmdGpuReader implements GpuSource {
  AmdGpuReader._(this._files, this._cards, this.names);

  /// The cards found; null when there is none.
  static AmdGpuReader? open(FileSource files, {int firstIndex = 0}) {
    const drm = '/sys/class/drm';
    final cards = <_Card>[];
    final names = <String>[];
    final ids = <String>[];
    final found = [for (final n in files.list(drm)) if (RegExp(r'^card\d+$').hasMatch(n)) n]..sort();
    for (final name in found) {
      final device = '$drm/$name/device';
      if (files.read('$device/vendor')?.trim() != '0x1002') continue;
      // (Another AMD driver's card has none of these.)
      if (files.read('$device/gpu_busy_percent') == null && files.read('$device/mem_info_vram_total') == null) continue;
      final hwmon = files.list('$device/hwmon').where((n) => n.startsWith('hwmon')).toList()..sort();
      cards.add(_Card('gpu.${firstIndex + cards.length}', device, hwmon.isEmpty ? null : '$device/hwmon/${hwmon.first}'));
      ids.add(files.read('$device/device')?.trim() ?? '');
      names.add(files.read('$device/product_name')?.trim() ?? '');
    }
    if (cards.isEmpty) return null;
    String? pci;
    for (var i = 0; i < names.length; i++) {
      if (names[i].isNotEmpty) continue;
      pci ??= _pciIds(files);
      final known = ids[i].isEmpty ? null : pciDeviceName(pci, '0x1002', ids[i]);
      names[i] = known ?? 'AMD graphics${ids[i].isEmpty ? '' : ' (1002:${ids[i].replaceFirst('0x', '')})'}';
    }
    return AmdGpuReader._(files, cards, names);
  }

  static String _pciIds(FileSource files) {
    for (final path in const [
      '/usr/share/hwdata/pci.ids',
      '/usr/share/misc/pci.ids',
      '/usr/share/pci.ids',
      '/var/lib/pciutils/pci.ids',
    ]) {
      final text = files.read(path);
      if (text != null) return text;
    }
    return '';
  }

  final FileSource _files;
  final List<_Card> _cards;

  @override
  final List<String> names;

  @override
  Map<String, double?> read() {
    final out = <String, double?>{};
    double? number(String path, [double scale = 1]) {
      final text = _files.read(path);
      final v = text == null ? null : double.tryParse(text.trim());
      return v == null ? null : v / scale;
    }

    void put(String id, double? v) {
      if (v != null) out[id] = v;
    }

    for (final c in _cards) {
      put('${c.id}.load', number('${c.device}/gpu_busy_percent'));
      put('${c.id}.vram', number('${c.device}/mem_info_vram_used', 1073741824));
      put('${c.id}.vramTotal', number('${c.device}/mem_info_vram_total', 1073741824));
      final dpm = _files.read('${c.device}/pp_dpm_sclk');
      final clocks = dpm == null ? null : parseDpm(dpm);
      if (clocks != null) {
        put('${c.id}.clock', clocks.current);
        put('${c.id}.clockMax', clocks.max);
        // The driver sets its clock by the load: a low clock under a light load is not a sign of being held down.
        if (clocks.current != null) out['${c.id}.clockFollowsLoad'] = 1;
      }
      final hwmon = c.hwmon;
      if (hwmon != null) {
        put('${c.id}.power', number('$hwmon/power1_average', 1e6) ?? number('$hwmon/power1_input', 1e6));
        put('${c.id}.powerLimit', number('$hwmon/power1_cap', 1e6));
        put('${c.id}.powerMax', number('$hwmon/power1_cap_max', 1e6));
        put('${c.id}.temp', number('$hwmon/temp1_input', 1000));
        put('${c.id}.tempMax', number('$hwmon/temp1_crit', 1000));
        if (clocks?.current == null) put('${c.id}.clock', number('$hwmon/freq1_input', 1e6));
      }
    }
    return out;
  }

  @override
  void close() {}
}

class _Card {
  const _Card(this.id, this.device, this.hwmon);

  /// `gpu.<n>`, the sysfs folder of the device, and its hwmon folder (null when it has none).
  final String id;
  final String device;
  final String? hwmon;
}

/// Several sources of graphics cards as one: the names in order, the readings together.
class GpuSources implements GpuSource {
  GpuSources(this._sources);

  final List<GpuSource> _sources;

  @override
  List<String> get names => [for (final s in _sources) ...s.names];

  @override
  Map<String, double?> read() => {for (final s in _sources) ...s.read()};

  @override
  void close() {
    for (final s in _sources) {
      s.close();
    }
  }
}
