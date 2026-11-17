import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';

import '../benchmark/hardware.dart';
import '../system/downloads.dart';
import '../system/folders.dart';
import '../system/github.dart';
import 'tuning.dart';

/// Where the engine's releases are listed: the latest release of TokenWing on GitHub.
Uri get engineReleases => gitHubApi().resolve('/repos/runmyai/tokenwing/releases/latest');

/// What the app needs to know of a graphics card to pick the engine build: its make and its own video memory.
enum GpuBrand { nvidia, amd, other }

typedef DetectedGpu = ({GpuBrand brand, int mib});

/// The engine builds released for a system ('linux' / 'windows') and CPU ('x64' / 'arm64'), in the order the list shows them.
List<String> engineBuilds(String os, String arch) => switch ((os, arch)) {
  ('windows', 'arm64') => const ['cpu'],
  ('windows', _) => const ['cuda13', 'cuda12', 'hip', 'vulkan', 'cpu'],
  (_, 'arm64') => const ['cuda13', 'cpu'],
  _ => const ['cuda13', 'cuda12', 'rocm', 'vulkan', 'cpu'],
};

/// The release file of one build, e.g. `tokenwing-linux-x64-cuda13.tar.gz`.
String engineAsset(String os, String arch, String build) =>
    'tokenwing-$os-$arch-$build.${os == 'windows' ? 'zip' : 'tar.gz'}';

/// What a build is called in the list.
String engineBuildLabel(String build) => switch (build) {
  'cuda13' => 'NVIDIA (CUDA 13)',
  'cuda12' => 'NVIDIA, older cards or drivers (CUDA 12)',
  'rocm' => 'AMD (ROCm)',
  'hip' => 'AMD (HIP)',
  'vulkan' => 'Other graphics cards (Vulkan)',
  'cpu' => 'No graphics card (CPU only)',
  _ => build,
};

/// The build that suits this PC: NVIDIA -> CUDA 13, or CUDA 12 when the cards or the driver are too old for it ([cuda12],
/// see needsCuda12); AMD -> ROCm (HIP on Windows); other cards -> Vulkan; none -> CPU only; an ARM64 PC: CUDA 13 with an
/// NVIDIA GPU (DGX Spark), else CPU only. With cards of two makes the make with more video memory is used ([mixed] is then
/// true). A card with less than 2 GiB of its own memory (a laptop's built-in GPU beside a separate card) counts only when
/// there is nothing else.
({String build, bool mixed}) pickEngineBuild({
  required String os,
  required String arch,
  required List<DetectedGpu> gpus,
  required bool cuda12,
}) {
  final big = gpus.where((g) => g.mib >= 2048).toList();
  final counted = big.isEmpty ? gpus : big;
  final memory = <GpuBrand, int>{};
  for (final g in counted) {
    memory[g.brand] = (memory[g.brand] ?? 0) + g.mib;
  }
  // ties go to the make listed first in GpuBrand
  final brand = GpuBrand.values
      .where(memory.containsKey)
      .fold<GpuBrand?>(null, (best, b) => best == null || memory[b]! > memory[best]! ? b : best);
  final offered = engineBuilds(os, arch);
  final wanted = switch (brand) {
    GpuBrand.nvidia => cuda12 && arch != 'arm64' ? 'cuda12' : 'cuda13',
    GpuBrand.amd => os == 'windows' ? 'hip' : 'rocm',
    GpuBrand.other => 'vulkan',
    null => 'cpu',
  };
  return (build: offered.contains(wanted) ? wanted : 'cpu', mixed: memory.length > 1);
}

/// The cards on a Linux PC: the NVIDIA ones from `nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits` ([nvidiaSmi],
/// null when it did not run; a card whose memory reads "[N/A]", like a DGX Spark's, counts with 0), the others from
/// /sys/class/drm: AMD with its video memory, Intel as "other", and an NVIDIA card without NVIDIA's driver as "other"
/// (only Vulkan can use it then). Other makes (a virtual machine's display) are left out.
/// shortcut: Intel's separate Arc cards count with 0 MiB (their memory is not read from sysfs yet).
List<DetectedGpu> linuxGpus({String? nvidiaSmi, required FileSource sys}) {
  final nvidia = [
    for (final line in const LineSplitter().convert(nvidiaSmi ?? ''))
      if (line.trim().isNotEmpty) (brand: GpuBrand.nvidia, mib: int.tryParse(line.trim()) ?? 0),
  ];
  const drm = '/sys/class/drm';
  final cards = [
    for (final n in sys.list(drm))
      if (RegExp(r'^card\d+$').hasMatch(n)) n,
  ]..sort();
  return [
    ...nvidia,
    for (final card in cards)
      ?switch (sys.read('$drm/$card/device/vendor')?.trim()) {
        '0x1002' => (
          brand: GpuBrand.amd,
          mib: (int.tryParse(sys.read('$drm/$card/device/mem_info_vram_total')?.trim() ?? '') ?? 0) >> 20,
        ),
        '0x8086' => (brand: GpuBrand.other, mib: 0),
        '0x10de' when nvidia.isEmpty => (brand: GpuBrand.other, mib: 0),
        _ => null,
      },
  ];
}

