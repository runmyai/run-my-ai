// Updates: version order, the app's release file, model updates from a repo's runmyai.json, the notes of every version
// since the one on this PC, Update refused while the engine is in use, a bad checksum that changes nothing, and the
// AppImage put in place of a fake running one (no real start of a new app). Against a local server that imitates
// GitHub's API and Hugging Face.
// Run: flutter test test/updates_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/engine_download.dart';
import 'package:runmyai/state/about.dart';
import 'package:runmyai/state/benchmark.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/state/serve.dart';
import 'package:runmyai/state/updates.dart';
import 'package:runmyai/system/chime.dart';
import 'package:runmyai/system/folders.dart';
import 'package:runmyai/system/relaunch.dart';
import 'package:runmyai/system/signature.dart';
import 'package:runmyai/system/updater.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/update_page.dart';

import 'signing.dart';

class _Folders extends FoldersNotifier {
  _Folders(this.main);
  final String main;

  @override
  FolderSet build() => FolderSet(main: main, models: '$main/models', chats: '$main/chats', cache: '$main/cache');
}

class _Chime extends Chime {
  _Chime(Ref ref) : super(ref, null, Duration.zero);

  @override
  Future<void> play() async {}
}

class _Hosting extends ServeNotifier {
  @override
  ServeState build() => const ServeState(phase: ServePhase.hosting);
}

class _Measuring extends BenchmarkNotifier {
  @override
  BenchmarkState build() => const BenchmarkState(phase: BenchmarkPhase.measuring);
}

const _file = ModelFile(
  id: 'm/f',
  quantization: 'q',
  sizeBytes: 1,
  repo: 'runmyai/m',
  parts: ['m.gguf', 'm.vram.json'],
);
const _model = CatalogModel(
  id: 'm',
  name: 'Model',
  lab: 'L',
  madeBy: '',
  country: '',
  released: '',
  type: '',
  input: '',
  output: '',
  maxContext: '',
  parameters: '1B',
  activeParameters: '1B',
  files: [_file],
);

/// A backend whose replies never end, with an engine that only notes when it is stopped.
class _Backend implements Backend, EngineControl {
  final calls = <String>[];
  final _engine = ValueNotifier(const EngineState(EnginePhase.stopped));

  @override
  ValueListenable<EngineState> get engineState => _engine;
  @override
  Future<void> startEngine(ModelFile file, EngineRun run, {bool restart = false}) async {}
  @override
  Future<void> stopEngine() async => calls.add('stop');
  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) {
    calls.add('reply');
    return StreamController<ReplyEvent>().stream;
  }

  @override
  Future<List<CatalogModel>> loadCatalog() async => [_model];
  @override
  Stream<double> download(ModelFile file) => Stream.value(1);
  @override
  Future<void> deleteDownload(ModelFile file) async {}
  @override
  Map<int, String> autoCommands(ModelFile file) => const {defaultContextLength: '-c $defaultContextLength'};
  @override
  int maxContext(ModelFile file) => defaultContextLength;
  @override
  List<String> get logLines => const [];
  @override
  Listenable get logChanged => ValueNotifier(0);
  @override
  Future<void> eraseChatState(String chatId) async {}
  @override
  Future<void> setPinnedChats(List<String> chatIds) async {}
  @override
  Future<String?> reportedVersion() async => null;
}

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// GitHub's API and files and Hugging Face in one: releases of the app and the engine (newest given last), files at
/// `/dl/<name>`, and one model repo with its file list, files (in byte ranges) and runmyai.json.
class _Server {
  late HttpServer server;
  final appReleases = <Map<String, Object?>>[], engineReleases = <Map<String, Object?>>[];
  final files = <String, List<int>>{};
  final repo = <String, List<int>>{};
  String? modelList;

  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}');

  Map<String, Object?> release(String tag, String notes, List<String> assets, {bool draft = false}) => {
    'tag_name': tag,
    'body': notes,
    'draft': draft,
    'prerelease': false,
    'assets': [
      for (final a in assets) {'name': a, 'size': files[a]!.length, 'browser_download_url': '$uri/dl/$a'},
    ],
  };

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path, response = request.response;
      if (path == '/repos/runmyai/run-my-ai/releases') {
        response.write(jsonEncode(appReleases.reversed.toList()));
      } else if (path == '/repos/runmyai/tokenwing/releases') {
        response.write(jsonEncode(engineReleases.reversed.toList()));
      } else if (path.startsWith('/dl/') && files.containsKey(path.substring(4))) {
        response.add(files[path.substring(4)]!);
      } else if (path == '/api/models/runmyai/m/tree/main') {
        response.write(
          jsonEncode([
            for (final MapEntry(key: name, value: bytes) in repo.entries)
              {
                'type': 'file',
                'path': name,
                'size': bytes.length,
                'oid': 'pointer',
                'lfs': {'oid': _sha(bytes), 'size': bytes.length},
              },
          ]),
        );
      } else if (path == '/runmyai/m/resolve/main/runmyai.json') {
        if (modelList == null) {
          response.statusCode = 404;
        } else {
          response.write(modelList);
        }
      } else if (path == '/runmyai/m/resolve/main/runmyai.json.sig') {
        if (modelList == null) {
          response.statusCode = 404;
        } else {
          response.write(testSign(utf8.encode(modelList!)));
        }
      } else if (path.startsWith('/runmyai/m/resolve/main/') && repo.containsKey(path.split('/').last)) {
        final bytes = repo[path.split('/').last]!;
        final range = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
        final first = range == null ? 0 : int.parse(range[1]!),
            last = range == null ? bytes.length - 1 : int.parse(range[2]!);
        response.statusCode = range == null ? 200 : 206;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $first-$last/${bytes.length}');
        response.add(bytes.sublist(first, last + 1));
      } else {
        response.statusCode = 404;
      }
      await response.close();
    });
  }
}

