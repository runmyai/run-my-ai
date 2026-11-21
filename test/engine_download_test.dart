// The engine download: which build is picked for a PC, the release files' names, SHA256SUMS, and the download itself
// against a local server that imitates GitHub's API and its files (pause and resume, a bad checksum, too little space,
// a failed unpack that leaves the old engine, no release yet).
// Run: flutter test test/engine_download_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/dummy_backend.dart';
import 'package:runmyai/benchmark/hardware.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/engine_download.dart';
import 'package:runmyai/engine/tuning.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/system/downloads.dart';
import 'package:runmyai/system/folders.dart';
import 'package:runmyai/system/signature.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/engine_setup.dart';

import 'signing.dart';

/// The app's folders in a test's own folder (never the real "Run My AI").
class _Folders extends FoldersNotifier {
  _Folders(this.main);
  final String main;

  @override
  FolderSet build() => FolderSet(main: main, models: '$main/models', chats: '$main/chats', cache: '$main/cache');
}

class _Files implements FileSource {
  _Files(this.files);
  final Map<String, String> files;

  @override
  String? read(String path) => files[path];

  @override
  List<String> list(String folder) => {
    for (final p in files.keys)
      if (p.startsWith('$folder/')) p.substring(folder.length + 1).split('/').first,
  }.toList();
}

DetectedGpu _nv(int mib) => (brand: GpuBrand.nvidia, mib: mib);
DetectedGpu _amd(int mib) => (brand: GpuBrand.amd, mib: mib);
DetectedGpu _other(int mib) => (brand: GpuBrand.other, mib: mib);

String _pick(List<DetectedGpu> gpus, {String os = 'linux', String arch = 'x64', bool cuda12 = false}) =>
    pickEngineBuild(os: os, arch: arch, gpus: gpus, cuda12: cuda12).build;

/// A .tar.gz with one top folder holding a runnable engine program, a library and a link to it. The library is 1 MB of
/// bytes that do not compress, so the archive arrives in several pieces.
List<int> _engineTar({bool withProgram = true}) {
  final random = Random(1);
  final archive = Archive()
    ..add(ArchiveFile.bytes('tokenwing/libggml.so.1', [for (var i = 0; i < 1 << 20; i++) random.nextInt(256)]))
    ..add(ArchiveFile.symlink('tokenwing/libggml.so', 'libggml.so.1'));
  if (withProgram) archive.add(ArchiveFile.string('tokenwing/llama-server', '#!/bin/sh\necho engine\n')..mode = 0x1ed);
  return GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive));
}

/// Imitates GitHub: the latest release at /repos/runmyai/tokenwing/releases/latest (404 while [release] is false), and
/// its files at `/dl/name`, answering ranges. Each archive request's Range header is kept in [ranges]. While [hold] is
/// set, an archive is sent up to its middle and then waits for it.
class _GitHub {
  late HttpServer server;
  final files = <String, List<int>>{};
  var release = true;
  final ranges = <String?>[];
  Completer<void>? hold;

