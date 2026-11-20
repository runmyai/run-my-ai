import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _JobBasicLimitInfo extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;
  @Int64()
  external int perJobUserTimeLimit;
  @Uint32()
  external int limitFlags;
  @Size()
  external int minimumWorkingSetSize;
  @Size()
  external int maximumWorkingSetSize;
  @Uint32()
  external int activeProcessLimit;
  @UintPtr()
  external int affinity;
  @Uint32()
  external int priorityClass;
  @Uint32()
  external int schedulingClass;
}

final class _IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;
  @Uint64()
  external int writeOperationCount;
  @Uint64()
  external int otherOperationCount;
  @Uint64()
  external int readTransferCount;
  @Uint64()
  external int writeTransferCount;
  @Uint64()
  external int otherTransferCount;
}

final class _JobExtendedLimitInfo extends Struct {
  external _JobBasicLimitInfo basic;
  external _IoCounters io;
  @Size()
  external int processMemoryLimit;
  @Size()
  external int jobMemoryLimit;
  @Size()
  external int peakProcessMemoryUsed;
  @Size()
  external int peakJobMemoryUsed;
}

/// Ties a child process on Windows to a kernel Job Object with KILL_ON_JOB_CLOSE
/// (and an optional commit limit), so the OS ends the engine even if the app crashes.
class Win32Job {
  Win32Job._(this._handle);

  int _handle;

  static const _jobObjectExtendedLimitInformation = 9;
  static const _limitKillOnJobClose = 0x00002000;
  static const _processSetQuotaAndTerminate = 0x0101;

  static Win32Job? attach(int pid) {
    if (!Platform.isWindows) return null;
    try {
      final k32 = DynamicLibrary.open('kernel32.dll');
      final createJob = k32.lookupFunction<
        IntPtr Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)
      >('CreateJobObjectW');
      final setInfo = k32.lookupFunction<
        Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32),
        int Function(int, int, Pointer<Void>, int)
      >('SetInformationJobObject');
      final openProcess = k32.lookupFunction<
        IntPtr Function(Uint32, Int32, Uint32),
        int Function(int, int, int)
      >('OpenProcess');
      final assignJob = k32.lookupFunction<
        Int32 Function(IntPtr, IntPtr),
        int Function(int, int)
      >('AssignProcessToJobObject');
      final closeHandle = k32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

      final job = createJob(nullptr, nullptr);
      if (job == 0) return null;

      final info = calloc<_JobExtendedLimitInfo>();
      try {
        info.ref.basic.limitFlags = _limitKillOnJobClose;
        if (setInfo(job, _jobObjectExtendedLimitInformation, info.cast(), sizeOf<_JobExtendedLimitInfo>()) == 0) {
          closeHandle(job);
          return null;
        }
      } finally {
        calloc.free(info);
      }

      final proc = openProcess(_processSetQuotaAndTerminate, 0, pid);
      if (proc == 0) {
        closeHandle(job);
        return null;
      }
      final ok = assignJob(job, proc);
      closeHandle(proc);
      if (ok == 0) {
        closeHandle(job);
        return null;
      }
      return Win32Job._(job);
    } on Object {
      return null;
    }
  }

  void close() {
    final h = _handle;
    if (h == 0) return;
    _handle = 0;
    try {
      final k32 = DynamicLibrary.open('kernel32.dll');
      final closeHandle = k32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
      closeHandle(h);
    } on Object {
      // Ignore cleanup errors on exit.
    }
  }
}
