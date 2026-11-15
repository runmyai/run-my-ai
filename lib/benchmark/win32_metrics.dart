import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _MemoryStatusEx extends Struct {
  @Uint32()
  external int dwLength;
  @Uint32()
  external int dwMemoryLoad;
  @Uint64()
  external int ullTotalPhys;
  @Uint64()
  external int ullAvailPhys;
  @Uint64()
  external int ullTotalPageFile;
  @Uint64()
  external int ullAvailPageFile;
  @Uint64()
  external int ullTotalVirtual;
  @Uint64()
  external int ullAvailVirtual;
  @Uint64()
  external int ullAvailExtendedVirtual;
}

final class _SystemPowerStatus extends Struct {
  @Uint8()
  external int acLineStatus;
  @Uint8()
  external int batteryFlag;
  @Uint8()
  external int batteryLifePercent;
  @Uint8()
  external int systemStatusFlag;
  @Uint32()
  external int batteryLifeTime;
  @Uint32()
  external int batteryFullLifeTime;
}

/// Native Win32 machine readings when Linux /proc and /sys are absent.
class Win32Metrics {
  Win32Metrics() : _k32 = Platform.isWindows ? DynamicLibrary.open('kernel32.dll') : null;

  final DynamicLibrary? _k32;
  int? _prevBusy;
  int? _prevTotal;

  ({double totalGiB, double availGiB, double swapUsedGiB, double swapTotalGiB})? memory() {
    final k32 = _k32;
    if (k32 == null) return null;
    final fn = k32.lookupFunction<Int32 Function(Pointer<_MemoryStatusEx>), int Function(Pointer<_MemoryStatusEx>)>(
      'GlobalMemoryStatusEx',
    );
    final st = calloc<_MemoryStatusEx>();
    try {
      st.ref.dwLength = sizeOf<_MemoryStatusEx>();
      if (fn(st) == 0) return null;
      const gib = 1073741824.0;
      final totalPhys = st.ref.ullTotalPhys / gib;
      final availPhys = st.ref.ullAvailPhys / gib;
      final pageTotal = (st.ref.ullTotalPageFile - st.ref.ullTotalPhys).clamp(0, 1 << 60) / gib;
      final pageAvail = (st.ref.ullAvailPageFile - st.ref.ullAvailPhys).clamp(0, 1 << 60) / gib;
      return (
        totalGiB: totalPhys,
        availGiB: availPhys,
        swapUsedGiB: (pageTotal - pageAvail).clamp(0, pageTotal),
        swapTotalGiB: pageTotal,
      );
    } finally {
      calloc.free(st);
    }
  }

  double? cpuLoad() {
    final k32 = _k32;
    if (k32 == null) return null;
    final fn = k32.lookupFunction<
      Int32 Function(Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
      int Function(Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)
    >('GetSystemTimes');
    final idle = calloc<Uint64>();
    final kernel = calloc<Uint64>();
    final user = calloc<Uint64>();
    try {
      if (fn(idle, kernel, user) == 0) return null;
      final total = kernel.value + user.value;
      final busy = total - idle.value;
      final pTotal = _prevTotal;
      final pBusy = _prevBusy;
      _prevTotal = total;
      _prevBusy = busy;
      if (pTotal == null || pBusy == null || total <= pTotal) return null;
      return (100.0 * (busy - pBusy) / (total - pTotal)).clamp(0.0, 100.0);
    } finally {
      calloc.free(idle);
      calloc.free(kernel);
      calloc.free(user);
    }
  }

  bool onBattery() {
    final k32 = _k32;
    if (k32 == null) return false;
    final fn = k32.lookupFunction<
      Int32 Function(Pointer<_SystemPowerStatus>),
      int Function(Pointer<_SystemPowerStatus>)
    >('GetSystemPowerStatus');
    final st = calloc<_SystemPowerStatus>();
    try {
      if (fn(st) == 0) return false;
      return st.ref.batteryFlag != 128 && st.ref.acLineStatus == 0;
    } finally {
      calloc.free(st);
    }
  }

  String cpuName() {
    if (!Platform.isWindows) return '';
    try {
      final adv = DynamicLibrary.open('advapi32.dll');
      final regGetValue = adv.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32, Pointer<Uint32>, Pointer<Void>, Pointer<Uint32>),
        int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Uint32>, Pointer<Void>, Pointer<Uint32>)
      >('RegGetValueW');
      final subKey = r'HARDWARE\DESCRIPTION\System\CentralProcessor\0'.toNativeUtf16();
      final valName = 'ProcessorNameString'.toNativeUtf16();
      final buf = calloc<Uint16>(128);
      final size = calloc<Uint32>()..value = 256;
      try {
        // HKEY_LOCAL_MACHINE = 0x80000002, RRF_RT_REG_SZ = 0x00000002
        if (regGetValue(0x80000002, subKey, valName, 2, nullptr, buf.cast(), size) == 0) {
          return buf.cast<Utf16>().toDartString().trim();
        }
      } finally {
        calloc.free(subKey);
        calloc.free(valName);
        calloc.free(buf);
        calloc.free(size);
      }
    } on Object {
      // Fall back to environment below.
    }
    return Platform.environment['PROCESSOR_IDENTIFIER'] ?? '';
  }
}
