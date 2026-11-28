import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'hardware.dart';

/// Where the graphics cards' readings come from: one value map per tick, series ids `gpu.<n>.<name>`.
abstract interface class GpuSource {
  /// The cards' names, in the order of their numbers.
  List<String> get names;

  Map<String, double?> read();

  void close();
}

final class _Utilization extends Struct {
  @Uint32()
  external int gpu;
  @Uint32()
  external int memory;
}

final class _Memory extends Struct {
  @Uint64()
  external int total;
  @Uint64()
  external int free;
  @Uint64()
  external int used;
}

typedef _Query = int Function(Pointer<Void>, Pointer<Uint32>);
typedef _QueryNative = Int32 Function(Pointer<Void>, Pointer<Uint32>);
typedef _QueryAt = int Function(Pointer<Void>, int, Pointer<Uint32>);
typedef _QueryAtNative = Int32 Function(Pointer<Void>, Int32, Pointer<Uint32>);

/// The NVIDIA driver's management library (libnvidia-ml), opened at run time. Nothing is installed or started: when
/// the library is not there, or the driver does not answer, [open] returns null and the cards have no readings.
class NvmlReader implements GpuSource {
  NvmlReader._(this._lib, this._devices, this.names) {
    for (final device in _devices) {
      _links.add(_link(device));
    }
  }