/// The cards on a Windows PC other than NVIDIA's (those come from nvidia-smi): lines of `maker|AdapterRAM bytes` from
/// Win32_VideoController.
/// shortcut: AdapterRAM stops at 4 GiB, so an AMD card beside an NVIDIA one with more than 4 GiB loses; read the registry's
/// qwMemorySize when Windows is tested.
List<DetectedGpu> windowsGpus(String text) => [
  for (final line in const LineSplitter().convert(text))
    if (line.split('|') case [final maker, final ram])
      ?switch (maker.toLowerCase()) {
        final m when m.contains('advanced micro') || m.contains('amd') || m.contains('ati ') => (
          brand: GpuBrand.amd,
          mib: (int.tryParse(ram.trim()) ?? 0) >> 20,
        ),
        final m when m.contains('intel') || m.contains('qualcomm') => (brand: GpuBrand.other, mib: 0),
        _ => null,
      },
];

/// This PC's system and CPU in the release files' words.
String get thisOs => Platform.isWindows ? 'windows' : 'linux';
String get thisArch => Abi.current() == Abi.linuxArm64 || Abi.current() == Abi.windowsArm64 ? 'arm64' : 'x64';

Future<String?> _run(String program, List<String> args) async {
  try {
    final r = await Process.run(program, args);
    return r.exitCode == 0 ? r.stdout as String : null;
  } on ProcessException {
    return null;
  }
}

/// The build for this PC, read from its cards (see [pickEngineBuild]).
Future<({String build, bool mixed})> pickEngineBuildHere() async {
  final smi = await _run('nvidia-smi', ['--query-gpu=memory.total', '--format=csv,noheader,nounits']);
  final gpus = [
    if (Platform.isWindows) ...[
      for (final line in const LineSplitter().convert(smi ?? ''))
        if (line.trim().isNotEmpty) (brand: GpuBrand.nvidia, mib: int.tryParse(line.trim()) ?? 0),
      ...windowsGpus(
        await _run('powershell', [
              '-NoProfile',
              '-Command',
              r"Get-CimInstance Win32_VideoController | ForEach-Object { $_.AdapterCompatibility + '|' + $_.AdapterRAM }",
            ]) ??
            '',
      ),
    ] else
      ...linuxGpus(nvidiaSmi: smi, sys: const DiskFiles()),
  ];
  var cuda12 = false;
  if (gpus.any((g) => g.brand == GpuBrand.nvidia)) {
    cuda12 = needsCuda12(
      await _run('nvidia-smi', ['--query-gpu=compute_cap,driver_version', '--format=csv,noheader']) ?? 'unreadable',
    );
  }
  return pickEngineBuild(os: thisOs, arch: thisArch, gpus: gpus, cuda12: cuda12);
}

// ---- The release --------------------------------------------------------------------------------------------------

/// One release of the engine: its tag (`v0.1.0`) and its files by name.
class EngineRelease {
  const EngineRelease(this.tag, this.assets);

  final String tag;
  final Map<String, ({Uri url, int size})> assets;
}

/// The checksums in a SHA256SUMS file (`sha256  name` per line; a `*` before the name marks binary mode), by name.
Map<String, String> parseSha256Sums(String text) => {
  for (final line in const LineSplitter().convert(text))
    if (RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$').firstMatch(line) case final m?) m[2]!: m[1]!.toLowerCase(),
};

/// The latest release from GitHub's API at [api]; null when there is none to be seen (no release yet, or the repo is not
/// public). Throws [DownloadFailure] when GitHub cannot be reached or refuses.
Future<EngineRelease?> latestEngineRelease(HttpClient client, Uri api) async {
  try {
    final request = await client.getUrl(api);
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw DownloadFailure('GitHub answered with an error (${response.statusCode}). Try again in a few minutes.');
    }
    final json = jsonDecode(body);
    if (json case {'tag_name': final String tag, 'assets': final List assets}) {
      return EngineRelease(tag, {
        for (final a in assets)
          if (a case {'name': final String name, 'size': final int size, 'browser_download_url': final String url})
            name: (url: Uri.parse(url), size: size),
      });
    }
    return null;
  } on IOException {
    throw const DownloadFailure('Could not reach GitHub. Check the internet connection, then try again.');
  } on FormatException {
    throw const DownloadFailure('GitHub sent an answer that could not be read. Try again in a few minutes.');
  }
}