List<int> _engineTar(String text) {
  final archive = Archive()..add(ArchiveFile.string('tokenwing/llama-server', text)..mode = 0x1ed);
  return GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive));
}

void main() {
  // the widget test's binding answers every request with 400; these talk to a real local server
  setUpAll(() {
    HttpOverrides.global = null;
    useTestKey();
  });

  group('versions', () {
    test('semantic versions are compared by number, a pre-release before its release', () {
      expect(compareVersions('v0.1.0', '0.1.0'), 0);
      expect(compareVersions('v0.1.10', 'v0.1.9'), greaterThan(0));
      expect(compareVersions('v0.2.0', 'v0.10.0'), lessThan(0));
      expect(compareVersions('v1.0', 'v1.0.0'), 0);
      expect(compareVersions('v0.2.0-beta', 'v0.2.0'), lessThan(0));
      expect(compareVersions('v0.2.0+5', 'v0.2.0'), 0);
    });

    test('the release file for each system and CPU', () {
      expect(appAsset('linux', 'x64'), 'RunMyAI-linux-x64.AppImage');
      expect(appAsset('linux', 'arm64'), 'RunMyAI-linux-arm64.AppImage');
      expect(appAsset('windows', 'x64'), 'RunMyAI-windows-x64.exe');
      expect(appAsset('macos', 'arm64'), isNull);
    });

    test('only newer releases, newest first', () {
      final rs = [
        for (final t in ['v0.1.0', 'v0.3.0', 'v0.0.9', 'v0.2.0']) GitHubRelease(t, '', const {}),
      ];
      expect([for (final r in newerReleases(rs, '0.1.0')) r.tag], ['v0.3.0', 'v0.2.0']);
    });

    test('a restarted AppImage gets no paths into the old one', () {
      final env = appImageEnvironment({
        'APPDIR': '/tmp/.mount_a',
        'PATH': '/tmp/.mount_a/usr/bin:/usr/bin',
        'LD_LIBRARY_PATH': '/tmp/.mount_a/usr/lib',
        'HOME': '/home/u',
        'DISPLAY': ':0',
      });
      expect(env, {'PATH': '/usr/bin', 'HOME': '/home/u', 'DISPLAY': ':0'});
    });
  });

  group('model list file', () {
    ModelVersion v(String version, Map<String, String> files) => (
      version: version,
      notes: 'notes $version',
      files: {for (final e in files.entries) e.key: (sha256: e.value, size: e.value.length)},
    );
    // files here with a checksum kept from their download
    Map<String, LocalFile> kept(Map<String, String> files) => {
      for (final e in files.entries) e.key: (sha256: e.value, size: e.value.length),
    };
    final versions = [
      v('1', {'w': 'w1', 'd': 'd1'}),
      v('2', {'w': 'w1', 'd': 'd2'}),
      v('3', {'w': 'w3', 'd': 'd2'}),
    ];

    test('the files that differ from the newest version, and the notes since the one here', () {
      final u = modelUpdate(versions, kept({'w': 'w1', 'd': 'd2'}))!;
      expect(u.files.keys, ['w']);
      expect(u.files['w']!.sha256, 'w3');
      expect([for (final x in u.versions) x.version], ['3']);
      final older = modelUpdate(versions, kept({'w': 'w1', 'd': 'd1'}))!;
      expect(older.files.keys.toSet(), {'w', 'd'});
      expect([for (final x in older.versions) x.version], ['3', '2']);
    });

    test('nothing to do when the files are the newest; every version shown for a file that is none of them', () {
      expect(modelUpdate(versions, kept({'w': 'w3', 'd': 'd2'})), isNull);
      expect(modelUpdate(versions, kept({'other': 'x'})), isNull);
      expect(
        [
          for (final x in modelUpdate(versions, kept({'w': 'mine'}))!.versions) x.version,
        ],
        ['3', '2', '1'],
      );
    });

    test('a file without a kept checksum is compared by its size', () {
      final sized = [
        v('1', {'w': 'w1'}),
        v('2', {'w': 'w-two'}),
      ];
      expect(modelUpdate(sized, {'w': (sha256: null, size: 5)}), isNull);
      final u = modelUpdate(sized, {'w': (sha256: null, size: 2)})!;
      expect(u.files['w']!.sha256, 'w-two');
      expect([for (final x in u.versions) x.version], ['2']);
      expect(
        [
          for (final x in modelUpdate(sized, {'w': (sha256: null, size: 9)})!.versions) x.version,
        ],
        ['2', '1'],
      );
    });

    test('only format 1 is read', () {
      expect(parseModelVersions('{"format": 2, "versions": []}'), isNull);
      expect(parseModelVersions('not json'), isNull);
      final parsed = parseModelVersions(
        '{"format": 1, "versions": [{"version": "1", "notes": "n", "files": {"a": {"sha256": "AB", "size": 3}}}]}',
      )!;
      expect(parsed.single.files['a'], (sha256: 'ab', size: 3));
    });
  });

  group('updating', () {
    late Directory dir;
    late String main;
    late ChatStore store;
    late _Backend backend;
    late _Server hub;
    late String appImage;
    var relaunched = 0;
    final oldWeights = utf8.encode('weights v1'),
        newWeights = utf8.encode('weights v2, larger'),
        vram = utf8.encode('[1, 2]');

    ProviderContainer make({List<Override> extra = const [], bool fromAppImage = true}) {
      final c = ProviderContainer(
        overrides: [
          storageProvider.overrideWithValue(Storage(Directory('${dir.path}/data'))),
          chatStoreProvider.overrideWithValue(store),
          backendProvider.overrideWithValue(backend),
          chimeProvider.overrideWith(_Chime.new),
          foldersProvider.overrideWith(() => _Folders(main)),
          gitHubApiProvider.overrideWithValue(hub.uri),
          websiteReleasesProvider.overrideWithValue(null),
          downloadServerProvider.overrideWithValue(hub.uri),
          updatesEnabledProvider.overrideWithValue(true),
          appFileProvider.overrideWithValue(fromAppImage ? appImage : null),
          relaunchProvider.overrideWithValue(() async => relaunched++),
          ...extra,
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('runmyai-updates-');
      main = '${dir.path}/Run My AI';
      store = await ChatStore.open(Directory('${dir.path}/data'));
      backend = _Backend();
      relaunched = 0;
      hub = _Server();
      await hub.start();

      // the app: this version and two newer ones (and a draft, never offered)
      appImage = '${dir.path}/apps/RunMyAI-linux-x64.AppImage';
      File(appImage)
        ..createSync(recursive: true)
        ..writeAsStringSync('old app');
      hub.files['RunMyAI-linux-x64.AppImage'] = utf8.encode('new app');
      hub.files['SHA256SUMS'] = utf8.encode(
        '${_sha(hub.files['RunMyAI-linux-x64.AppImage']!)}  RunMyAI-linux-x64.AppImage\n',
      );
      hub.files['SHA256SUMS.sig'] = utf8.encode(testSign(hub.files['SHA256SUMS']!));
      const appFiles = ['RunMyAI-linux-x64.AppImage', 'SHA256SUMS', 'SHA256SUMS.sig'];
      hub.appReleases.addAll([
        hub.release('v$appVersion', 'this one', appFiles),
        hub.release('v9.1.0', '**first** new', appFiles),
        hub.release('v9.3.0', 'unfinished', appFiles, draft: true),
        hub.release('v9.2.0', 'second new', appFiles),
      ]);

      // the engine: v0.1.0 installed, v0.2.0 out
      final tar = _engineTar('new engine');
      final asset = engineAsset(thisOs, thisArch, 'cuda13');
      hub.files[asset] = tar;
      hub.files['ENGINE-SUMS'] = utf8.encode('${_sha(tar)}  $asset\n');
      hub.files['ENGINE-SUMS.sig'] = utf8.encode(testSign(hub.files['ENGINE-SUMS']!));
      final engineRelease = hub.release('v0.2.0', 'faster engine', [asset, 'ENGINE-SUMS', 'ENGINE-SUMS.sig']);
      final engineFiles = engineRelease['assets']! as List;
      engineFiles[1]['name'] = 'SHA256SUMS';
      engineFiles[2]['name'] = 'SHA256SUMS.sig';
      hub.engineReleases.addAll([
        hub.release('v0.1.0', 'first engine', [asset]),
        engineRelease,
      ]);
      File('$main/engine/llama-server')
        ..createSync(recursive: true)
        ..writeAsStringSync('old engine');
      File('$main/engine/build.json').writeAsStringSync(jsonEncode({'build': 'cuda13', 'version': 'v0.1.0'}));

      // the model: weights of version 1 here; version 2 changed them
      for (final (name, bytes) in [('m.gguf', oldWeights), ('m.vram.json', vram)]) {
        File('$main/models/$name')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes);
      }
      hub.repo.addAll({'m.gguf': newWeights, 'm.vram.json': vram});
      hub.modelList = jsonEncode({
        'format': 1,
        'versions': [
          {
            'version': '1',
            'notes': 'first',
            'files': {
              'm.gguf': {'sha256': _sha(oldWeights), 'size': oldWeights.length},
              'm.vram.json': {'sha256': _sha(vram), 'size': vram.length},
            },
          },
          {
            'version': '2',
            'notes': 'better data',
            'files': {
              'm.gguf': {'sha256': _sha(newWeights), 'size': newWeights.length},
              'm.vram.json': {'sha256': _sha(vram), 'size': vram.length},
            },
          },
        ],
      });
    });

    tearDown(() async {
      await hub.server.close(force: true);
      await store.close();
      dir.deleteSync(recursive: true);
    });

    test('the check finds the app, the engine and the model, with the notes of every version since this one', () async {
      final c = make();
      await c.read(updatesProvider.notifier).check();
      final s = c.read(updatesProvider);
      expect([for (final r in s.app!.releases) r.tag], ['v9.2.0', 'v9.1.0']);
      expect([for (final r in s.app!.releases) r.notes], ['second new', '**first** new']);
      expect(s.app!.manual, isNull);
      expect(s.engine!.newest.tag, 'v0.2.0');
      expect(s.engine!.build, 'cuda13');
      expect(s.models.single.files.keys, ['m.gguf']);
      expect([for (final v in s.models.single.versions) v.notes], ['better data']);
      expect(s.updatable, isTrue);
      // found by its size: no model file was hashed
      expect(File('${dir.path}/data/file_hashes.json').existsSync(), isFalse);
    });

    test('a model file is compared by the checksum kept from its download, else by its size only', () async {
      // the same size as the newest version but other bytes
      hub.repo['m.gguf'] = utf8.encode('weights v3');
      final list = jsonDecode(hub.modelList!) as Map;
      (list['versions'] as List).last['files']['m.gguf'] = {
        'sha256': _sha(hub.repo['m.gguf']!),
        'size': oldWeights.length,
      };
      hub.modelList = jsonEncode(list);
      final c = make();
      await c.read(updatesProvider.notifier).check();
      expect(c.read(updatesProvider).models, isEmpty);
      expect(File('${dir.path}/data/file_hashes.json').existsSync(), isFalse);

      // its download kept the checksum: the change is seen
      c.read(fileHashesProvider).remember('$main/models/m.gguf', _sha(oldWeights));
      await c.read(updatesProvider.notifier).check();
      expect(c.read(updatesProvider).models.single.files.keys, ['m.gguf']);
    });

    test(
      'nothing is offered without a list file, without build.json, with the user\'s own engine, or from a dev build',
      () async {
        hub.modelList = null;
        Storage(Directory('${dir.path}/data')).writePrefs(PrefsData(engineFolder: '${dir.path}/own'));
        final c = make(fromAppImage: false);
        await c.read(updatesProvider.notifier).check();
        final s = c.read(updatesProvider);
        expect(s.models, isEmpty);
        expect(s.engine, isNull);
        expect(s.app!.manual, contains('not started from its AppImage'));
        expect(s.updatable, isFalse);

        Storage(Directory('${dir.path}/data')).writePrefs(const PrefsData());
        File('$main/engine/build.json').deleteSync();
        final again = make();
        await again.read(updatesProvider.notifier).check();
        expect(again.read(updatesProvider).engine, isNull);
      },
    );

    test('a data file the newest version adds is downloaded beside the model; an unsigned list offers nothing', () async {
      final corr = utf8.encode('correction data');
      hub.repo['m.correction'] = corr;
      final list = jsonDecode(hub.modelList!) as Map;
      final versions = list['versions'] as List;
      versions.add({
        'version': '3',
        'notes': 'the data as its own file',
        'files': {
          ...versions.last['files'] as Map,
          'm.gguf': {'sha256': _sha(oldWeights), 'size': oldWeights.length},
          'm.correction': {'sha256': _sha(corr), 'size': corr.length},
        },
      });
      hub.modelList = jsonEncode(list);
      final c = make();
      await c.read(updatesProvider.notifier).check();
      expect(c.read(updatesProvider).models.single.files.keys, ['m.correction']);
      await c.read(updatesProvider.notifier).update();
      expect(File('$main/models/m.correction').readAsBytesSync(), corr);
      expect(File('$main/models/m.gguf').readAsBytesSync(), oldWeights, reason: 'the weights did not change');

      // a list whose signature does not verify is not read at all
      checkKey = base64.encode(List.filled(32, 9));
      addTearDown(useTestKey);
      File('$main/models/m.correction').deleteSync();
      await c.read(updatesProvider.notifier).check();
      expect(c.read(updatesProvider).models, isEmpty);
    });

    test('a failed check says nothing', () async {
      final c = make();
      await hub.server.close(force: true);
      await c.read(updatesProvider.notifier).check();
      expect(c.read(updatesProvider).any, isFalse);
    });

    Future<void> refused(ProviderContainer c, String says) async {
      await c.read(updatesProvider.notifier).check();
      await c.read(updatesProvider.notifier).update();
      final s = c.read(updatesProvider);
      expect(s.message, says);
      expect(s.updating, isFalse);
      expect(backend.calls, isNot(contains('stop')));
      expect(File(appImage).readAsStringSync(), 'old app');
      expect(File('$main/models/m.gguf').readAsBytesSync(), oldWeights);
    }

    test('Update waits while a reply is being written', () async {
      final c = make();
      await c.read(catalogProvider.future);
      c.read(chatsProvider.notifier).send('hello', _file);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await refused(c, 'A reply is being written - update when it finishes.');
    });

    test('Update waits while a benchmark runs or a model is hosted', () async {
      await refused(
        make(extra: [benchmarkProvider.overrideWith(_Measuring.new)]),
        'A benchmark is running - update when it finishes.',
      );
      await refused(
        make(extra: [serveProvider.overrideWith(_Hosting.new)]),
        'A model is hosted - update when hosting ends.',
      );
    });

    test('Update puts everything in place: the engine, the model, then the AppImage and a restart', () async {
      final c = make();
      await c.read(updatesProvider.notifier).check();
      await c.read(updatesProvider.notifier).update();
      final s = c.read(updatesProvider);
      expect(s.message, isNull, reason: '${s.message}');
      expect(backend.calls, ['stop']);
      expect(File('$main/engine/llama-server').readAsStringSync(), 'new engine');
      expect(installedEngine('$main/engine')!.version, 'v0.2.0');
      expect(File('$main/models/m.gguf').readAsBytesSync(), newWeights);
      expect(File('$main/models/m.vram.json').readAsBytesSync(), vram);
      expect(Directory('$main/models/$updateFolderName').existsSync(), isFalse);
      expect(File(appImage).readAsStringSync(), 'new app');
      expect(File(appImage).statSync().mode & 0x49, 0x49, reason: 'runnable');
      expect(Directory('${dir.path}/apps').listSync().length, 1, reason: 'no download left beside it');
      expect(relaunched, 1);
      expect(s.any, isFalse);
    });

    testWidgets('the arrow appears; the page lists every version\'s notes, newest first, with the sizes', (
      tester,
    ) async {
      final c = make();
      await tester.runAsync(() => c.read(updatesProvider.notifier).check());
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const Scaffold(
              body: Column(
                children: [
                  UpdateButton(),
                  Expanded(child: UpdatePage()),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('update-button')), findsOneWidget);
      final app = find.textContaining('Run My AI v9.2.0');
      final second = find.text('second new', findRichText: true),
          first = find.textContaining('first', findRichText: true);
      expect(app, findsOneWidget);
      expect(find.textContaining('TokenWing engine v0.2.0'), findsOneWidget);
      expect(find.textContaining('Model · '), findsOneWidget);
      expect(find.text('better data', findRichText: true), findsOneWidget);
      expect(tester.getTopLeft(second.first).dy, lessThan(tester.getTopLeft(first.first).dy));
      expect(find.byKey(const Key('update-now')), findsOneWidget);
    });

    test('a bad checksum changes nothing: not the model, not the app', () async {
      // the list file promises other bytes than Hugging Face holds
      final list = jsonDecode(hub.modelList!) as Map;
      (list['versions'] as List).last['files']['m.gguf']['sha256'] = _sha(utf8.encode('something else'));
      hub.modelList = jsonEncode(list);
      hub.engineReleases.clear();
      final c = make();
      await c.read(updatesProvider.notifier).check();
      await c.read(updatesProvider.notifier).update();
      var s = c.read(updatesProvider);
      expect(s.failed, isTrue);
      expect(s.message, contains("does not match the model's update list"));
      expect(File('$main/models/m.gguf').readAsBytesSync(), oldWeights);
      expect(File('$main/models/$updateFolderName/m.gguf').existsSync(), isFalse);
      expect(relaunched, 0);

      // and an AppImage that does not match SHA256SUMS
      hub.modelList = null;
      hub.files['SHA256SUMS'] = utf8.encode('${_sha(utf8.encode('other'))}  RunMyAI-linux-x64.AppImage\n');
      hub.files['SHA256SUMS.sig'] = utf8.encode(testSign(hub.files['SHA256SUMS']!));
      final again = make();
      await again.read(updatesProvider.notifier).check();
      await again.read(updatesProvider.notifier).update();
      s = again.read(updatesProvider);
      expect(s.failed, isTrue);
      expect(s.message, contains('damaged'));
      expect(File(appImage).readAsStringSync(), 'old app');
      expect(Directory('${dir.path}/apps').listSync().length, 1);
      expect(relaunched, 0);
    });
  });
}
