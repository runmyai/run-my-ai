import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import '../data/models.dart';
import '../engine/engine_download.dart';
import 'downloads.dart';
import 'folders.dart';

/// Where new versions of the app and the engine are listed.
const appReleasesPath = '/repos/runmyai/run-my-ai/releases';
const engineReleasesPath = '/repos/runmyai/tokenwing/releases';

/// The website, for a new version the app cannot put in place itself.
const websiteUrl = 'https://runmyai.org';

/// Compares two versions like `v0.2.1` (semantic versions; a leading `v` and build metadata after `+` are ignored, a
/// pre-release such as `0.2.0-beta` comes before `0.2.0`): negative when [a] is older than [b], 0 when equal.
int compareVersions(String a, String b) {
  (List<int>, String?) split(String v) {
    final plain = (v.startsWith('v') || v.startsWith('V') ? v.substring(1) : v).split('+').first;
    final dash = plain.indexOf('-');
    final core = dash < 0 ? plain : plain.substring(0, dash);
    final numbers = [for (final p in core.split('.')) int.tryParse(p) ?? 0];
    while (numbers.length < 3) {
      numbers.add(0);
    }
    return (numbers, dash < 0 ? null : plain.substring(dash + 1));
  }

  final (na, pa) = split(a);
  final (nb, pb) = split(b);
  for (var i = 0; i < na.length || i < nb.length; i++) {
    final x = i < na.length ? na[i] : 0, y = i < nb.length ? nb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  if (pa == pb) return 0;
  if (pa == null) return 1;
  if (pb == null) return -1;
  return pa.compareTo(pb);
}

/// One release on GitHub: its tag, its text (the release notes, markdown) and its files by name.
class GitHubRelease {
  const GitHubRelease(this.tag, this.notes, this.assets);

  final String tag;
  final String notes;
  final Map<String, ({Uri url, int size})> assets;

  EngineRelease get asEngine => EngineRelease(tag, assets);
}

/// The published releases (not drafts, not pre-releases) at GitHub's API address [api]; empty when there are none to
/// be seen. Throws [DownloadFailure] when GitHub cannot be reached or refuses.
Future<List<GitHubRelease>> gitHubReleases(HttpClient client, Uri api) async {
  try {
    final request = await client.getUrl(api);
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode == 404) return const [];
    if (response.statusCode != 200) throw DownloadFailure('GitHub answered with an error (${response.statusCode}).');
    final json = jsonDecode(body);
    return [
      if (json is List)
        for (final r in json)
          if (r case {'tag_name': final String tag, 'assets': final List assets}
              when r['draft'] != true && r['prerelease'] != true)
            GitHubRelease(tag, r['body'] is String ? r['body'] as String : '', {
              for (final a in assets)
                if (a case {
                  'name': final String name,
                  'size': final int size,
                  'browser_download_url': final String url,
                })
                  name: (url: Uri.parse(url), size: size),
            }),
    ];
  } on IOException {
    throw const DownloadFailure('Could not reach GitHub.');
  } on FormatException {
    throw const DownloadFailure('GitHub sent an answer that could not be read.');
  }
}

/// The releases of [releases] newer than [current], newest first.
List<GitHubRelease> newerReleases(List<GitHubRelease> releases, String current) => [
  for (final r in releases)
    if (compareVersions(r.tag, current) > 0) r,
]..sort((a, b) => compareVersions(b.tag, a.tag));

/// The app's release file for a system and CPU; null where the app does not replace itself (Windows for now).
String? appAsset(String os, String arch) => os == 'linux' ? 'RunMyAI-linux-$arch.AppImage' : null;

// ---- Model updates ------------------------------------------------------------------------------------------------

/// A file's checksum and size in a model's list file.
typedef FileSum = ({String sha256, int size});

/// One version in a model's list file (`runmyai.json` in its Hugging Face repo).
typedef ModelVersion = ({String version, String notes, Map<String, FileSum> files});

/// The versions in a model's list file, oldest first; null when it is not one this app reads (format 1).
List<ModelVersion>? parseModelVersions(String text) {
  try {
    final json = jsonDecode(text);
    if (json case {'format': 1, 'versions': final List versions}) {
      return [
        for (final v in versions)
          if (v case {'version': final String version, 'files': final Map files})
            (
              version: version,
              notes: v['notes'] is String ? v['notes'] as String : '',
              files: {
                for (final MapEntry(:key, :value) in files.entries)
                  if ((key, value) case (final String name, {'sha256': final String sha, 'size': final int size}))
                    name: (sha256: sha.toLowerCase(), size: size),
              },
            ),
      ];
    }
  } on FormatException {
    // Not readable: no updates.
  }
  return null;
}

