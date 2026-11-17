import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../benchmark/amd_gpu.dart';
import '../benchmark/hardware.dart';
import '../benchmark/nvml.dart';
import '../benchmark/share.dart' show installIdIn;
import '../data/models.dart';
import '../system/firebase.dart';
import 'about.dart';
import 'feedback.dart' show cutText;
import 'first_run.dart';
import 'library.dart';
import 'prefs.dart';
import 'providers.dart';

// A small "app stats" document, at most once a day, when the user shares benchmark results and app stats: it tells how
// many installs are in use and with which versions and kinds of PC. It holds this install's random name, the versions,
// the system, the processor and graphics cards, the names of the downloaded models and the day. Never a chat, a name
// or a folder.

/// The version of the document's layout.
const appStatsDocVersion = 1;

/// The `appStats` document the database's rules allow: every text and list within its limit.
Map<String, Object?> appStatsDocument({
  required String installId,
  required String day,
  required String appVersion,
  String? engineVersion,
  required HardwareInfo hardware,
  required List<String> models,
}) => {
  'v': appStatsDocVersion,
  'installId': installId,
  'day': day,
  'appVersion': cutText(appVersion, 40),
  if (engineVersion != null) 'engineVersion': cutText(engineVersion, 80),
  'os': cutText(hardware.os.isNotEmpty ? hardware.os : Platform.operatingSystem, 120),
  'cpu': cutText(hardware.cpu, 120),
  'gpus': [for (final g in hardware.gpus.take(8)) cutText(g, 120)],
  'models': [for (final m in models.take(20)) cutText(m, 80)],
};

/// The date of [t] in UTC, as yyyy-mm-dd.
String dayOf(DateTime t) => t.toUtc().toIso8601String().substring(0, 10);

/// What the computer is: the processor, the graphics cards (NVIDIA's through their driver, AMD's through the system's
/// files), the memory and the system. Read on another isolate.
Future<HardwareInfo> readHardwareInfo() => Isolate.run(() {
  final nvidia = NvmlReader.open();
  final amd = AmdGpuReader.open(const DiskFiles(), firstIndex: nvidia?.names.length ?? 0);
  final cards = <GpuSource>[?nvidia, ?amd];
  final reader = SystemReader(const DiskFiles(), gpu: cards.isEmpty ? null : GpuSources(cards));
  try {
    return reader.info();
  } finally {
    reader.gpu?.close();
  }
});

/// Sends the day's document when it is due.
class AppStatsSender {
  AppStatsSender(this._ref, {Future<HardwareInfo> Function()? hardware, DateTime Function()? now})
    : _hardware = hardware ?? readHardwareInfo,
      _now = now ?? DateTime.now;

  final Ref _ref;
  final Future<HardwareInfo> Function() _hardware;
  final DateTime Function() _now;
  var _busy = false;

  /// The document that was sent last (for the tests); null before.
  Map<String, Object?>? lastSent;

  /// Sends today's document unless the user does not share, or one went out today. A failure is only logged: the next
  /// start tries again. Never throws.
  Future<void> sendIfDue() async {
    if (_busy) return;
    _busy = true;
    try {
      if (!_ref.read(prefsProvider).shareBenchmarks) return;
      final dir = _ref.read(storageProvider).dir;
      final day = dayOf(_now());
      final kept = File('${dir.path}${Platform.pathSeparator}app-stats-day');
      if (kept.existsSync() && kept.readAsStringSync().trim() == day) return;
      final catalog = await _ref
          .read(catalogProvider.future)
          .then<List<CatalogModel>>((c) => c, onError: (Object _) => <CatalogModel>[]);
      final files = {
        for (final m in catalog)
          for (final f in m.files) f.id: '${m.name} ${f.quantization}',
      };
      final engine = await _ref.read(engineVersionProvider.future).catchError((Object _) => null);
      final doc = appStatsDocument(
        installId: installIdIn(dir),
        day: day,
        appVersion: appVersion,
        engineVersion: engine,
        hardware: await _hardware(),
        models: [for (final id in _ref.read(libraryProvider).downloaded) ?files[id]],
      );
      // (The user may have turned sharing off while the machine was read.)
      if (!_ref.read(prefsProvider).shareBenchmarks) return;
      lastSent = doc;
      await _ref.read(firestoreProvider).create('appStats', doc);
      kept.writeAsStringSync(day);
    } on Object catch (e) {
      debugPrint('App stats not sent: $e');
    } finally {
      _busy = false;
    }
  }
}

final appStatsSenderProvider = Provider<AppStatsSender>(AppStatsSender.new);

/// Starts the day's send in the background: once the welcome screen is done (so the user has made their choice), and
/// at every start after it. Watched once, by the app.
final appStatsProvider = Provider<void>((ref) {
  void send() {
    if (ref.read(firstRunProvider).welcomeShown) {
      unawaited(ref.read(appStatsSenderProvider).sendIfDue());
    }
  }

  ref.listen(firstRunProvider.select((f) => f.welcomeShown), (_, _) => send());
  send();
});
