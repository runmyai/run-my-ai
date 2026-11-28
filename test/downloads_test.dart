// Model downloads: parts over several connections, continuing after a stop, checksums, the space check, the line of
// downloads in the Store. Against a small local server that answers as Hugging Face does.
// Run: flutter test test/downloads_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/system/chime.dart';
import 'package:runmyai/system/downloads.dart';
import 'package:runmyai/system/folders.dart';

/// A stand-in for Hugging Face: each repo's file list with sizes and checksums, and the files, redirected to another
/// address as Hugging Face does, served in the byte ranges asked.
class _Hub {
  _Hub(this.repos);

  /// Repo -> file name -> its bytes.
  final Map<String, Map<String, List<int>>> repos;

  /// The ranges asked, as "name first-last", in order.
  final asked = <String>[];

  /// Files the list says another checksum for.
  final wrongChecksum = <String>{};

  /// How many answers to cut short (the connection ends half way).
  var cutShort = 0;

  /// How many answers send half their bytes and then hang, as a connection does when the download is paused.
  var hangHalfWay = 0;

  /// The status every file request gets instead of the file.
  int? refuse;

  /// The wait before each part is sent.
  var delay = Duration.zero;

  /// When set, each part waits up to 15 ms more, so the parts finish out of order.
  Random? jitter;

  late HttpServer _server;

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_answer);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _answer(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;
    for (final MapEntry(key: repo, value: files) in repos.entries) {
      if (path == '/api/models/$repo/tree/main') {
        response.write(
          jsonEncode([
            {'type': 'directory', 'path': 'onnx', 'oid': '0', 'size': 0},
            for (final MapEntry(key: name, value: bytes) in files.entries)
              if (name.endsWith('.json'))
                {
                  'type': 'file',
                  'path': name,
                  'size': bytes.length,
                  'oid': _gitSha1(bytes, wrong: wrongChecksum.contains(name)),
                }
              else
                {
                  'type': 'file',
                  'path': name,
                  'size': bytes.length,
                  'oid': 'pointer',
                  'lfs': {'oid': _sha256(bytes, wrong: wrongChecksum.contains(name)), 'size': bytes.length},
                },
          ]),
        );
        return response.close();
      }
      if (path.startsWith('/$repo/resolve/main/')) {
        if (refuse case final status?) {
          response.statusCode = status;
          return response.close();
        }
        return response.redirect(uri.resolve('/cdn/$repo/${path.split('/').last}'), status: HttpStatus.found);
      }
      if (path.startsWith('/cdn/$repo/')) {
        final name = path.split('/').last;
        final bytes = files[name]!;
        final range = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
        final first = range == null ? 0 : int.parse(range[1]!),
            last = range == null ? bytes.length - 1 : int.parse(range[2]!);
        asked.add('$name $first-$last');
        await Future<void>.delayed(delay + Duration(milliseconds: jitter?.nextInt(15) ?? 0));
        response.statusCode = range == null ? 200 : 206;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $first-$last/${bytes.length}');
        if (hangHalfWay > 0) {
          hangHalfWay--;
          response
            ..bufferOutput = false
            ..contentLength = last - first + 1;
          response.add(bytes.sublist(first, first + (last - first + 1) ~/ 2));
          await response.flush();
          return Completer<void>().future;
        }
        if (cutShort > 0) {
          cutShort--;
          response.add(bytes.sublist(first, first + (last - first + 1) ~/ 2));
        } else {
          response.add(bytes.sublist(first, last + 1));
        }
        return response.close();
      }
    }
    response.statusCode = 404;
    return response.close();
  }
}

String _sha256(List<int> bytes, {bool wrong = false}) => sha256.convert(wrong ? [...bytes, 0] : bytes).toString();

String _gitSha1(List<int> bytes, {bool wrong = false}) =>
    sha1.convert([...utf8.encode('blob ${bytes.length}\x00'), ...bytes, if (wrong) 0]).toString();

List<int> _random(int n, int seed) {
  final r = Random(seed);
  return [for (var i = 0; i < n; i++) r.nextInt(256)];
}

final _weights = _random(20000, 1), _data = utf8.encode('{"experts": [1, 2, 3]}');
const _model = ModelFile(
  id: 'm/q',
  quantization: 'q',
  sizeBytes: 20022,
  repo: 'o/m',
  parts: ['m.gguf', 'm.vram-experts.json'],
);