/// A model file on this PC: its size, and its checksum when one was kept from its download.
typedef LocalFile = ({String? sha256, int size});

/// What a model's update would change, given its list file's [versions] (oldest first) and its files on this PC
/// ([local], by file name): each file whose newest entry differs from the one here, with that entry, and the versions
/// since the oldest one the changed files were at (newest first, for their notes). Null when nothing differs. A file
/// is compared by its checksum, or by its size when no checksum was kept for it (never hashed here: a model file
/// takes minutes).
({List<ModelVersion> versions, Map<String, FileSum> files})? modelUpdate(
  List<ModelVersion> versions,
  Map<String, LocalFile> local,
) {
  final files = <String, FileSum>{};
  var since = versions.length;
  for (final MapEntry(key: name, value: here) in local.entries) {
    bool same(FileSum sum) => here.sha256 != null ? sum.sha256 == here.sha256 : sum.size == here.size;
    final listing = [
      for (var i = 0; i < versions.length; i++)
        if (versions[i].files.containsKey(name)) i,
    ];
    if (listing.isEmpty) continue;
    final newest = versions[listing.last].files[name]!;
    if (same(newest)) continue;
    files[name] = newest;
    // the version the file here is at (-1 when it is none of them: every version's notes are shown)
    final own = listing.lastWhere((i) => same(versions[i].files[name]!), orElse: () => -1);
    if (own < since) since = own;
  }
  if (files.isEmpty) return null;
  return (versions: versions.sublist(since + 1).reversed.toList(), files: files);
}

/// The checksums (SHA-256) of model files, kept in a small file with each file's size and time: a download's checksum
/// is kept as it is checked, so looking for updates never hashes a model file.
class FileHashes {
  FileHashes(this.store);

  final File store;

  Map<String, dynamic> _read() {
    try {
      final json = jsonDecode(store.readAsStringSync());
      if (json is Map<String, dynamic>) return json;
    } on FileSystemException {
      // None kept yet.
    } on FormatException {
      // Damaged: the files are hashed again.
    }
    return {};
  }

  /// The kept checksum of [path], if the file is still the one it was kept for (same size and time).
  String? known(String path) {
    final stat = File(path).statSync();
    if (stat.type != FileSystemEntityType.file) return null;
    if (_read()[path] case {'size': final int size, 'modified': final int modified, 'sha256': final String sha}
        when size == stat.size && modified == stat.modified.millisecondsSinceEpoch) {
      return sha;
    }
    return null;
  }

  void remember(String path, String sha256) {
    final stat = File(path).statSync();
    final all = _read()
      ..[path] = {'size': stat.size, 'modified': stat.modified.millisecondsSinceEpoch, 'sha256': sha256};
    try {
      store.parent.createSync(recursive: true);
      final tmp = File('${store.path}.tmp')..writeAsStringSync(jsonEncode(all), flush: true);
      tmp.renameSync(store.path);
    } on FileSystemException {
      // Not kept: hashed again next time.
    }
  }
}

Future<String> sha256Of(String path) =>
    Isolate.run(() async => (await sha256.bind(File(path).openRead()).first).toString());

String _join(String folder, String name) => '$folder${Platform.pathSeparator}$name';

/// The folder in a models folder where an update's files are downloaded before they are put in place.
const updateFolderName = '.runmyai-update';

