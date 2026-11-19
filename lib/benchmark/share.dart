import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../engine/engine_flags.dart';
import '../engine/tuning.dart';
import '../state/prefs.dart';
import '../state/providers.dart';
import '../system/firebase.dart';
import '../system/folders.dart';
import 'benchmark.dart';

// A finished Benchmark run, shared (when the user allows it) so the engine can be made faster on every kind of PC:
// the PC, the engine and its settings, the autotuner's measurements and every number the run measured. Never any chat
// text, prompt or reply, no names, no folders (a file is named by its file name alone), no address.

/// The version of the shared document's layout.
const benchmarkDocVersion = 1;

/// A number list longer than this is sent as one text of comma-separated numbers: a document stays small, and the
/// database does not index thousands of single numbers.
const packedListMin = 33;

/// A document larger than this (as JSON) leaves out the readings over time, then the turns' token times.
const benchmarkDocMaxBytes = 800000;

/// [value] with its folders left out: a path (`/a/b/file.gguf`, `C:\a\file`, `~/a/file`, `{models}/file`) becomes its
/// file name, also after `name=`; anything else stays as it is.
String withoutFolders(String value) {
  bool path(String s) => RegExp(r'^(?:[A-Za-z]:|~|\{models\}|\.{1,2})?[\\/]').hasMatch(s);
  String name(String s) => s.split(RegExp(r'[\\/]')).last;
  if (path(value)) return name(value);
  final eq = value.indexOf('=');
  return eq > 0 && path(value.substring(eq + 1)) ? '${value.substring(0, eq + 1)}${name(value.substring(eq + 1))}' : value;
}

/// A command's words with their folders left out ([withoutFolders]).
List<String> commandWithoutFolders(List<String> words) => [for (final w in words) withoutFolders(w)];

/// The last line of defence: every text in [value] with the [folders] (the home folder, the app's data folder) and any
/// path that starts a word cut down to file names.
Object? scrubbed(Object? value, List<String> folders) => switch (value) {
  String s => _scrubText(s, folders),
  Map m => {for (final e in m.entries) '${e.key}': scrubbed(e.value, folders)},
  List l => [for (final v in l) scrubbed(v, folders)],
  _ => value,
};

String _scrubText(String text, List<String> folders) {
  var out = text;
  for (final f in folders) {
    if (f.length > 1) out = out.replaceAll('$f${Platform.pathSeparator}', '').replaceAll('$f/', '').replaceAll(f, '');
  }
  return out.replaceAllMapped(
    RegExp(r'''(^|[\s'"=(])((?:[A-Za-z]:|~)?[\\/][^\s'"]*)'''),
    (m) => '${m[1]}${m[2]!.split(RegExp(r'[\\/]')).last}',
  );
}

/// [value] with every list of more than [packedListMin] numbers written as one text ("1.5,2,,3": an empty place is a
/// missing value), numbers to two decimals.
Object? packed(Object? value) {
  if (value is Map) return {for (final e in value.entries) '${e.key}': packed(e.value)};
  if (value is List) {
    if (value.length >= packedListMin && value.every((v) => v == null || v is num)) {
      return value.map((v) => v == null ? '' : _short(v as num)).join(',');
    }
    return [for (final v in value) packed(v)];
  }
  return value;
}

String _short(num v) {
  if (v is int || v == v.roundToDouble()) return '${v.round()}';
  final s = v.toStringAsFixed(2);
  return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}

