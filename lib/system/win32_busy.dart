import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows' counters for the busy check while the autotuner runs: the PC's CPU time, the autotuner's own CPU time and
/// read bytes, and the bytes moved on the drive that holds the model. Times are in 100 ns over all processors.
class Win32BusyCounters {
  Win32BusyCounters._(this._k32, this._process, this._volume);

  /// Opens the counters for the process [pid] and the drive of [modelPath]; null when the process cannot be opened
  /// (it ended already) or the system's functions are missing. A drive that cannot be read (a network path) is left
  /// out: the CPU alone is checked then.
  static Win32BusyCounters? open(int pid, String modelPath) {
    if (!Platform.isWindows) return null;
    try {
      final k32 = DynamicLibrary.open('kernel32.dll');
      final openProcess = k32.lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>(
        'OpenProcess',
      );
      final process = openProcess(_processQueryLimitedInformation, 0, pid);
      if (process == 0) return null;
      return Win32BusyCounters._(k32, process, _openVolume(k32, modelPath));
    } on ArgumentError {
      return null;
    }
  }

  static const _processQueryLimitedInformation = 0x1000;
  static const _ioctlDiskPerformance = 0x00070020;
  static const _invalidHandle = -1;

  final DynamicLibrary _k32;
  final int _process;
  final int _volume;   // 0: the drive is not read

  /// The volume the model is on (`\\.\C:`), opened without any access right: enough for its counters.
  static int _openVolume(DynamicLibrary k32, String modelPath) {
    final letter = RegExp(r'^([A-Za-z]):').firstMatch(File(modelPath).absolute.path)?[1];
    if (letter == null) return 0;
    final createFile = k32.lookupFunction<
      IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr),
      int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
    >('CreateFileW');
    final name = '\\\\.\\$letter:'.toNativeUtf16();
    try {
      // no access asked for, shared for reading and writing, an existing object
      final handle = createFile(name, 0, 3, nullptr, 3, 0, 0);
      return handle == _invalidHandle ? 0 : handle;
    } finally {
      calloc.free(name);
    }
  }

  late final _getSystemTimes = _k32.lookupFunction<
    Int32 Function(Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
    int Function(Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)
  >('GetSystemTimes');
  late final _getProcessTimes = _k32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
    int Function(int, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)
  >('GetProcessTimes');
  late final _getProcessIoCounters = _k32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint64>),
    int Function(int, Pointer<Uint64>)
  >('GetProcessIoCounters');
  late final _deviceIoControl = _k32.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32, Pointer<Void>, Uint32, Pointer<Uint32>, Pointer<Void>),
    int Function(int, int, Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>)
  >('DeviceIoControl');
  late final _closeHandle = _k32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

  /// One look; null when the process has ended or a counter could not be read.
  ({int total, int idle, int own, int? disk, int? ownRead})? read() {
    // 16 eight-byte fields: more than the largest structure read here (the drive's counters, 88 bytes)
    final buf = calloc<Uint64>(16);
    final returned = calloc<Uint32>();
    try {
      // the system's times: idle, kernel (the idle time is part of it) and user
      if (_getSystemTimes(buf, buf + 1, buf + 2) == 0) return null;
      final idle = buf[0], total = buf[1] + buf[2];
      // the process's times: created, ended, kernel, user
      if (_getProcessTimes(_process, buf, buf + 1, buf + 2, buf + 3) == 0) return null;
      final own = buf[2] + buf[3];
      // its transfers: three counts of operations, then the bytes read, written and other
      final ownRead = _getProcessIoCounters(_process, buf) == 0 ? null : buf[3];
      int? disk;
      if (_volume != 0 && _deviceIoControl(_volume, _ioctlDiskPerformance, nullptr, 0, buf.cast(), 128, returned, nullptr) != 0) {
        disk = buf[0] + buf[1];   // the drive's counters start with the bytes read and the bytes written
      }
      return (total: total, idle: idle, own: own, disk: disk, ownRead: ownRead);
    } on ArgumentError {
      return null;
    } finally {
      calloc.free(buf);
      calloc.free(returned);
    }
  }

  void close() {
    try {
      _closeHandle(_process);
      if (_volume != 0) _closeHandle(_volume);
    } on ArgumentError {
      // nothing to close with
    }
  }
}