/// Updates [files] of the model in [folder] (from [repo] on Hugging Face at [server]): each is downloaded into a
/// folder inside [folder] with the model download (continued after a stop, checked against Hugging Face's checksum),
/// checked against the list file's checksum, and only when every one passed are they all put in place of the old
/// ones. A failure leaves the model as it was. Throws [DownloadFailure].
Future<void> updateModelFiles({
  required String repo,
  required String folder,
  required Map<String, FileSum> files,
  Uri? server,
  FileHashes? hashes,
  void Function(DownloadProgress progress)? onProgress,
  Future<int?> Function(String path) free = freeBytes,
}) async {
  final staging = _join(folder, updateFolderName);
  final verified = <String, String>{};
  final download = ModelDownload(
    ModelFile(
      id: repo,
      quantization: '',
      sizeBytes: files.values.fold(0, (sum, f) => sum + f.size),
      repo: repo,
      parts: files.keys.toList(),
    ),
    staging,
    server: server,
    free: free,
    onProgress: onProgress,
    onVerified: (_, f) {
      if (f.sha256 != null) verified[f.name] = f.sha256!;
    },
  );
  if (!await download.run()) throw const DownloadFailure('The update stopped. Nothing was changed.');
  for (final MapEntry(key: name, value: sum) in files.entries) {
    final staged = _join(staging, name);
    // a file finished by an earlier try was not checked in this one (a small file has only git's checksum)
    final sha = verified[name] ?? await sha256Of(staged);
    if (sha != sum.sha256) {
      File(staged).deleteSync();
      throw DownloadFailure("$name does not match the model's update list, so nothing was changed.", broken: true);
    }
  }
  final moved = <String>[], placed = <String>[];
  try {
    for (final name in files.keys) {
      final whole = File(_join(folder, name));
      if (whole.existsSync()) {
        whole.renameSync(_join(staging, '$name.old'));
        moved.add(name);
      }
      File(_join(staging, name)).renameSync(whole.path);
      placed.add(name);
    }
  } on FileSystemException {
    for (final name in placed) {
      File(_join(folder, name)).renameSync(_join(staging, name));
    }
    for (final name in moved) {
      File(_join(staging, '$name.old')).renameSync(_join(folder, name));
    }
    throw const DownloadFailure('The new model files could not be put in place. Nothing was changed.');
  }
  for (final name in moved) {
    File(_join(staging, '$name.old')).deleteSync();
  }
  for (final name in placed) {
    hashes?.remember(_join(folder, name), files[name]!.sha256);
  }
  try {
    Directory(staging).deleteSync();
  } on FileSystemException {
    // Something else left there: kept.
  }
}

// ---- The app ------------------------------------------------------------------------------------------------------

/// Downloads [asset] of [release] next to the running AppImage at [appImage], checks it against the release's
/// SHA256SUMS and only then puts it in place of the running one (Linux lets a running program's file be replaced).
/// A failure leaves the app as it was. Throws [DownloadFailure].
Future<void> replaceAppImage({
  required GitHubRelease release,
  required String asset,
  required String appImage,
  void Function(DownloadProgress progress)? onProgress,
  Future<int?> Function(String path) free = freeBytes,
}) async {
  final file = release.assets[asset], sumsFile = release.assets['SHA256SUMS'];
  if (file == null) throw DownloadFailure('The new version has no $asset.');
  if (sumsFile == null) throw const DownloadFailure('The new version has no checksums, so it was not installed.');
  final dir = File(appImage).parent.path;
  final part = File(_join(dir, '.$asset.${release.tag}.part'));
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final response = await (await client.getUrl(sumsFile.url)).close();
    final sums = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) throw DownloadFailure('GitHub answered with an error (${response.statusCode}).');
    final sha = parseSha256Sums(sums)[asset];
    if (sha == null) throw DownloadFailure('The new version has no checksum for $asset, so it was not installed.');
    final room = await free(dir);
    if (room != null && room < file.size + spareBytes) {
      throw DownloadFailure(
        'Not enough free space. Free ${((file.size + spareBytes - room) / 1e9).toStringAsFixed(1)} GB on the drive '
        'of $dir, then try again.',
      );
    }
    final download = await (await client.getUrl(file.url)).close();
    if (download.statusCode != 200) {
      await download.drain<void>();
      throw DownloadFailure('GitHub answered with an error (${download.statusCode}).');
    }
    var done = 0;
    final out = part.openWrite();
    try {
      await for (final data in download) {
        out.add(data);
        done += data.length;
        onProgress?.call(DownloadProgress(done: done, total: file.size));
      }
    } finally {
      await out.close();
    }
    if (part.lengthSync() != file.size) throw const DownloadFailure('The download broke off. Try again.');
    onProgress?.call(DownloadProgress(done: done, total: file.size, checking: true));
    if (!await checksumMatches(part.path, RemoteFile(asset, file.size, sha256: sha))) {
      throw const DownloadFailure('The new version was damaged in the download. Try again.', broken: true);
    }
    final mode = await Process.run('chmod', ['755', part.path]);
    if (mode.exitCode != 0) throw const DownloadFailure('The new version could not be made runnable.');
    part.renameSync(appImage);
  } on IOException catch (e) {
    throw DownloadFailure(
      e is FileSystemException ? 'Could not write next to the app in $dir.' : 'The download broke off. Try again.',
    );
  } finally {
    client.close(force: true);
    if (part.existsSync()) part.deleteSync();
  }
}