/// The `benchmarks` document for [result]: the fields the database's rules allow, everything else inside `data`.
/// [machine]: what [readMachine] found; [tuned]: the autotuner's result for the model ([tunedFor]); [layout]: the
/// engine's own memory layout at the end of the run.
Map<String, Object?> benchmarkDocument({
  required BenchmarkResult result,
  required String installId,
  required ModelFile file,
  required String kvCache,
  Map<String, Object?> machine = const {},
  ({String fileName, Map<String, dynamic> result})? tuned,
  Map<String, Object?> layout = const {},
  List<String> folders = const [],
}) {
  final env = result.environment;
  final flags = EngineFlags.parse(result.flags);
  final turns = [
    for (final t in result.turns)
      {
        ...t.toJson(),
        // (The engine's own token times are the ones to keep; the app's are only for runs that lack them.)
        if (t.tokenMillis.isNotEmpty) 'tokenGaps': null,
        'tokensPerSecond': t.tokensPerSecond,
        'promptTokensPerSecond': t.promptTokensPerSecond,
        'tokenStats': _stats(t.tokenStats),
      }..removeWhere((_, v) => v == null),
  ];
  final hardware = env.hardware;
  final data = <String, Object?>{
    'at': result.at.toUtc().toIso8601String(),
    'machine': {
      'cpu': hardware.cpu,
      'logicalCores': hardware.threads,
      'ramTotalGiB': hardware.ramGiB,
      'ramFreeGiB': result.memory.freeRamGiB,
      'gpus': hardware.gpus,
      'osSummary': hardware.os,
      'onBattery': env.onBattery,
      ...machine,
    },
    'model': {
      'id': file.id,
      'name': result.modelName,
      'quantization': file.quantization,
      'fileName': ?tuned?.fileName,
      'fileBytes': env.modelFileBytes,
      'fileModified': env.modelFileModified?.toUtc().toIso8601String(),
    },
    'settings': {
      'test': result.promptLabel,
      'contextLength': result.contextLength,
      'kvCache': kvCache,
      'memoryHeadroomGiB': result.memoryCapGiB,
      'vramHeadroomGiB': ?result.vramHeadroomGiB,
      'profile': result.profileName,
      'replyLength': result.replyLength,
      'thinking': result.thinking,
      'warmups': result.warmups.length,
      'environment': {for (final e in flags.environment.entries) e.key: withoutFolders(e.value)},
      'flags': commandWithoutFolders(flags.arguments).join(' '),
      // What the engine was started with: the flags with the autotuner's measured settings put in, as the app does.
      'flagsUsed': commandWithoutFolders(withTuning(flags.arguments, tuned?.result)).join(' '),
      'addedFlags': env.addedFlags,
    },
    'autotuner': tuned?.result,
    'results': {
      'loadMillis': result.loadMillis,
      'firstTokenMillis': result.firstTokenMillis,
      'promptTokens': result.promptTokens,
      'promptMillis': result.promptMillis,
      'promptTokensPerSecond': result.promptTokensPerSecond,
      'replyTokens': result.replyTokens,
      'replyMillis': result.replyMillis,
      'tokensPerSecond': result.tokensPerSecond,
      'millisPerToken': result.millisPerToken,
      'totalMillis': result.totalMillis,
      'stopReason': result.stopReason,
      'tokenStats': _stats(result.tokenStats),
      'ssdWaitPerToken': result.ssdWaitPerToken,
      'hitRate': result.hitRate,
      'ramHitPercent': result.ramHitPercent,
      'vramHitPercent': result.vramHitPercent,
      'tokenMillis': [for (final w in result.tokens) double.parse(w.toStringAsFixed(2))],
      'timeParts': result.timeParts,
      'layers': result.layers,
      'engineStats': result.engineStats,
      'memory': result.memory.toJson(),
      'engineLayout': layout,
      'disturbed': result.disturbed,
      'turns': turns,
      'series': result.series?.toJson(),
    },
  };
  var packedData = packed(scrubbed(data, folders))! as Map<String, Object?>;
  final doc = {
    'v': benchmarkDocVersion,
    'installId': installId,
    if (env.appVersion != null) 'appVersion': _cut(env.appVersion!, 40),
    if (env.engineVersion != null) 'engineVersion': _cut(env.engineVersion!, 80),
    'data': packedData,
  };
  // A very long run: the readings over time go first, then the turns' token times (the measured turn's stay).
  int size() => utf8.encode(jsonEncode(doc)).length;
  final results = packedData['results']! as Map<String, Object?>;
  if (size() > benchmarkDocMaxBytes) results.remove('series');
  if (size() > benchmarkDocMaxBytes) {
    for (final t in (results['turns'] as List?) ?? const []) {
      (t as Map)..remove('tokenMillis')..remove('tokenGaps');
    }
  }
  if (size() > benchmarkDocMaxBytes) results.remove('tokenMillis');
  return doc;
}

String _cut(String s, int max) => s.length <= max ? s : s.substring(0, max);

