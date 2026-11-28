import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../data/models.dart';
import 'folders.dart';
import 'hashing.dart';

/// Where the models are downloaded from.
final huggingFace = Uri.parse('https://huggingface.co');

/// One file of a model on Hugging Face: its name, size and checksum (SHA-256 for a large file; for a small one kept
/// in git itself, git's own SHA-1 of it).
class RemoteFile {
  const RemoteFile(this.name, this.size, {this.sha256, this.gitSha1});

  final String name;
  final int size;
  final String? sha256;
  final String? gitSha1;
}

/// Why a download stopped before its end, said for the user. [broken]: a file did not match its checksum and was
/// deleted.
class DownloadFailure implements Exception {
  const DownloadFailure(this.message, {this.broken = false});

  final String message;
  final bool broken;

  @override
  String toString() => message;
}

/// How far a download is: [done] of [total] bytes, how fast it goes, and whether a finished file is being checked.
class DownloadProgress {
  const DownloadProgress({required this.done, required this.total, this.bytesPerSecond, this.checking = false});

  final int done;
  final int total;
  final double? bytesPerSecond;
  final bool checking;
}

/// The sizes and checksums of [names] in [repo], from Hugging Face's list of the repo's files.
Future<List<RemoteFile>> remoteFiles(HttpClient client, Uri server, String repo, List<String> names) async {
  final response = await (await client.getUrl(server.resolve('/api/models/$repo/tree/main'))).close();
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) throw DownloadFailure(_refused(response.statusCode));
  final list = jsonDecode(body);
  final byName = {
    if (list is List)
      for (final e in list)
        if (e is Map && e['type'] == 'file' && e['path'] is String) e['path'] as String: e,
  };
  return [
    for (final name in names)
      switch (byName[name]) {
        {'lfs': {'oid': final String sha, 'size': final int size}} => RemoteFile(name, size, sha256: sha),
        {'oid': final String sha1, 'size': final int size} => RemoteFile(name, size, gitSha1: sha1),
        _ => throw DownloadFailure('$name is not on Hugging Face.'),
      },
  ];
}

String _refused(int status) => switch (status) {
  401 || 403 => 'Hugging Face did not allow the download (error $status).',
  404 => 'The model was not found on Hugging Face (error 404).',
  _ => 'Hugging Face answered with an error ($status).',
};

bool _retryable(int status) => status == 408 || status == 429 || status >= 500;

/// What has been downloaded of a file so far, kept next to it (`<name>.part.json`) so a download continues where it
/// stopped, also after the app was closed: the file's size and checksum, and how many bytes from its start are
/// [written].
class PartRecord {
  PartRecord({required this.size, this.sha256, this.gitSha1, this.written = 0});

  final int size;
  final String? sha256;
  final String? gitSha1;
  int written;

  /// Whether this record is for that file (same size and checksum), so its bytes can be kept.
  bool isFor(RemoteFile f) => size == f.size && sha256 == f.sha256 && gitSha1 == f.gitSha1;

  Map<String, Object?> toJson() => {'size': size, 'sha256': sha256, 'gitSha1': gitSha1, 'written': written};

  /// The record in [file]; null when there is none or it cannot be read. A record of an older version of the app,
  /// which fetched a file in parts of `partBytes` (`done`: the parts written, `started`: the bytes written of each
  /// unfinished part), keeps the stretch written from the file's start.
  static PartRecord? read(File file) {
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map || json['size'] is! int) return null;
      final size = json['size'] as int;
      int? written;
      if (json['written'] case final int w) {
        written = w;
      } else if (json case {'partBytes': final int partBytes, 'done': final List done} when partBytes > 0) {
        final finished = done.whereType<int>().toSet();
        var i = 0;
        while (finished.contains(i)) {
          i++;
        }
        written = i * partBytes;
        if (json['started'] case final Map started) {
          if (started['$i'] case final int bytes when bytes > 0 && bytes < partBytes) written += bytes;
        }
      }
      if (written == null) return null;
      return PartRecord(
        size: size,
        sha256: json['sha256'] as String?,
        gitSha1: json['gitSha1'] as String?,
        written: written.clamp(0, size),
      );
    } on FileSystemException {
      // None.
    } on FormatException {
      // Damaged: started again.
    } on TypeError {
      // Damaged: started again.
    }
    return null;
  }

  void write(File file) {
    final tmp = File('${file.path}.tmp')..writeAsStringSync(jsonEncode(toJson()), flush: true);
    tmp.renameSync(file.path);
  }
}

String _join(String folder, String name) => '$folder${Platform.pathSeparator}$name';

