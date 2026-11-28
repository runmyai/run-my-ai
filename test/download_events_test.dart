// The download events: the document's fields and limits, that a model's and an engine's go out only when the user
// shares, and the one retry. Nothing reaches the real database.
// Run: flutter test test/download_events_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/engine_backend.dart';
import 'package:runmyai/benchmark/hardware.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/download_events.dart';
import 'package:runmyai/state/prefs.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/system/firebase.dart';

const _hardware = HardwareInfo(
  cpu: 'c',
  threads: 1,
  gpus: [],
  ramGiB: 1,
  os: 'Fedora Linux 44',
);

const _ling = CatalogModel(
  id: 'ling',
  name: 'Ling 3.0 Flash',
  lab: 'x',
  madeBy: '',
  country: '',
  released: '',
  type: '',
  input: '',
  output: '',
  maxContext: '',
  parameters: '124B',
  activeParameters: '5.1B',
  files: [
    ModelFile(
      id: 'ling-mxfp4',
      quantization: 'MXFP4',
      sizeBytes: 1,
      repo: 'a/b',
      parts: ['f.gguf'],
    ),
  ],
);

void main() {
  late Directory dir;
  late List<Map<String, Object?>> fieldsSent;
  late int failFirst;
  var calls = 0;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('runmyai-events-');
    fieldsSent = [];
    failFirst = 0;
    calls = 0;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  ProviderContainer open() {
    final container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        catalogProvider.overrideWith((ref) async => const [_ling]),
        firestoreProvider.overrideWithValue(
          Firestore(
            post: (url, body) async {
              if (calls++ < failFirst) return (503, '{}');
              final update =
                  (((jsonDecode(body) as Map)['writes'] as List).single
                          as Map)['update']
                      as Map;
              expect(update['name'], contains('/documents/downloadEvents/'));
              fieldsSent.add({
                for (final e in (update['fields'] as Map).entries)
                  e.key as String: (e.value as Map).values.single,
              });
              return (200, '{}');
            },
          ),
        ),
        downloadEventsProvider.overrideWith(
          (ref) => DownloadEvents(
            ref,
            hardware: () async => _hardware,
            now: () => DateTime.utc(2030, 5, 6, 23, 59),
            retryAfter: const Duration(milliseconds: 10),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<DownloadEvents> ready(ProviderContainer c) async {
    await c.read(catalogProvider.future);
    return c.read(downloadEventsProvider);
  }

  test('the document holds exactly its fields, each within its limit', () {
    final doc = downloadEventDocument(
      installId: 'a' * 32,
      day: '2030-05-06',
      kind: 'engine',
      name: 'n' * 300,
      version: 'v' * 300,
      appVersion: '0.1.0',
      os: 'o' * 300,
    );
    expect(doc.keys, {
      'v',
      'installId',
      'day',
      'kind',
      'name',
      'version',
      'appVersion',
      'os',
    });
    expect((doc['name']! as String).length, 120);
    expect((doc['version']! as String).length, 80);
    expect((doc['os']! as String).length, 120);
    expect(() => firestoreFields(doc), returnsNormally);
  });

  test('a finished model: its name and quantization, no version', () async {
    final events = await ready(open());
    await events.model('ling-mxfp4');
    expect(fieldsSent, hasLength(1));
    final f = fieldsSent.single;
    expect(f.keys, {
      'v',
      'installId',
      'day',
      'kind',
      'name',
      'version',
      'appVersion',
      'os',
    });
    expect(f['kind'], 'model');
    expect(f['name'], 'Ling 3.0 Flash MXFP4');
    expect(f['version'], '');
    expect(f['day'], '2030-05-06');
    expect(f['os'], 'Fedora Linux 44');
    expect(f['installId'], File('${dir.path}/install-id').readAsStringSync());
  });

  test('an installed engine: the release file and its tag; a model the catalog does not know sends nothing', () async {
    final events = await ready(open());
    await events.engine('tokenwing-linux-x64-cuda13.tar.gz', 'v0.1.0');
    expect(fieldsSent.single['kind'], 'engine');
    expect(fieldsSent.single['name'], 'tokenwing-linux-x64-cuda13.tar.gz');
    expect(fieldsSent.single['version'], 'v0.1.0');
    await events.model('unknown');
    expect(fieldsSent, hasLength(1));
  });

  test('not sharing: nothing is sent', () async {
    final container = open();
    container.read(prefsProvider.notifier).setShareBenchmarks(false);
    final events = await ready(container);
    await events.model('ling-mxfp4');
    await events.engine('a.tar.gz', 'v1');
    expect(calls, 0);
  });

  test(
    'one failure is tried once more; two are dropped without throwing',
    () async {
      failFirst = 1;
      final events = await ready(open());
      await events.model('ling-mxfp4');
      expect(calls, 2);
      expect(fieldsSent, hasLength(1));

      calls = 0;
      failFirst = 5;
      await events.engine('a.tar.gz', 'v1');
      expect(calls, 2, reason: 'one try and one retry, then dropped');
      expect(fieldsSent, hasLength(1));
    },
  );

  test(
    'the engine is told who started it, and that the user does not share',
    () {
      expect(EngineBackend.launcherEnvironment('abc', true), {
        'TOKENWING_LAUNCHER': 'run-my-ai',
        'TOKENWING_INSTALL_ID': 'abc',
      });
      expect(EngineBackend.launcherEnvironment('abc', false), {
        'TOKENWING_LAUNCHER': 'run-my-ai',
        'TOKENWING_INSTALL_ID': 'abc',
        'TOKENWING_NO_STATS': '1',
      });
    },
  );
}