void main() {
  late Directory dir;
  late _Hub hub;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('runmyai-dl-');
    hub = _Hub({
      'o/m': {'m.gguf': _weights, 'm.vram-experts.json': _data},
    });
    await hub.start();
  });
  tearDown(() async {
    await hub.close();
    dir.deleteSync(recursive: true);
  });

  ModelDownload download({
    Future<int?> Function(String)? free,
    void Function(DownloadProgress)? onProgress,
    int connections = 4,
    int partBytes = 1000,
    Duration idleTimeout = const Duration(seconds: 30),
  }) => ModelDownload(
    _model,
    '${dir.path}/models',
    server: hub.uri,
    connections: connections,
    partBytes: partBytes,
    free: free ?? (_) async => 1 << 40,
    onProgress: onProgress,
    retryDelay: Duration.zero,
    idleTimeout: idleTimeout,
  );

  test('a part record splits the file into ranges and remembers the parts written', () {
    final record = PartRecord(size: 2500, partBytes: 1000, sha256: 'abc');
    expect(record.parts, 3);
    expect([for (var i = 0; i < 3; i++) record.range(i)], [(0, 999), (1000, 1999), (2000, 2499)]);
    record.done.addAll([0, 2]);
    record.started[1] = 300;
    expect(record.missing, [1]);
    expect(record.doneBytes, 1800);
    final file = File('${dir.path}/r.json');
    record.write(file);
    final back = PartRecord.read(file)!;
    expect(back.done, {0, 2});
    expect(back.started, {1: 300});
    // what an older version of the app wrote (no started parts) is read; a started count that does not fit is not
    file.writeAsStringSync('{"size": 2500, "partBytes": 1000, "sha256": "abc", "done": [0]}');
    expect(PartRecord.read(file)!.started, isEmpty);
    file.writeAsStringSync('{"size": 2500, "partBytes": 1000, "done": [0], "started": {"0": 5, "1": 1000, "2": 7}}');
    expect(PartRecord.read(file)!.started, {2: 7});
    expect(back.isFor(const RemoteFile('x', 2500, sha256: 'abc')), isTrue);
    expect(back.isFor(const RemoteFile('x', 2500, sha256: 'abd')), isFalse);
    expect(back.isFor(const RemoteFile('x', 2501, sha256: 'abc')), isFalse);
    expect(PartRecord(size: 0, partBytes: 1000).parts, 0);
  });

  test('every file comes in parts over several connections, is checked, and only then gets its name', () async {
    var checked = false;
    expect(await download(onProgress: (p) => checked |= p.checking).run(), isTrue);
    expect(File('${dir.path}/models/m.gguf').readAsBytesSync(), _weights);
    expect(File('${dir.path}/models/m.vram-experts.json').readAsBytesSync(), _data);
    expect(Directory('${dir.path}/models').listSync().map((e) => e.path.split('/').last).toSet(), {
      'm.gguf',
      'm.vram-experts.json',
    });
    expect(hub.asked.where((a) => a.startsWith('m.gguf')).length, 20);
    expect(checked, isTrue);
    expect(dir.listSync().length, 1);
    // A second run finds it all there.
    hub.asked.clear();
    expect(await download().run(), isTrue);
    expect(hub.asked, isEmpty);
  });

  test('stopped, it continues where it stopped: the parts written are not fetched again', () async {
    hub.delay = const Duration(milliseconds: 20);
    final first = download();
    final going = first.run();
    while (hub.asked.length < 6) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    first.stop();
    expect(await going, isFalse);
    final record = PartRecord.read(File('${dir.path}/models/m.gguf.part.json'))!;
    expect(record.done, isNotEmpty);
    expect(record.missing, isNotEmpty);
    expect(downloadedBytes('${dir.path}/models', _model), record.doneBytes);
    expect(File('${dir.path}/models/m.gguf').existsSync(), isFalse);

    hub.asked.clear();
    hub.delay = Duration.zero;
    expect(await download().run(), isTrue);
    expect(File('${dir.path}/models/m.gguf').readAsBytesSync(), _weights);
    for (final i in record.done) {
      expect(hub.asked, isNot(contains('m.gguf ${i * 1000}-${i * 1000 + 999}')));
    }
    expect(downloadedBytes('${dir.path}/models', _model), isNull);
  });

  test(
    'paused part way through a part, Resume continues it from its last byte; the progress never goes back',
    () async {
      hub.hangHalfWay = 1;
      final seen = <int>[];
      final first = download(connections: 1, onProgress: (p) => seen.add(p.done));
      final going = first.run();
      for (var i = 0; i < 200 && (seen.isEmpty || seen.last < 500); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(seen.last, 500, reason: 'the half that came counts');
      first.stop();
      expect(await going, isFalse);
      final record = PartRecord.read(File('${dir.path}/models/m.gguf.part.json'))!;
      expect(record.done, isEmpty);
      expect(record.started, {0: 500});
      expect(downloadedBytes('${dir.path}/models', _model), 500);

      hub.asked.clear();
      final again = <int>[];
      expect(await download(connections: 1, onProgress: (p) => again.add(p.done)).run(), isTrue);
      expect(hub.asked.first, 'm.gguf 500-999');
      expect(hub.asked, isNot(contains('m.gguf 0-999')));
      for (final (a, b) in [for (var i = 1; i < seen.length; i++) (seen[i - 1], seen[i])]) {
        expect(b, greaterThanOrEqualTo(a));
      }
      expect(again.first, greaterThanOrEqualTo(seen.last));
      for (final (a, b) in [for (var i = 1; i < again.length; i++) (again[i - 1], again[i])]) {
        expect(b, greaterThanOrEqualTo(a));
      }
      final whole = File('${dir.path}/models/m.gguf');
      expect(whole.readAsBytesSync(), _weights);
      expect(sha256.convert(whole.readAsBytesSync()).toString(), _sha256(_weights));
    },
  );

  test('a download paused by an older version of the app (larger parts, no started bytes) still finishes', () async {
    final models = Directory('${dir.path}/models')..createSync();
    File('${models.path}/m.gguf.part').writeAsBytesSync([..._weights.sublist(0, 8000), ...List.filled(3000, 0)]);
    File('${models.path}/m.gguf.part.json').writeAsStringSync(
      jsonEncode({
        'size': 20000,
        'partBytes': 8000,
        'sha256': _sha256(_weights),
        'gitSha1': null,
        'done': [0],
      }),
    );
    expect(await download().run(), isTrue);
    expect(File('${models.path}/m.gguf').readAsBytesSync(), _weights);
    expect(hub.asked.where((a) => a.startsWith('m.gguf')), ['m.gguf 8000-15999', 'm.gguf 16000-19999']);
  });

  test('the checksum is worked out as the parts arrive out of order, also across a pause; the check at the end says so '
      'until it is done', () async {
    for (final seed in [1, 2, 3]) {
      hub.jitter = Random(seed);
      // a part size that does not divide the file
      final first = download(connections: 6, partBytes: 768);
      final going = first.run();
      while (hub.asked.length < 8) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      first.stop();
      expect(await going, isFalse);
      // after the check started, every progress says checking until the file has its name
      var checking = false, checkingDropped = false;
      final whole = File('${dir.path}/models/m.gguf');
      expect(
        await download(
          connections: 6,
          partBytes: 768,
          onProgress: (p) {
            if (p.checking) checking = true;
            if (checking && !p.checking && !whole.existsSync()) checkingDropped = true;
          },
        ).run(),
        isTrue,
      );
      expect(checking, isTrue);
      expect(checkingDropped, isFalse);
      expect(whole.readAsBytesSync(), _weights, reason: 'seed $seed');
      deleteModelFiles('${dir.path}/models', _model);
      hub.asked.clear();
    }
  });

  test('a connection that breaks off is retried, and the file is still right', () async {
    hub.cutShort = 3;
    expect(await download().run(), isTrue);
    expect(File('${dir.path}/models/m.gguf').readAsBytesSync(), _weights);
    final asked = hub.asked.where((a) => a.startsWith('m.gguf'));
    expect(asked.length, 23);
    // each of the three cut answers sent half its part, and its retry asked only for the other half
    final bytes = asked
        .map((a) => a.split(' ').last.split('-').map(int.parse).toList())
        .fold(0, (n, r) => n + r[1] - r[0] + 1);
    expect(bytes, _weights.length + 3 * 500);
  });

  test('a connection that stops sending without closing is dropped after the idle time, and the part continues', () async {
    hub.hangHalfWay = 2;
    expect(await download(idleTimeout: const Duration(milliseconds: 200)).run(), isTrue);
    expect(File('${dir.path}/models/m.gguf').readAsBytesSync(), _weights);
    // the two hung answers sent half their part; each retry asked only for the other half
    final asked = hub.asked.where((a) => a.startsWith('m.gguf'));
    final bytes = asked
        .map((a) => a.split(' ').last.split('-').map(int.parse).toList())
        .fold(0, (n, r) => n + r[1] - r[0] + 1);
    expect(bytes, _weights.length + 2 * 500);
  });

  test('a file that does not match its checksum is deleted and reported as damaged', () async {
    hub.wrongChecksum.add('m.gguf');
    await expectLater(download().run(), throwsA(isA<DownloadFailure>().having((e) => e.broken, 'broken', isTrue)));
    expect(File('${dir.path}/models/m.gguf').existsSync(), isFalse);
    expect(File('${dir.path}/models/m.gguf.part').existsSync(), isFalse);
    expect(File('${dir.path}/models/m.gguf.part.json').existsSync(), isFalse);
  });

  test('a small file is checked with git\'s checksum', () async {
    hub.wrongChecksum.add('m.vram-experts.json');
    await expectLater(download().run(), throwsA(isA<DownloadFailure>().having((e) => e.broken, 'broken', isTrue)));
    // The weights before it are kept.
    expect(File('${dir.path}/models/m.gguf').readAsBytesSync(), _weights);
  });

  test(
    'without the room for the files and 0.5 GB to spare, nothing is downloaded and the user is told how much to free',
    () async {
      await expectLater(
        download(free: (_) async => spareBytes).run(),
        throwsA(isA<DownloadFailure>().having((e) => e.message, 'message', contains('Free 0.0 GB'))),
      );
      await expectLater(
        download(free: (_) async => 1000).run(),
        throwsA(isA<DownloadFailure>().having((e) => e.message, 'message', contains('Not enough free space'))),
      );
      expect(hub.asked, isEmpty);
      // What is already there counts: the space needed shrinks.
      expect(await download(free: (_) async => spareBytes + 20022).run(), isTrue);
    },
  );

  test('a refusal (a private repo) is said plainly, not retried', () async {
    hub.refuse = 401;
    await expectLater(
      download().run(),
      throwsA(isA<DownloadFailure>().having((e) => e.message, 'message', contains('did not allow'))),
    );
  });

  group('the Store', () {
    late ProviderContainer container;
    late _Chime chime;
    const second = ModelFile(id: 'n/q', quantization: 'q', sizeBytes: 5000, repo: 'o/n', parts: ['n.gguf']);
    final secondBytes = _random(5000, 2);

    ProviderContainer open() {
      final c = ProviderContainer(
        overrides: [
          storageProvider.overrideWithValue(Storage(Directory('${dir.path}/data'))),
          backendProvider.overrideWithValue(_Backend([_model, second])),
          downloadServerProvider.overrideWithValue(hub.uri),
          chimeProvider.overrideWith((ref) => chime = _Chime(ref)),
        ],
      );
      c.read(libraryProvider);
      c.read(chimeProvider);
      return c;
    }

    setUp(() {
      hub.repos['o/n'] = {'n.gguf': secondBytes};
      FolderSet(
        main: dir.path,
        models: '${dir.path}/models',
        chats: '${dir.path}/chats',
        cache: '${dir.path}/cache',
      ).save(Directory('${dir.path}/data'));
    });

    LibraryState library() => container.read(libraryProvider);

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 500 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(done(), isTrue);
    }

    test('one download at a time, the next waiting in line; each done one rings', () async {
      container = open();
      addTearDown(container.dispose);
      await container.read(catalogProvider.future);
      final notifier = container.read(libraryProvider.notifier);
      notifier.download(_model);
      notifier.download(second);
      expect(library().downloads['n/q']?.phase, DownloadPhase.queued);
      expect(library().downloads['m/q']?.phase, isNot(DownloadPhase.queued));
      await until(() => library().downloaded.containsAll(['m/q', 'n/q']));
      expect(library().downloads, isEmpty);
      expect(library().picked, 'm/q');
      // Every part of the first came before any of the second.
      final firstOfSecond = hub.asked.indexWhere((a) => a.startsWith('n.gguf'));
      expect(hub.asked.skip(firstOfSecond).where((a) => a.startsWith('m.')), isEmpty);
      expect(chime.rings, 2);
      expect(File('${dir.path}/models/n.gguf').readAsBytesSync(), secondBytes);
    });

    test('a waiting download paused stays out of line; Resume puts it back; Cancel deletes what was written', () async {
      container = open();
      addTearDown(container.dispose);
      await container.read(catalogProvider.future);
      final notifier = container.read(libraryProvider.notifier);
      hub.delay = const Duration(milliseconds: 10);
      notifier.download(_model);
      notifier.download(second);
      notifier.pause('n/q');
      expect(library().downloads['n/q']?.phase, DownloadPhase.paused);
      await until(() => library().downloaded.contains('m/q'));
      expect(hub.asked.any((a) => a.startsWith('n.gguf')), isFalse);

      hub.delay = const Duration(seconds: 1);
      notifier.download(second);
      await until(() => hub.asked.any((a) => a.startsWith('n.gguf')));
      await notifier.cancel('n/q');
      expect(library().downloads.containsKey('n/q'), isFalse);
      expect(Directory('${dir.path}/models').listSync().where((e) => e.path.contains('n.gguf')), isEmpty);
    });

    test(
      'an unfinished download shows as paused after the app was closed, and a model in the folder as downloaded',
      () async {
        // A download stopped part way, as when the app is closed.
        hub.delay = const Duration(milliseconds: 20);
        final first = download();
        final going = first.run();
        while (hub.asked.length < 6) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        first.stop();
        expect(await going, isFalse);
        File('${dir.path}/models/n.gguf').writeAsBytesSync(secondBytes);

        container = open();
        addTearDown(container.dispose);
        await container.read(catalogProvider.future);
        await until(() => library().downloads['m/q'] != null);
        final status = library().downloads['m/q']!;
        expect(status.phase, DownloadPhase.paused);
        expect(status.done, greaterThan(0));
        expect(library().downloaded, {'n/q'});
        hub.delay = Duration.zero;
        container.read(libraryProvider.notifier).download(_model);
        await until(() => library().downloaded.contains('m/q'));
        expect(File('${dir.path}/models/m.gguf').readAsBytesSync(), _weights);
      },
    );

    test('a failed download says why and can be resumed', () async {
      container = open();
      addTearDown(container.dispose);
      await container.read(catalogProvider.future);
      hub.refuse = 403;
      container.read(libraryProvider.notifier).download(second);
      await until(() => library().downloads['n/q']?.phase == DownloadPhase.failed);
      expect(library().downloads['n/q']?.message, contains('did not allow'));
      hub.refuse = null;
      container.read(libraryProvider.notifier).download(second);
      await until(() => library().downloaded.contains('n/q'));
    });
  });

  test('a public Hugging Face model downloads and passes its checksums', () async {
    // Small files of a public repo (no token): the real redirects, ranges and both kinds of checksum.
    const tiny = ModelFile(
      id: 'tiny/gpt2',
      quantization: '',
      sizeBytes: 454671,
      repo: 'hf-internal-testing/tiny-random-gpt2',
      parts: ['model.safetensors', 'config.json'],
    );
    try {
      final ok = await ModelDownload(tiny, '${dir.path}/hf', partBytes: 100000, free: (_) async => 1 << 40).run();
      expect(ok, isTrue);
      expect(File('${dir.path}/hf/model.safetensors').lengthSync(), 453864);
      expect(jsonDecode(File('${dir.path}/hf/config.json').readAsStringSync())['model_type'], 'gpt2');
    } on DownloadFailure catch (e) {
      if (e.message.startsWith('Could not reach')) return markTestSkipped('no internet');
      rethrow;
    }
  });
}

/// Counts the sounds instead of playing them.
class _Chime extends Chime {
  _Chime(Ref ref) : super(ref, null, Duration.zero);

  int rings = 0;

  @override
  Future<void> play() async => rings++;
}

class _Backend implements Backend {
  _Backend(this.files);

  final List<ModelFile> files;

  @override
  Future<List<CatalogModel>> loadCatalog() async => [
    for (final f in files)
      CatalogModel(
        id: f.id,
        name: f.id,
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
        files: [f],
      ),
  ];

  @override
  Stream<double> download(ModelFile file) => const Stream.empty();

  @override
  Future<void> deleteDownload(ModelFile file) async {}

  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) => const Stream.empty();

  @override
  Map<int, String> autoCommands(ModelFile file) => const {65536: '-c 65536'};

  @override
  int maxContext(ModelFile file) => 65536;
}