Map<String, double> _stats(TokenStats s) => {'p50': s.p50, 'p90': s.p90, 'p99': s.p99, 'max': s.max, 'mean': s.mean};

/// The autotuner's result for the model file of [bytes] bytes in the app's autotuner.json (kept per model file under
/// "name:size:..."), with the file's name; null when it has none.
({String fileName, Map<String, dynamic> result})? tunedFor(String autotunerJson, int? bytes) {
  if (bytes == null) return null;
  try {
    final models = (jsonDecode(autotunerJson) as Map)['models'];
    if (models is! Map) return null;
    ({String fileName, Map<String, dynamic> result})? found;
    for (final e in models.entries) {
      final parts = '${e.key}'.split(':');
      if (parts.length >= 2 && parts[1] == '$bytes' && e.value is Map) {
        found = (fileName: parts[0], result: (e.value as Map).cast<String, dynamic>());
      }
    }
    return found;
  } on Object {
    return null;
  }
}

/// The mount in /proc/self/mountinfo's [mountinfo] that holds [path]: its file system and its device.
({String filesystem, String device})? mountOf(String mountinfo, String path) {
  ({String filesystem, String device})? best;
  var bestLength = -1;
  for (final line in mountinfo.split('\n')) {
    final halves = line.split(' - ');
    if (halves.length < 2) continue;
    final left = halves[0].split(' '), right = halves[1].split(' ');
    if (left.length < 5 || right.length < 2) continue;
    // (A space in a mount point is written \040.)
    final point = left[4].replaceAllMapped(RegExp(r'\\([0-7]{3})'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)));
    final inside = path == point || point == '/' || path.startsWith('$point/');
    if (inside && point.length > bestLength) {
      bestLength = point.length;
      best = (filesystem: right[0], device: right[1]);
    }
  }
  return best;
}

/// The /etc/os-release fields worth keeping.
Map<String, String> parseOsRelease(String text) => {
  for (final m in RegExp(r'^(NAME|VERSION_ID|ID|PRETTY_NAME)="?([^"\n]*)"?$', multiLine: true).allMatches(text))
    m[1]!: m[2]!,
};

/// The physical cores in /proc/cpuinfo (distinct package and core numbers); null when it does not say.
int? physicalCores(String cpuinfo) {
  final cores = <String>{};
  String? package;
  for (final line in cpuinfo.split('\n')) {
    final m = RegExp(r'^(physical id|core id)\s*:\s*(\d+)').firstMatch(line);
    if (m == null) continue;
    if (m[1] == 'physical id') {
      package = m[2];
    } else {
      cores.add('$package:${m[2]}');
    }
  }
  return cores.isEmpty ? null : cores.length;
}