/// How much of [file] is in [folder] while its download is unfinished (finished files and what is written of the
/// others), or null when no download of it was started there.
int? downloadedBytes(String folder, ModelFile file) {
  var started = false, bytes = 0;
  for (final name in file.parts) {
    final whole = File(_join(folder, name));
    final record = PartRecord.read(File(_join(folder, '$name.part.json')));
    if (record != null) {
      started = true;
      bytes += record.written;
    } else if (whole.existsSync()) {
      bytes += whole.lengthSync();
    }
  }
  return started ? bytes : null;
}

/// Deletes [file]'s files in [folder]: the finished ones, an unfinished download's `.part` file and record, and what
/// the engine learned about the model next to it (`<name>.usage.json`).
void deleteModelFiles(String folder, ModelFile file) {
  for (final name in file.parts) {
    for (final path in [name, '$name.part', '$name.part.json', '$name.part.json.tmp', '$name.usage.json']) {
      final f = File(_join(folder, path));
      _hashers.remove(f.path)?.close();
      if (f.existsSync()) f.deleteSync();
    }
  }
}

/// Whether the file at [path] matches [f]'s checksum. Read in its own isolate (SHA-256 at several GB/s with the
/// system's crypto library; slower where it is missing).
Future<bool> checksumMatches(String path, RemoteFile f) async {
  if (f.sha256 != null) return await sha256OfFile(path) == f.sha256;
  return _gitSha1Matches(path, f);
}

Future<bool> _gitSha1Matches(String path, RemoteFile f) => Isolate.run(() async {
  final stream = File(path).openRead();
  // git's SHA-1 of a file is that of "blob <size>\0" followed by the file
  late Digest digest;
  final sink = sha1.startChunkedConversion(ChunkedConversionSink<Digest>.withCallback((d) => digest = d.single));
  sink.add(utf8.encode('blob ${f.size}\x00'));
  await stream.forEach(sink.add);
  sink.close();
  return digest.toString() == f.gitSha1;
});

/// The running checksums of the unfinished downloads, by the path of their `.part` file. They stay while a download is
/// paused, so Resume in the same run of the app continues each where it was; after a restart the stretch written is
/// hashed again from its start, in the background while the rest comes.
final _hashers = <String, FileHasher>{};

/// How long a download's connection may send nothing before it is given up (a server can stop sending without closing the
/// connection, and the system would only give up on it after minutes).
const downloadIdleTimeout = Duration(seconds: 30);

/// One model's download into [folder]: its files one after another, each fetched with one streaming request and
/// written as it arrives to `<name>.part` next to where it goes, with its [PartRecord] (saved twice a second and when
/// it stops). A broken connection, a pause or a closed app continue with one new request from the last byte written,
/// as a browser does (Hugging Face counts every request to a file as one download). A finished file is checked against
/// Hugging Face's checksum and only then gets its name. [stop] pauses it (what is written stays).
class ModelDownload {
  ModelDownload(
    this.file,
    this.folder, {
    Uri? server,
    this.free = freeBytes,
    this.onProgress,
    this.onVerified,
    this.retryDelay = const Duration(seconds: 1),
    this.idleTimeout = downloadIdleTimeout,
    this.known,
  }) : server = server ?? huggingFace;

  /// The files' sizes and checksums when the caller knows them already (from a signed list): Hugging Face's own list
  /// of the repo's files is not read then.
  final List<RemoteFile>? known;

  final ModelFile file;
  final String folder;
  final Uri server;

  /// Free bytes on a drive (tests give their own).
  final Future<int?> Function(String path) free;
  final void Function(DownloadProgress progress)? onProgress;

  /// Called for each file that passed its check and got its name, with its path (updates keep its checksum from it).
  final void Function(String path, RemoteFile file)? onVerified;

  /// The wait before the first retry after a break; each further retry with nothing new written waits twice as long.
  final Duration retryDelay;

  /// How long the connection may send nothing before it is dropped and the download continues on a new one.
  final Duration idleTimeout;

  HttpClient? _client;
  var _stopped = false;
  var _base = 0, _total = 0, _flowing = 0, _saved = 0;
  PartRecord? _record;
  FileHasher? _hasher;
  // the last file's check after its last byte: the Store says "Checking..." then
  var _checking = false;
  // the records of the files not finished yet, so their written bytes count from the first progress on
  final _kept = <String, PartRecord>{};
  File? _recordFile;
  final _speed = <(int, int)>[];

  /// Stops the download; [run] then returns false. What is written stays, to be continued.
  void stop() {
    _stopped = true;
    _client?.close(force: true);
  }