// ---- The installed engine ------------------------------------------------------------------------------------------

/// The file in the engine folder that says which build and version were installed (for updates).
const installedFileName = 'build.json';

/// The build and version of the downloaded engine in [folder]; null when the engine there was not downloaded by the app.
({String build, String version})? installedEngine(String folder) {
  try {
    final json = jsonDecode(File('$folder${Platform.pathSeparator}$installedFileName').readAsStringSync());
    if (json case {'build': final String build, 'version': final String version}) {
      return (build: build, version: version);
    }
  } on FileSystemException {
    // Not downloaded.
  } on FormatException {
    // Damaged: treated as not downloaded.
  }
  return null;
}

/// The engine's program name on this system.
String get engineProgram => Platform.isWindows ? 'llama-server.exe' : 'llama-server';

// ---- The download -------------------------------------------------------------------------------------------------

/// The download of one engine build of [release] into [engineFolder]: fetched (continued where a pause left it, with
/// HTTP ranges) into `<asset>.<tag>.part` in the engine folder's parent, checked against the release's SHA256SUMS,
/// unpacked into a new folder beside it, and only when that is complete swapped in for the old engine. [stop] pauses
/// (what is written stays); [cancel] also deletes it.
class EngineDownload {
  EngineDownload({
    required this.release,
    required this.asset,
    required this.build,
    required this.engineFolder,
    this.free = freeBytes,
    this.onProgress,
    this.unpack = unpackArchive,
    this.beforeInstall,
  });

  final EngineRelease release;
  final String asset, build, engineFolder;
  final Future<int?> Function(String path) free;
  final void Function(DownloadProgress progress)? onProgress;

  /// Unpacks an archive into a folder (tests give a failing one).
  final Future<void> Function(String archive, String folder) unpack;

  /// Called once the download is checked, before the old engine is replaced (Settings stops a running engine here).
  final Future<void> Function()? beforeInstall;

  HttpClient? _client;
  var _stopped = false;
  final _speed = <(int, int)>[];

  String get _parent => Directory(engineFolder).parent.path;
  File get part => File('$_parent${Platform.pathSeparator}$asset.${release.tag}.part');

  void stop() {
    _stopped = true;
    _client?.close(force: true);
  }

  /// Stops and deletes what was downloaded.
  void cancel() {
    stop();
    try {
      part.deleteSync();
    } on FileSystemException {
      // Nothing written yet.
    }
  }