/// What the PC is, beyond the run's own record: the system and its kernel, the physical cores, the graphics driver, and
/// the drive of [modelsFolder] (its model, kind and file system). Linux reads /proc and /sys; elsewhere only what Dart
/// itself tells. Nothing it cannot read is a failure.
Map<String, Object?> readMachine(String modelsFolder) {
  String? read(String path) {
    try {
      return File(path).readAsStringSync().trim();
    } on FileSystemException {
      return null;
    }
  }

  final out = <String, Object?>{'system': Platform.operatingSystem, 'systemVersion': Platform.operatingSystemVersion};
  if (!Platform.isLinux) return out;
  out['os'] = parseOsRelease(read('/etc/os-release') ?? '');
  out['kernel'] = read('/proc/sys/kernel/osrelease');
  out['physicalCores'] = physicalCores(read('/proc/cpuinfo') ?? '');
  final nvidia = RegExp(r'Kernel Module.*?\s(\d+\.\d+(?:\.\d+)?)\s').firstMatch(read('/proc/driver/nvidia/version') ?? '');
  if (nvidia != null) out['nvidiaDriver'] = nvidia[1];
  final amd = read('/sys/module/amdgpu/version');
  if (amd != null && amd.isNotEmpty) out['amdgpuDriver'] = amd;

  try {
    var folder = modelsFolder;
    if (Directory(folder).existsSync()) folder = Directory(folder).resolveSymbolicLinksSync();
    final mount = mountOf(read('/proc/self/mountinfo') ?? '', folder);
    if (mount == null) return out;
    final drive = <String, Object?>{'filesystem': mount.filesystem};
    out['drive'] = drive;
    if (!mount.device.startsWith('/dev/')) return out;
    // The device, through the mapper (an encrypted or joined volume) to the disk that holds it.
    var name = File(mount.device).resolveSymbolicLinksSync().split('/').last;
    for (var hops = 0; hops < 4; hops++) {
      final slaves = Directory('/sys/class/block/$name/slaves');
      final under = slaves.existsSync() ? slaves.listSync().map((e) => e.path.split('/').last).toList() : const <String>[];
      if (under.isEmpty) break;
      name = under.first;
    }
    final sysPath = Directory('/sys/class/block/$name').resolveSymbolicLinksSync();
    if (File('$sysPath/partition').existsSync()) name = sysPath.split('/').reversed.elementAt(1);
    final disk = '/sys/block/$name';
    final rotational = read('$disk/queue/rotational');
    final through = Directory(disk).resolveSymbolicLinksSync();
    drive['model'] = read('$disk/device/model');
    drive['type'] = name.startsWith('nvme')
        ? 'NVMe SSD'
        : rotational == '1'
        ? 'HDD'
        : rotational == '0'
        ? 'SSD'
        : null;
    drive['usb'] = through.contains('/usb');
    drive['removable'] = read('$disk/removable') == '1';
  } on FileSystemException {
    // (A drive the app cannot follow is left out.)
  }
  return out;
}

/// The random name of this PC's install, made once and kept in the app's data folder [dir]: tied to nothing else.
String installIdIn(Directory dir) {
  final file = File('${dir.path}${Platform.pathSeparator}install-id');
  try {
    final kept = file.readAsStringSync().trim();
    if (RegExp(r'^[0-9a-f]{32}$').hasMatch(kept)) return kept;
  } on FileSystemException {
    // (None yet.)
  }
  final random = Random.secure();
  final id = [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  file.writeAsStringSync(id);
  return id;
}

/// Sends a finished run's document when the user shares benchmark results, in the background. A failed send is tried
/// once more after [retryAfter], then dropped; a failure is only logged (no message).
class BenchmarkSharer {
  BenchmarkSharer(this._ref, {this.retryAfter = const Duration(seconds: 30)});

  final Ref _ref;
  final Duration retryAfter;

  /// The document that was sent last (for the tests); null before.
  Map<String, Object?>? lastSent;

  Future<void> share(BenchmarkResult result, {required ModelFile file, required String kvCache, Map<String, Object?> layout = const {}}) async {
    try {
      if (!_ref.read(prefsProvider).shareBenchmarks) return;
      final dir = _ref.read(storageProvider).dir;
      final firestore = _ref.read(firestoreProvider);
      final modelsFolder = _ref.read(foldersProvider).models;
      final machine = await Isolate.run(() => readMachine(modelsFolder));
      final tuneFile = File('${dir.path}${Platform.pathSeparator}autotuner.json');
      final tuned = tuneFile.existsSync() ? tunedFor(await tuneFile.readAsString(), result.environment.modelFileBytes) : null;
      final env = Platform.environment;
      final doc = benchmarkDocument(
        result: result,
        installId: installIdIn(dir),
        file: file,
        kvCache: kvCache,
        machine: machine,
        tuned: tuned,
        layout: layout,
        folders: [?env['HOME'], ?env['USERPROFILE'], dir.path, modelsFolder],
      );
      lastSent = doc;
      String name;
      try {
        name = await firestore.create('benchmarks', doc);
      } on FirestoreFailure catch (e) {
        debugPrint('Benchmark result not shared, trying once more: $e');
        await Future<void>.delayed(retryAfter);
        // (The user may have turned sharing off meanwhile.)
        if (!_ref.read(prefsProvider).shareBenchmarks) return;
        name = await firestore.create('benchmarks', doc);
      }
      debugPrint('Benchmark result shared: $name');
    } on Object catch (e) {
      debugPrint('Benchmark result not shared: $e');
    }
  }
}

final benchmarkSharerProvider = Provider<BenchmarkSharer>((ref) => BenchmarkSharer(ref));