  Uri get api => Uri.parse('http://127.0.0.1:${server.port}/repos/runmyai/tokenwing/releases/latest');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path, response = request.response;
      if (path == '/repos/runmyai/tokenwing/releases/latest') {
        if (!release) {
          response.statusCode = 404;
          response.write('{"message":"Not Found"}');
        } else {
          response.write(
            jsonEncode({
              'tag_name': 'v0.1.0',
              'assets': [
                for (final e in files.entries)
                  {
                    'name': e.key,
                    'size': e.value.length,
                    // GitHub's file links redirect to where the file is stored
                    'browser_download_url': 'http://127.0.0.1:${server.port}/redirect/${e.key}',
                  },
              ],
            }),
          );
        }
      } else if (path.startsWith('/redirect/')) {
        response.redirect(Uri.parse('/dl/${path.substring(10)}'));
        return;
      } else if (path.startsWith('/runmyai/tokenwing-files/resolve/main/') && store.containsKey(path.split('/').last)) {
        // the engine files on "Hugging Face", by checksum, answered in byte ranges
        final bytes = store[path.split('/').last]!;
        storeAsked.add(path.split('/').last);
        final range = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
        final first = range == null ? 0 : int.parse(range[1]!), last = range == null ? bytes.length - 1 : int.parse(range[2]!);
        response.statusCode = range == null ? 200 : 206;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $first-$last/${bytes.length}');
        response.add(bytes.sublist(first, last + 1));
      } else if (path.startsWith('/dl/') && files.containsKey(path.substring(4))) {
        final bytes = files[path.substring(4)]!;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        final archive = path.endsWith('.tar.gz');
        if (archive) ranges.add(range);
        var from = 0;
        if (range != null) {
          from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
          response.statusCode = 206;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $from-${bytes.length - 1}/${bytes.length}');
        }
        response.contentLength = bytes.length - from;
        final wait = archive ? hold : null;
        if (wait != null) {
          final middle = from + (bytes.length - from) ~/ 2;
          response.add(bytes.sublist(from, middle));
          await response.flush();
          await wait.future;
          response.add(bytes.sublist(middle));
        } else {
          response.add(bytes.sublist(from));
        }
      } else {
        response.statusCode = 404;
      }
      await response.close();
    });
  }

  final _sums = <String, String>{};

  /// The engine files by checksum, and which of them were asked for.
  final store = <String, List<int>>{};
  final storeAsked = <String>{};

  /// A release with a file list: [build] holds [files] (path to bytes, or to a link target with `link:`).
  void putFileList(String build, Map<String, Object> files) {
    final entries = <Map<String, Object>>[];
    for (final MapEntry(:key, :value) in files.entries) {
      if (value is String && value.startsWith('link:')) {
        entries.add({'path': key, 'link': value.substring(5)});
      } else {
        final bytes = value as List<int>, sha = '${sha256.convert(bytes)}';
        store[sha] = bytes;
        entries.add({'path': key, 'size': bytes.length, 'sha256': sha, if (key == 'llama-server') 'program': true});
      }
    }
    put(
      'engine-files.json',
      utf8.encode(
        jsonEncode({
          'format': 1,
          'version': 'v0.1.0',
          'store': 'http://127.0.0.1:${server.port}/runmyai/tokenwing-files/resolve/main/',
          'builds': {build: entries},
        }),
      ),
    );
  }

  void put(String name, List<int> archive, {String? sum}) {
    files[name] = archive;
    _sums[name] = sum ?? '${sha256.convert(archive)}';
    files['SHA256SUMS'] = utf8.encode([for (final e in _sums.entries) '${e.value}  ${e.key}\n'].join());
    files['SHA256SUMS.sig'] = utf8.encode(testSign(files['SHA256SUMS']!));
  }

  Future<EngineRelease> latest() async {
    final client = HttpClient();
    try {
      return (await latestEngineRelease(client, api))!;
    } finally {
      client.close();
    }
  }
}