  int get _done => _base + _kept.values.fold<int>(0, (sum, r) => sum + r.written) + _flowing;

  /// Downloads every file not yet there. True when all are there and checked; false when [stop] was called. Throws
  /// [DownloadFailure].
  Future<bool> run() async {
    final client = _client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    Timer? ticks;
    try {
      Directory(folder).createSync(recursive: true);
      final List<RemoteFile> files;
      try {
        files = known ?? await remoteFiles(client, server, file.repo!, file.parts);
      } on IOException {
        if (_stopped) return false;
        throw const DownloadFailure('Could not reach Hugging Face. Check the internet connection, then press Resume.');
      }
      if (_stopped) return false;
      _total = files.fold(0, (sum, f) => sum + f.size);
      var needed = spareBytes;
      for (final f in files) {
        final record = PartRecord.read(File(_join(folder, '${f.name}.part.json')));
        if (_finished(f)) {
          _base += f.size;
        } else if (record != null && record.isFor(f) && File(_join(folder, '${f.name}.part')).existsSync()) {
          _kept[f.name] = record;
          needed += f.size - record.written;
        } else {
          needed += f.size;
        }
      }
      final room = await free(folder);
      if (_stopped) return false;
      if (room != null && room < needed) {
        throw DownloadFailure(
          'Not enough free space. Free ${((needed - room) / 1e9).toStringAsFixed(1)} GB on the drive of $folder '
          '(the download needs ${((needed - spareBytes) / 1e9).toStringAsFixed(1)} GB and 0.5 GB to spare), then '
          'press Resume.',
        );
      }
      ticks = Timer.periodic(const Duration(milliseconds: 500), (_) {
        _tell();
        _save();
      });
      _tell();
      for (final f in files) {
        if (_finished(f)) continue;
        if (!await _fetch(client, f)) return false;
        _base += f.size;
        _kept.remove(f.name);
        _record = null;
      }
      return true;
    } finally {
      ticks?.cancel();
      client.close(force: true);
    }
  }

  bool _finished(RemoteFile f) {
    final whole = File(_join(folder, f.name));
    return whole.existsSync() && whole.lengthSync() == f.size && !File('${whole.path}.part.json').existsSync();
  }

  /// Writes the file's record when it has changed since it was last written.
  void _save() {
    final record = _record, file = _recordFile;
    if (record == null || file == null || record.written == _saved) return;
    try {
      record.write(file);
      _saved = record.written;
    } on FileSystemException {
      // The drive is gone or full: the file's own writes fail and say so.
    }
  }