  /// The library, or null on a computer without it.
  static NvmlReader? open() {
    try {
      final lib = _load();
      if (lib == null) return null;
      final init = lib.lookupFunction<Int32 Function(), int Function()>('nvmlInit_v2');
      if (init() != 0) return null;
      final count = calloc<Uint32>();
      final devices = <Pointer<Void>>[];
      final names = <String>[];
      try {
        final getCount = lib.lookupFunction<_QueryNativeNoDevice, _QueryNoDevice>('nvmlDeviceGetCount_v2');
        if (getCount(count) != 0) return null;
        final handle = lib.lookupFunction<
          Int32 Function(Uint32, Pointer<Pointer<Void>>),
          int Function(int, Pointer<Pointer<Void>>)
        >('nvmlDeviceGetHandleByIndex_v2');
        final name = lib.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Utf8>, Uint32),
          int Function(Pointer<Void>, Pointer<Utf8>, int)
        >('nvmlDeviceGetName');
        for (var i = 0; i < count.value; i++) {
          final slot = calloc<Pointer<Void>>();
          final text = calloc<Uint8>(96).cast<Utf8>();
          try {
            if (handle(i, slot) != 0) continue;
            devices.add(slot.value);
            names.add(name(slot.value, text, 96) == 0 ? text.toDartString() : 'GPU $i');
          } finally {
            calloc.free(slot);
            calloc.free(text);
          }
        }
      } finally {
        calloc.free(count);
      }
      return devices.isEmpty ? null : NvmlReader._(lib, devices, names);
    } on Object {
      // A library that is missing, too old or not answering: no readings from it.
      return null;
    }
  }

  static DynamicLibrary? _load() {
    final names = Platform.isWindows
        ? ['nvml.dll', r'C:\Program Files\NVIDIA Corporation\NVSMI\nvml.dll']
        : Platform.isLinux
        ? ['libnvidia-ml.so.1', 'libnvidia-ml.so']
        : const <String>[];
    for (final name in names) {
      try {
        return DynamicLibrary.open(name);
      } on ArgumentError {
        continue;
      }
    }
    return null;
  }

  final DynamicLibrary _lib;
  final List<Pointer<Void>> _devices;
  final _links = <({double? gts, int? lanes})>[];

  @override
  final List<String> names;

  // The functions are looked up when first used, so one the driver lacks costs only its own reading.
  final _plain = <String, _Query?>{};
  final _withKind = <String, _QueryAt?>{};

  _Query? _plainFunction(String name) => _plain.putIfAbsent(name, () {
    try {
      return _lib.lookupFunction<_QueryNative, _Query>(name);
    } on ArgumentError {
      return null;
    }
  });

  _QueryAt? _kindFunction(String name) => _withKind.putIfAbsent(name, () {
    try {
      return _lib.lookupFunction<_QueryAtNative, _QueryAt>(name);
    } on ArgumentError {
      return null;
    }
  });

  /// One number of one card by a function of the shape `f(device, out)` (or `f(device, kind, out)`); null when it
  /// fails.
  int? _get(String name, Pointer<Void> device, [int? kind]) {
    final out = calloc<Uint32>();
    try {
      final int result;
      if (kind == null) {
        final f = _plainFunction(name);
        if (f == null) return null;
        result = f(device, out);
      } else {
        final f = _kindFunction(name);
        if (f == null) return null;
        result = f(device, kind, out);
      }
      return result == 0 ? out.value : null;
    } finally {
      calloc.free(out);
    }
  }

  /// The most power the driver lets the card be given, in watts.
  double? _powerMax(Pointer<Void> device) {
    final least = calloc<Uint32>();
    final most = calloc<Uint32>();
    try {
      final f = _lib.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint32>, Pointer<Uint32>),
        int Function(Pointer<Void>, Pointer<Uint32>, Pointer<Uint32>)
      >('nvmlDeviceGetPowerManagementLimitConstraints');
      return f(device, least, most) == 0 ? most.value / 1000 : null;
    } on ArgumentError {
      return null;
    } finally {
      calloc.free(least);
      calloc.free(most);
    }
  }

  ({double? gts, int? lanes}) _link(Pointer<Void> device) {
    final generation = _get('nvmlDeviceGetCurrPcieLinkGeneration', device);
    final width = _get('nvmlDeviceGetCurrPcieLinkWidth', device);
    final gts = switch (generation) {
      1 => 2.5,
      2 => 5.0,
      3 => 8.0,
      4 => 16.0,
      5 => 32.0,
      6 => 64.0,
      _ => null,
    };
    return (gts: gts, lanes: width);
  }

  @override
  Map<String, double?> read() {
    final out = <String, double?>{};
    for (var i = 0; i < _devices.length; i++) {
      final d = _devices[i];
      final p = 'gpu.$i';
      double? scaled(int? v, double by) => v == null ? null : v / by;
      final util = calloc<_Utilization>();
      final mem = calloc<_Memory>();
      final reasons = calloc<Uint64>();
      try {
        final getUtil = _lib.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<_Utilization>),
          int Function(Pointer<Void>, Pointer<_Utilization>)
        >('nvmlDeviceGetUtilizationRates');
        out['$p.load'] = getUtil(d, util) == 0 ? util.ref.gpu.toDouble() : null;
        final getMem = _lib.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<_Memory>),
          int Function(Pointer<Void>, Pointer<_Memory>)
        >('nvmlDeviceGetMemoryInfo');
        if (getMem(d, mem) == 0) {
          out['$p.vram'] = mem.ref.used / 1073741824;
          out['$p.vramTotal'] = mem.ref.total / 1073741824;
        }
        // The throttle reasons' function was renamed in newer drivers; either name works.
        for (final name in const ['nvmlDeviceGetCurrentClocksEventReasons', 'nvmlDeviceGetCurrentClocksThrottleReasons']) {
          try {
            final getReasons = _lib.lookupFunction<
              Int32 Function(Pointer<Void>, Pointer<Uint64>),
              int Function(Pointer<Void>, Pointer<Uint64>)
            >(name);
            if (getReasons(d, reasons) == 0) out['$p.reasons'] = reasons.value.toDouble();
            break;
          } on ArgumentError {
            continue;
          }
        }
      } finally {
        calloc.free(util);
        calloc.free(mem);
        calloc.free(reasons);
      }
      out['$p.power'] = scaled(_get('nvmlDeviceGetPowerUsage', d), 1000);
      out['$p.powerLimit'] = scaled(_get('nvmlDeviceGetEnforcedPowerLimit', d), 1000);
      out['$p.powerMax'] = _powerMax(d);
      out['$p.clock'] = _get('nvmlDeviceGetClockInfo', d, 0)?.toDouble();
      out['$p.clockMax'] = _get('nvmlDeviceGetMaxClockInfo', d, 0)?.toDouble();
      out['$p.temp'] = _get('nvmlDeviceGetTemperature', d, 0)?.toDouble();
      // The temperature the card aims to stay under (NVML_TEMPERATURE_THRESHOLD_GPS_CURR); the slowdown point is kept
      // for the record.
      out['$p.tempMax'] = _get('nvmlDeviceGetTemperatureThreshold', d, 7)?.toDouble();
      out['$p.tempSlowdown'] = _get('nvmlDeviceGetTemperatureThreshold', d, 1)?.toDouble();
      final tx = _get('nvmlDeviceGetPcieThroughput', d, 0);
      final rx = _get('nvmlDeviceGetPcieThroughput', d, 1);
      // (The driver gives KB/s.)
      out['$p.pcieTx'] = scaled(tx, 1000);
      out['$p.pcieRx'] = scaled(rx, 1000);
      final link = _links[i];
      out['$p.pcieMax'] = link.gts == null || link.lanes == null ? null : pcieGBps(link.gts!, link.lanes!) * 1000;
    }
    return out;
  }

  @override
  void close() {
    try {
      _lib.lookupFunction<Int32 Function(), int Function()>('nvmlShutdown')();
    } on Object {
      // Nothing more to do with it.
    }
  }
}

typedef _QueryNoDevice = int Function(Pointer<Uint32>);
typedef _QueryNativeNoDevice = Int32 Function(Pointer<Uint32>);
