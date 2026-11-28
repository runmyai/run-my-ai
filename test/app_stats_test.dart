// The daily app stats: the document's fields and limits, and that it goes at most once a day and only when the user
// shares. Nothing reaches the real database.
// Run: flutter test test/app_stats_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/benchmark/hardware.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/about.dart';
import 'package:runmyai/state/app_stats.dart';
import 'package:runmyai/state/first_run.dart';
import 'package:runmyai/state/prefs.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/system/firebase.dart';

const _hardware = HardwareInfo(
  cpu: 'Ryzen AI 9 HX 370',
  threads: 24,
  gpus: ['RTX 5070 Ti Laptop'],
  ramGiB: 30,
  os: 'Fedora Linux 44, kernel 7.2',
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
    ModelFile(id: 'ling-mxfp4', quantization: 'MXFP4', sizeBytes: 1, repo: 'a/b', parts: ['f.gguf']),
  ],
);

void main() {
  late Directory dir;
  late List<Map<String, Object?>> posted;
  late DateTime now;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('runmyai-stats-');
    posted = [];
    now = DateTime.utc(2030, 5, 6, 23, 59);
    // A library with one downloaded model.
    Storage(dir).writeLibrary(const LibraryData(downloaded: {'ling-mxfp4', 'gone'}));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  ProviderContainer open() {
    final container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        catalogProvider.overrideWith((ref) async => const [_ling]),
        engineVersionProvider.overrideWith((ref) async => '0.9.0 (build 1)'),
        firestoreProvider.overrideWithValue(
          Firestore(
            post: (url, body) async {
              posted.add((jsonDecode(body) as Map).cast<String, Object?>());
              return (200, '{}');
            },
          ),
        ),
        appStatsSenderProvider.overrideWith(
          (ref) => AppStatsSender(ref, hardware: () async => _hardware, now: () => now),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Map<String, Object?> fields() =>
      ((((posted.last['writes']! as List).single as Map)['update'] as Map)['fields'] as Map).cast<String, Object?>();

  test('the document holds exactly its fields, each within its limit', () {
    final doc = appStatsDocument(
      installId: 'a' * 32,
      day: '2030-05-06',
      appVersion: '0.1.0',
      engineVersion: 'v' * 200,
      hardware: HardwareInfo(cpu: 'c' * 300, gpus: [for (var i = 0; i < 12; i++) 'g' * 300], os: ''),
      models: [for (var i = 0; i < 30; i++) 'm' * 200],
    );
    expect(doc.keys, {'v', 'installId', 'day', 'appVersion', 'engineVersion', 'os', 'cpu', 'gpus', 'models'});
    expect((doc['engineVersion']! as String).length, 80);
    expect((doc['cpu']! as String).length, 120);
    expect(doc['os'], Platform.operatingSystem);
    expect(doc['gpus'], hasLength(8));
    expect(doc['models'], hasLength(20));
    expect(() => firestoreFields(doc), returnsNormally);
    expect(dayOf(DateTime.parse('2030-05-06T23:59:00-05:00')), '2030-05-07');
  });

  test('one send a day: the fields, the lasting install id, then nothing until the next day', () async {
    final container = open();
    final sender = container.read(appStatsSenderProvider);
    await sender.sendIfDue();
    expect(posted, hasLength(1));
    final write = ((posted.single['writes']! as List).single as Map)['update'] as Map;
    expect(write['name'], contains('/documents/appStats/'));
    expect(fields().keys, {'v', 'installId', 'day', 'appVersion', 'engineVersion', 'os', 'cpu', 'gpus', 'models'});
    expect((fields()['day']! as Map)['stringValue'], '2030-05-06');
    expect((fields()['installId']! as Map)['stringValue'], File('${dir.path}/install-id').readAsStringSync());
    expect((fields()['cpu']! as Map)['stringValue'], 'Ryzen AI 9 HX 370');
    expect(jsonEncode(posted.single), contains('Ling 3.0 Flash MXFP4'));
    expect(jsonEncode(posted.single), isNot(contains('gone')), reason: 'only names the catalog knows');
    expect(jsonEncode(posted.single), isNot(contains(dir.path)));

    await sender.sendIfDue();
    now = DateTime.utc(2030, 5, 6, 23, 59, 59);
    await sender.sendIfDue();
    expect(posted, hasLength(1), reason: 'the same day');

    // A new start (a new sender) on the same day still sends nothing: the day is kept in a file.
    await open().read(appStatsSenderProvider).sendIfDue();
    expect(posted, hasLength(1));

    now = DateTime.utc(2030, 5, 7, 0, 1);
    await sender.sendIfDue();
    expect(posted, hasLength(2), reason: 'the next day');
  });

  test('not sharing: nothing is sent and nothing is kept', () async {
    final container = open();
    container.read(prefsProvider.notifier).setShareBenchmarks(false);
    await container.read(appStatsSenderProvider).sendIfDue();
    expect(posted, isEmpty);
    expect(File('${dir.path}/app-stats-day').existsSync(), isFalse);
  });

  test('a failed send is not counted: the next try sends it', () async {
    var status = 503;
    final container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        catalogProvider.overrideWith((ref) async => const [_ling]),
        engineVersionProvider.overrideWith((ref) async => null),
        firestoreProvider.overrideWithValue(Firestore(post: (url, body) async => (status, '{}'))),
        appStatsSenderProvider.overrideWith(
          (ref) => AppStatsSender(ref, hardware: () async => _hardware, now: () => now),
        ),
      ],
    );
    addTearDown(container.dispose);
    final sender = container.read(appStatsSenderProvider);
    await sender.sendIfDue();
    expect(File('${dir.path}/app-stats-day').existsSync(), isFalse);
    status = 200;
    await sender.sendIfDue();
    expect(File('${dir.path}/app-stats-day').readAsStringSync(), '2030-05-06');
  });

  test('the start-up hook waits for the welcome screen, then sends', () async {
    final container = open();
    container.listen(appStatsProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(posted, isEmpty, reason: 'the user has not made their choice yet');
    container.read(firstRunProvider.notifier).welcomeDone();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(posted, hasLength(1));
  });
}