  void _tell() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _speed
      ..add((now, _done))
      ..removeWhere((s) => now - s.$1 > 5000);
    final first = _speed.first, last = _speed.last;
    final seconds = (last.$1 - first.$1) / 1000;
    onProgress?.call(
      DownloadProgress(
        done: _done,
        total: _total,
        bytesPerSecond: seconds >= 1 ? (last.$2 - first.$2) / seconds : null,
        checking: _checking,
      ),
    );
  }

  /// One file: the rest of its bytes, then the check. False when stopped.
  Future<bool> _fetch(HttpClient client, RemoteFile f) async {
    final part = File(_join(folder, '${f.name}.part'));
    final recordFile = File('${part.path}.json');
    var record = PartRecord.read(recordFile);
    if (record == null || !record.isFor(f) || !part.existsSync()) {
      _hashers.remove(part.path)?.close();
      if (part.existsSync()) part.deleteSync();
      part.createSync();
      record = PartRecord(size: f.size, sha256: f.sha256, gitSha1: f.gitSha1);
    }
    // never more than the file holds (the record of a file the system did not finish writing can be ahead of it);
    // written at once, so an older version's record is in this one's form from now on
    record
      ..written = min(record.written, part.lengthSync())
      ..write(recordFile);
    _record = _kept[f.name] = record;
    _recordFile = recordFile;
    _saved = record.written;
    // git's checksum is for small files only: those are checked whole at the end
    if (f.sha256 != null) {
      // a running checksum that went past the bytes kept starts again
      if ((_hashers[part.path]?.asked ?? 0) > record.written) _hashers.remove(part.path)!.close();
      _hasher = _hashers.putIfAbsent(part.path, () => FileHasher(part.path))..feed(record.written);
    }
    final url = server.resolve('/${file.repo}/resolve/main/${f.name}');
    final bool finished;
    FileHasher? hasher;
    try {
      finished = await _stream(client, url, part, record);
    } finally {
      _save();
      _recordFile = null;
      hasher = _hasher;
      _hasher = null;
    }
    if (!finished || _stopped) return false;

    _checking = true;
    _tell();
    final bool matches;
    try {
      matches = await _matches(part.path, f, hasher);
    } finally {
      _checking = false;
    }
    if (!matches) {
      part.deleteSync();
      recordFile.deleteSync();
      throw DownloadFailure('${f.name} was damaged in the download.', broken: true);
    }
    final whole = File(_join(folder, f.name));
    if (whole.existsSync()) whole.deleteSync();
    part.renameSync(whole.path);
    recordFile.deleteSync();
    onVerified?.call(whole.path, f);
    return true;
  }

  /// Whether the finished `.part` file matches its checksum: what the running hash has not taken yet is hashed now;
  /// if the running hash failed, the file is hashed again whole.
  Future<bool> _matches(String path, RemoteFile f, FileHasher? hasher) async {
    if (hasher == null) return checksumMatches(path, f);
    _hashers.remove(path);
    try {
      return await hasher.digest(f.size) == f.sha256;
    } on FileSystemException {
      return checksumMatches(path, f);
    }
  }

  /// Fetches the file from its first byte not yet written to its end with one request, and when the connection
  /// breaks, with one more from the last byte written (six tries in a row without a new byte at most). What came is
  /// written and recorded also when it stops. False when stopped.
  Future<bool> _stream(HttpClient client, Uri url, File part, PartRecord record) async {
    // (Append mode opens without cutting the file; whatever lies past the bytes recorded is cut and fetched again.)
    final out = await part.open(mode: FileMode.append);
    var pending = 0, tries = 0;
    final buffer = BytesBuilder(copy: false);
    // The bytes are counted as written only once they are in the file, so the progress never goes back.
    Future<void> flush() async {
      final bytes = buffer.takeBytes();
      // (never past the file's end, whatever the server sent)
      final keep = min(bytes.length, record.size - record.written);
      await out.writeFrom(bytes, 0, keep);
      record.written += keep;
      pending -= bytes.length;
      _flowing -= bytes.length;
      _hasher?.feed(record.written);
    }

    void drop() {
      buffer.clear();
      _flowing -= pending;
      pending = 0;
    }

    try {
      await out.truncate(record.written);
      await out.setPosition(record.written);
      while (record.written < record.size) {
        final from = record.written;
        try {
          final request = await client.getUrl(url);
          if (from > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
          final response = await request.close();
          final status = response.statusCode;
          if (from > 0 && (status == 200 || status == 416)) {
            // the server ignored the range and sends the whole file, or has no such range (the file changed): the
            // file starts over, from this answer (200) or from a new request without a range (416)
            await _restart(out, part, record);
            if (status == 416) {
              await response.drain<void>();
              continue;
            }
          } else if (status != 200 && status != 206) {
            await response.drain<void>();
            throw _Status(status);
          }
          await for (final data in response.timeout(idleTimeout)) {
            buffer.add(data);
            pending += data.length;
            _flowing += data.length;
            if (buffer.length >= 4 << 20) await flush();
          }
          await flush();
          if (record.written == record.size) return true;
          throw const SocketException('the connection ended early');
        } on FileSystemException catch (e) {
          drop();
          if (_stopped) return false;
          throw DownloadFailure('Could not write the download in $folder: ${e.osError?.message ?? e.message}');
        } on Exception catch (e) {
          // what came before the break is good: written, so the retry or the Resume continues after it
          try {
            await flush();
          } on FileSystemException {
            drop();
          }
          if (record.written == record.size) return true;
          if (_stopped) return false;
          if (e is _Status && !_retryable(e.status)) throw DownloadFailure(_refused(e.status));
          tries = record.written > from ? 1 : tries + 1;
          if (tries >= 6) {
            throw const DownloadFailure(
              'The download keeps breaking off. Check the internet connection, then press Resume.',
            );
          }
          await Future<void>.delayed(retryDelay * (1 << (tries - 1)));
          if (_stopped) return false;
        }
      }
      return true;
    } finally {
      await out.close();
    }
  }

  /// Cuts the file back to nothing and starts its running checksum again.
  Future<void> _restart(RandomAccessFile out, File part, PartRecord record) async {
    await out.truncate(0);
    await out.setPosition(0);
    record.written = 0;
    if (_hasher != null) {
      _hashers.remove(part.path)?.close();
      _hasher = _hashers[part.path] = FileHasher(part.path);
    }
  }
}

class _Status implements Exception {
  const _Status(this.status);
  final int status;
}