void main() {
  // the widget tests' binding answers every HTTP request with 400; these tests talk to their own local server
  setUpAll(() {
    HttpOverrides.global = null;
    useTestKey();
  });

  group('the build picked for a PC', () {
    test('NVIDIA: CUDA 13, or CUDA 12 for old cards or drivers', () {
      expect(_pick([_nv(12227)]), 'cuda13');
      expect(_pick([_nv(8192)], cuda12: true), 'cuda12');
      // the cuda12 answer comes from nvidia-smi's lines: an old card, an old driver
      expect(_pick([_nv(8192)], cuda12: needsCuda12('6.1, 580.65.06')), 'cuda12');
      expect(_pick([_nv(8192)], cuda12: needsCuda12('8.6, 550.120')), 'cuda12');
      expect(_pick([_nv(8192)], os: 'windows'), 'cuda13');
    });

    test('AMD: ROCm on Linux, HIP on Windows', () {
      expect(_pick([_amd(16368)]), 'rocm');
      expect(_pick([_amd(16368)], os: 'windows'), 'hip');
    });

    test('other cards: Vulkan; none: CPU only', () {
      expect(_pick([_other(0)]), 'vulkan');
      expect(_pick([]), 'cpu');
      expect(_pick([], os: 'windows'), 'cpu');
    });

    test('ARM64: CUDA 13 with an NVIDIA GPU, else CPU only', () {
      // a DGX Spark's GB10 reports no memory of its own
      expect(_pick([_nv(0)], arch: 'arm64'), 'cuda13');
      expect(_pick([_nv(0)], arch: 'arm64', cuda12: true), 'cuda13');
      expect(_pick([], arch: 'arm64'), 'cpu');
      expect(_pick([_amd(16000)], arch: 'arm64'), 'cpu');
      expect(_pick([_nv(8192)], os: 'windows', arch: 'arm64'), 'cpu');
    });

    test('two makes: the one with more video memory, with the note', () {
      final a = pickEngineBuild(os: 'linux', arch: 'x64', gpus: [_nv(8192), _amd(24560)], cuda12: false);
      expect(a.build, 'rocm');
      expect(a.mixed, isTrue);
      final b = pickEngineBuild(os: 'linux', arch: 'x64', gpus: [_nv(24564), _amd(16368), _amd(4096)], cuda12: false);
      expect(b.build, 'cuda13');
      expect(b.mixed, isTrue);
    });

    test("a laptop's small built-in GPU beside a separate card is not a second make", () {
      // this laptop: RTX 5070 Ti + Radeon 890M with 512 MiB set aside
      final r = pickEngineBuild(os: 'linux', arch: 'x64', gpus: [_nv(12227), _amd(512)], cuda12: false);
      expect(r.build, 'cuda13');
      expect(r.mixed, isFalse);
      expect(pickEngineBuild(os: 'linux', arch: 'x64', gpus: [_nv(8192), _other(0)], cuda12: false).mixed, isFalse);
      // a built-in GPU alone still counts
      expect(_pick([_amd(512)]), 'rocm');
    });
  });

  test('the cards read on Linux: nvidia-smi and /sys/class/drm', () {
    final sys = _Files({
      '/sys/class/drm/card0/device/vendor': '0x10de\n',
      '/sys/class/drm/card1/device/vendor': '0x1002\n',
      '/sys/class/drm/card1/device/mem_info_vram_total': '536870912\n',
      '/sys/class/drm/card1-eDP-1/status': 'connected',
      '/sys/class/drm/card2/device/vendor': '0x8086\n',
      '/sys/class/drm/card3/device/vendor': '0x1af4\n',
    });
    expect(linuxGpus(nvidiaSmi: '12227\n', sys: sys), [_nv(12227), _amd(512), _other(0)]);
    expect(linuxGpus(nvidiaSmi: '[N/A]\n', sys: _Files({})), [_nv(0)]);
    // an NVIDIA card without NVIDIA's driver: only Vulkan can use it
    expect(linuxGpus(sys: _Files({'/sys/class/drm/card0/device/vendor': '0x10de'})), [_other(0)]);
  });

  test('the cards read on Windows', () {
    expect(
      windowsGpus('NVIDIA|4293918720\r\nAdvanced Micro Devices, Inc.|4293918720\r\nIntel Corporation|1073741824\r\n'),
      [_amd(4095), _other(0)],
    );
  });

  test('release file names per system, CPU and build', () {
    expect(engineAsset('linux', 'x64', 'cuda13'), 'tokenwing-linux-x64-cuda13.tar.gz');
    expect(engineAsset('linux', 'arm64', 'cpu'), 'tokenwing-linux-arm64-cpu.tar.gz');
    expect(engineAsset('windows', 'x64', 'hip'), 'tokenwing-windows-x64-hip.zip');
    expect(engineAsset('windows', 'arm64', 'cpu'), 'tokenwing-windows-arm64-cpu.zip');
    expect(engineBuilds('linux', 'x64'), ['cuda13', 'cuda12', 'rocm', 'vulkan', 'cpu']);
    expect(engineBuilds('linux', 'arm64'), ['cuda13', 'cpu']);
    expect(engineBuilds('windows', 'x64'), ['cuda13', 'cuda12', 'hip', 'vulkan', 'cpu']);
    expect(engineBuilds('windows', 'arm64'), ['cpu']);
  });

  test('SHA256SUMS', () {
    final a = 'a' * 64, b = 'B' * 64;
    expect(parseSha256Sums('$a  tokenwing-linux-x64-cpu.tar.gz\n$b *tokenwing-windows-x64-cpu.zip\r\nnot a line\n'), {
      'tokenwing-linux-x64-cpu.tar.gz': a,
      'tokenwing-windows-x64-cpu.zip': 'b' * 64,
    });
  });

  group('the download', () {
    late _GitHub github;
    late Directory main;
    late String engine;
    const asset = 'tokenwing-linux-x64-cpu.tar.gz';

    setUp(() async {
      github = _GitHub();
      await github.start();
      main = Directory.systemTemp.createTempSync('enginedl');
      engine = '${main.path}/engine';
    });

    tearDown(() async {
      github.hold?.complete();
      await github.server.close(force: true);
      main.deleteSync(recursive: true);
    });

    EngineDownload download(
      EngineRelease release, {
      int? free,
      void Function(DownloadProgress)? onProgress,
      Future<void> Function(String, String)? unpack,
    }) => EngineDownload(
      release: release,
      asset: asset,
      build: 'cpu',
      engineFolder: engine,
      free: (_) async => free ?? 1 << 40,
      onProgress: onProgress,
      unpack: unpack ?? unpackArchive,
    );

    test('no release yet (or the repo is not public): null', () async {
      github.release = false;
      final client = HttpClient();
      expect(await latestEngineRelease(client, github.api), isNull);
      client.close();
    });

    test('downloads, checks and installs; the program stays runnable and the archive goes', () async {
      github.put(asset, _engineTar());
      Directory(engine).createSync();
      File('$engine/old-file').writeAsStringSync('old engine');
      expect(await download(await github.latest()).run(), isTrue);
      final program = File('$engine/llama-server');
      expect(program.existsSync(), isTrue);
      expect(program.statSync().modeString(), startsWith('rwx'));
      expect(Link('$engine/libggml.so').targetSync(), 'libggml.so.1');
      expect(File('$engine/old-file').existsSync(), isFalse);
      expect(installedEngine(engine), (build: 'cpu', version: 'v0.1.0'));
      expect(main.listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last), ['engine']);
    });

    test('a release with a file list: only the files this engine lacks are downloaded; the rest is copied, links kept', () async {
      final shared = List<int>.generate(300000, (i) => i % 251), program = utf8.encode('#!/bin/sh\necho new engine\n');
      github.put(asset, _engineTar());
      github.putFileList('linux-x64-cpu', {
        'llama-server': program,
        'libggml.so.1': shared,
        'libggml.so': 'link:libggml.so.1',
      });
      Directory(engine).createSync();
      File('$engine/libggml.so.1').writeAsBytesSync(shared);
      File('$engine/llama-server').writeAsStringSync('old engine');
      expect(await download(await github.latest()).run(), isTrue);
      expect(github.storeAsked, {'${sha256.convert(program)}'}, reason: 'the file this engine already had is not downloaded');
      expect(github.ranges, isEmpty, reason: 'the whole package is not downloaded');
      expect(File('$engine/llama-server').readAsBytesSync(), program);
      expect(File('$engine/llama-server').statSync().modeString(), startsWith('rwx'));
      expect(File('$engine/libggml.so.1').readAsBytesSync(), shared);
      expect(Link('$engine/libggml.so').targetSync(), 'libggml.so.1');
      expect(installedEngine(engine), (build: 'cpu', version: 'v0.1.0'));
      expect(main.listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last), ['engine']);
    });

    test('a file list whose checksum is not the signed one installs nothing', () async {
      github.put(asset, _engineTar());
      github.putFileList('linux-x64-cpu', {'llama-server': utf8.encode('x')});
      github.files['engine-files.json'] = utf8.encode('{"format":1}');
      Directory(engine).createSync();
      File('$engine/llama-server').writeAsStringSync('old engine');
      await expectLater(download(await github.latest()).run(), throwsA(isA<DownloadFailure>()));
      expect(File('$engine/llama-server').readAsStringSync(), 'old engine');
    });

    test('an unsigned release, or one whose signature does not match, installs nothing', () async {
      github.put(asset, _engineTar());
      github.files['SHA256SUMS.sig'] = utf8.encode(testSign(utf8.encode('something else')));
      await expectLater(download(await github.latest()).run(), throwsA(isA<DownloadFailure>()));
      github.files.remove('SHA256SUMS.sig');
      await expectLater(download(await github.latest()).run(), throwsA(isA<DownloadFailure>()));
      expect(Directory(engine).existsSync(), isFalse);
    });

    test('a pause keeps what was written; Resume asks for the rest only', () async {
      final tar = _engineTar();
      github.put(asset, tar);
      github.hold = Completer();
      late EngineDownload first;
      first = download(
        await github.latest(),
        onProgress: (p) {
          if (p.done > 0) first.stop();
        },
      );
      expect(await first.run(), isFalse);
      final kept = first.part.lengthSync();
      expect(kept, tar.length ~/ 2);
      github.hold!.complete();
      github.hold = null;
      expect(await download(await github.latest()).run(), isTrue);
      expect(github.ranges, [null, 'bytes=$kept-']);
      expect(File('$engine/llama-server').existsSync(), isTrue);
    });

    test('a checksum that does not match: the file is deleted and nothing is installed', () async {
      github.put(asset, _engineTar(), sum: '0' * 64);
      final d = download(await github.latest());
      await expectLater(d.run(), throwsA(isA<DownloadFailure>().having((e) => e.broken, 'broken', isTrue)));
      expect(d.part.existsSync(), isFalse);
      expect(Directory(engine).existsSync(), isFalse);
    });

    test('too little space: says how much to free, downloads nothing', () async {
      final tar = _engineTar();
      github.put(asset, tar);
      final need = tar.length * 3 + 500 * 1000 * 1000;
      await expectLater(
        download(await github.latest(), free: need - 2000000000).run(),
        throwsA(isA<DownloadFailure>().having((e) => e.message, 'message', contains('Free 2.0 GB'))),
      );
      expect(github.ranges, isEmpty);
    });

    test('a failed unpack leaves the old engine as it was', () async {
      github.put(asset, _engineTar());
      Directory(engine).createSync();
      File('$engine/llama-server').writeAsStringSync('old');
      final d = download(
        await github.latest(),
        unpack: (archive, folder) async {
          File('$folder/tokenwing/half').createSync(recursive: true);
          throw const FileSystemException('disk full');
        },
      );
      await expectLater(d.run(), throwsA(isA<DownloadFailure>()));
      expect(File('$engine/llama-server').readAsStringSync(), 'old');
      expect(Directory('$engine.new').existsSync(), isFalse);
      // the checked archive stays, so trying again does not download it again
      expect(d.part.existsSync(), isTrue);
    });

    test('an archive without the engine program changes nothing', () async {
      github.put(asset, _engineTar(withProgram: false));
      await expectLater(download(await github.latest()).run(), throwsA(isA<DownloadFailure>()));
      expect(Directory(engine).existsSync(), isFalse);
      expect(Directory('$engine.new').existsSync(), isFalse);
    });
  });

  testWidgets(
    'the engine step: the build for this PC is chosen, Download, and the dialog closes once the engine is there',
    (tester) async {
      final github = _GitHub();
      final dir = Directory.systemTemp.createTempSync('enginedl-ui');
      addTearDown(() => dir.deleteSync(recursive: true));
      // the step reads the cards (nvidia-smi) and talks to the server: real time, not the test's clock
      await tester.runAsync(() async {
        await github.start();
        for (final b in engineBuilds(thisOs, thisArch)) {
          github.put(engineAsset(thisOs, thisArch, b), _engineTar());
        }
        addTearDown(() => github.server.close(force: true));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              storageProvider.overrideWithValue(Storage(dir)),
              foldersProvider.overrideWith(() => _Folders(dir.path)),
              backendProvider.overrideWithValue(DummyBackend()),
            ],
            child: MaterialApp(
              theme: buildTheme(Brightness.light),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => EngineSetup(releases: github.api),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        Future<void> until(Finder f) async {
          for (var i = 0; i < 400 && f.evaluate().isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
            await tester.pump();
          }
          expect(f, findsOneWidget);
        }

        await tester.tap(find.text('open'));
        await tester.pump();
        expect(find.byKey(const Key('engine-setup')), findsOneWidget);
        await until(find.byKey(const Key('engine-download')));
        expect(find.textContaining('for this PC'), findsOneWidget);
        // nothing is downloaded before the click
        expect(github.ranges, isEmpty);
        await tester.tap(find.byKey(const Key('engine-download')));
        // closed as soon as the engine is in place, with no pause on a "Ready" line
        for (var i = 0; i < 400 && find.byKey(const Key('engine-setup')).evaluate().isNotEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('engine-setup')), findsNothing);
        expect(File('${dir.path}/engine/llama-server').existsSync(), isTrue);
        expect(installedEngine('${dir.path}/engine')?.version, 'v0.1.0');
      });
    },
  );

  testWidgets('the engine step without a release says so and offers Try again', (tester) async {
    final github = _GitHub()..release = false;
    final dir = Directory.systemTemp.createTempSync('enginedl-ui');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.runAsync(() async {
      await github.start();
      addTearDown(() => github.server.close(force: true));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageProvider.overrideWithValue(Storage(dir)),
            foldersProvider.overrideWith(() => _Folders(dir.path)),
            backendProvider.overrideWithValue(DummyBackend()),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(body: EngineSetup(releases: github.api)),
          ),
        ),
      );
      for (var i = 0; i < 400 && find.byKey(const Key('engine-unavailable')).evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await tester.pump();
      }
      expect(find.text("The engine download isn't available yet."), findsOneWidget);
      expect(find.byKey(const Key('engine-retry')), findsOneWidget);
    });
  });
}
