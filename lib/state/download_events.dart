import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../benchmark/hardware.dart';
import '../benchmark/share.dart' show installIdIn;
import '../data/models.dart';
import '../system/firebase.dart';
import 'about.dart';
import 'app_stats.dart';
import 'feedback.dart' show cutText;
import 'prefs.dart';
import 'providers.dart';

// One small document each time a model or an engine build finishes downloading, when the user shares benchmark results
// and app stats: it tells which downloads are in use. It holds this install's random name, the day, what was
// downloaded and the versions. Never a chat, a name or a folder.

/// The version of the document's layout.
const downloadEventDocVersion = 1;

/// The `downloadEvents` document the database's rules allow: [kind] is `model` or `engine`; every text within its limit.
Map<String, Object?> downloadEventDocument({
  required String installId,
  required String day,
  required String kind,
  required String name,
  String version = '',
  required String appVersion,
  required String os,
}) => {
  'v': downloadEventDocVersion,
  'installId': installId,
  'day': day,
  'kind': kind,
  'name': cutText(name, 120),
  'version': cutText(version, 80),
  'appVersion': cutText(appVersion, 40),
  'os': cutText(os, 120),
};

/// Sends the documents. A failed send is tried once more after [retryAfter], then dropped; nothing is kept for later.
class DownloadEvents {
  DownloadEvents(
    this._ref, {
    Future<HardwareInfo> Function()? hardware,
    DateTime Function()? now,
    this.retryAfter = const Duration(seconds: 20),
  }) : _hardware = hardware ?? readHardwareInfo,
       _now = now ?? DateTime.now;

  final Ref _ref;
  final Future<HardwareInfo> Function() _hardware;
  final DateTime Function() _now;
  final Duration retryAfter;

  /// A model file that has just finished downloading. Unknown to the catalog: nothing is sent.
  Future<void> model(String fileId) async {
    final catalog = _ref.read(catalogProvider).value ?? const <CatalogModel>[];
    for (final m in catalog) {
      for (final f in m.files) {
        if (f.id == fileId) {
          return _send('model', '${m.name} ${f.quantization}', '');
        }
      }
    }
  }

  /// An engine build ([asset], release [tag]) that has just been installed.
  Future<void> engine(String asset, String tag) => _send('engine', asset, tag);

  Future<void> _send(String kind, String name, String version) async {
    try {
      if (!_ref.read(prefsProvider).shareBenchmarks) return;
      final os = (await _hardware()).os;
      final doc = downloadEventDocument(
        installId: installIdIn(_ref.read(storageProvider).dir),
        day: dayOf(_now()),
        kind: kind,
        name: name,
        version: version,
        appVersion: appVersion,
        os: os.isNotEmpty ? os : Platform.operatingSystem,
      );
      for (var attempt = 0; ; attempt++) {
        try {
          await _ref.read(firestoreProvider).create('downloadEvents', doc);
          return;
        } on Object catch (e) {
          debugPrint('Download event not sent: $e');
          if (attempt == 1) return;
          await Future<void>.delayed(retryAfter);
        }
      }
    } on Object catch (e) {
      debugPrint('Download event not sent: $e');
    }
  }
}

final downloadEventsProvider = Provider<DownloadEvents>(DownloadEvents.new);