  /// Downloads, checks and installs the build. True when it is installed; false when [stop] was called. Throws
  /// [DownloadFailure].
  Future<bool> run() async {
    final file = release.assets[asset];
    final sumsFile = release.assets['SHA256SUMS'];
    if (file == null) throw DownloadFailure('This release has no $asset.');
    if (sumsFile == null) throw const DownloadFailure('This release has no checksums, so it was not installed.');
    final client = _client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    Timer? ticks;
    try {
      Directory(_parent).createSync(recursive: true);
      final String sums;
      try {
        final response = await (await client.getUrl(sumsFile.url)).close();
        sums = await response.transform(utf8.decoder).join();
        if (response.statusCode != 200) {
          throw DownloadFailure('GitHub answered with an error (${response.statusCode}).');
        }
      } on IOException {
        if (_stopped) return false;
        throw const DownloadFailure('Could not reach GitHub. Check the internet connection, then press Resume.');
      }
      final sha = parseSha256Sums(sums)[asset];
      if (sha == null) throw DownloadFailure('The release has no checksum for $asset, so it was not installed.');

      var have = part.existsSync() ? part.lengthSync() : 0;
      if (have > file.size) {
        part.deleteSync();
        have = 0;
      }
      // the packed file, the unpacked engine and the old engine until the swap
      final needed = file.size * 3 + spareBytes - have;
      final room = await free(_parent);
      if (_stopped) return false;
      if (room != null && room < needed) {
        throw DownloadFailure(
          'Not enough free space. Free ${((needed - room) / 1e9).toStringAsFixed(1)} GB on the drive of $_parent '
          '(the engine needs ${(file.size * 3 / 1e9).toStringAsFixed(1)} GB while it is unpacked, and 0.5 GB to '
          'spare), then try again.',
        );
      }

      var done = have;
      void tell({bool checking = false}) {
        final now = DateTime.now().millisecondsSinceEpoch;
        _speed
          ..add((now, done))
          ..removeWhere((s) => now - s.$1 > 5000);
        final seconds = (_speed.last.$1 - _speed.first.$1) / 1000;
        onProgress?.call(
          DownloadProgress(
            done: done,
            total: file.size,
            bytesPerSecond: seconds >= 1 ? (_speed.last.$2 - _speed.first.$2) / seconds : null,
            checking: checking,
          ),
        );
      }

      ticks = Timer.periodic(const Duration(milliseconds: 500), (_) => tell());
      tell();
      if (have < file.size) {
        try {
          final request = await client.getUrl(file.url);
          if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
          final response = await request.close();
          // a server that ignores the range sends the whole file again
          final append = response.statusCode == 206;
          if (!append && response.statusCode != 200) {
            await response.drain<void>();
            throw DownloadFailure('GitHub answered with an error (${response.statusCode}). Try again.');
          }
          if (!append) done = 0;
          final out = part.openWrite(mode: append ? FileMode.append : FileMode.write);
          try {
            await for (final data in response) {
              out.add(data);
              done += data.length;
            }
          } finally {
            await out.close();
          }
        } on IOException {
          if (_stopped) return false;
          throw const DownloadFailure('The download broke off. Check the internet connection, then press Resume.');
        }
        if (_stopped) return false;
        if (part.lengthSync() != file.size) {
          throw const DownloadFailure('The download broke off. Check the internet connection, then press Resume.');
        }
      }
      ticks.cancel();
      tell(checking: true);
      if (!await checksumMatches(part.path, RemoteFile(asset, file.size, sha256: sha))) {
        part.deleteSync();
        throw const DownloadFailure(
          'The engine was damaged in the download. Press Download to get it again.',
          broken: true,
        );
      }
      await beforeInstall?.call();
      await install(part.path);
      return true;
    } finally {
      ticks?.cancel();
      client.close(force: true);
    }
  }

  /// Unpacks [archive] into a new folder beside the engine folder and swaps it in for the old engine, then deletes the
  /// archive. A failed unpack leaves the old engine as it was.
  Future<void> install(String archive) async {
    final sep = Platform.pathSeparator;
    final fresh = Directory('$engineFolder.new'), old = Directory('$engineFolder.old');
    for (final d in [fresh, old]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
    try {
      await unpack(archive, fresh.path);
    } on Object catch (e) {
      if (fresh.existsSync()) fresh.deleteSync(recursive: true);
      throw DownloadFailure('The engine could not be unpacked ($e). Nothing was changed; try again.');
    }
    // the archive holds one top folder with the engine in it
    final inside = fresh.listSync();
    final top = inside.length == 1 && inside.single is Directory ? inside.single.path : fresh.path;
    if (!File('$top$sep$engineProgram').existsSync()) {
      fresh.deleteSync(recursive: true);
      throw const DownloadFailure('The download did not hold the engine. Nothing was changed.');
    }
    File('$top$sep$installedFileName')
        .writeAsStringSync(jsonEncode({'build': build, 'version': release.tag, 'asset': asset}));
    final engine = Directory(engineFolder);
    try {
      if (engine.existsSync()) engine.renameSync(old.path);
      Directory(top).renameSync(engineFolder);
    } on FileSystemException {
      if (old.existsSync()) old.renameSync(engineFolder);
      if (fresh.existsSync()) fresh.deleteSync(recursive: true);
      throw const DownloadFailure('The new engine could not be put in place (is it running?). Nothing was changed.');
    }
    for (final d in [old, fresh]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
    // this download and any other build's paused one
    for (final f in Directory(_parent).listSync()) {
      final name = f.uri.pathSegments.last;
      if (f is File && name.startsWith('tokenwing-') && name.endsWith('.part')) f.deleteSync();
    }
  }
}

/// Unpacks a .tar.gz or .zip into [folder], keeping the programs' permissions and links (in its own isolate: it takes
/// a while).
Future<void> unpackArchive(String archive, String folder) =>
    Isolate.run(() => extractFileToDisk(archive, folder, verify: true));
