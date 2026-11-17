import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../data/models.dart';
import 'folders.dart';

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
/// stopped, also after the app was closed. The file is fetched in parts of [partBytes]; [done] are the parts written,
/// [started] how many bytes from its start are written of each part not finished yet (a record without it, from an
/// older version of the app, fetches those parts again from their start).
class PartRecord {
  PartRecord({
    required this.size,
    required this.partBytes,
    this.sha256,
    this.gitSha1,
    Set<int>? done,
    Map<int, int>? started,
  }) : done = done ?? {},
       started = started ?? {};

  final int size;
  final int partBytes;
  final String? sha256;
  final String? gitSha1;
  final Set<int> done;
  final Map<int, int> started;

  int get parts => size == 0 ? 0 : (size + partBytes - 1) ~/ partBytes;

  /// Part [i]'s first and last byte.
  (int, int) range(int i) => (i * partBytes, min(size, (i + 1) * partBytes) - 1);

  int get doneBytes =>
      done.fold(0, (sum, i) => sum + range(i).$2 - range(i).$1 + 1) +
      started.values.fold(0, (sum, bytes) => sum + bytes);

  /// The parts still to fetch, in order.
  List<int> get missing => [
    for (var i = 0; i < parts; i++)
      if (!done.contains(i)) i,
  ];

  /// Whether this record is for that file (same size and checksum), so its parts can be kept.
  bool isFor(RemoteFile f) => size == f.size && sha256 == f.sha256 && gitSha1 == f.gitSha1;

  Map<String, Object?> toJson() => {
    'size': size,
    'partBytes': partBytes,
    'sha256': sha256,
    'gitSha1': gitSha1,
    'done': done.toList()..sort(),
    'started': {for (final MapEntry(:key, :value) in started.entries) '$key': value},
  };

  /// The record in [file]; null when there is none or it cannot be read.
  static PartRecord? read(File file) {
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json case {'size': final int size, 'partBytes': final int partBytes, 'done': final List done}
          when partBytes > 0) {
        final record = PartRecord(
          size: size,
          partBytes: partBytes,
          sha256: json['sha256'] as String?,
          gitSha1: json['gitSha1'] as String?,
          done: done.whereType<int>().toSet(),
        );
        // only what lies inside an unfinished part counts; anything else is fetched again
        if (json['started'] case final Map started) {
          for (final MapEntry(:key, :value) in started.entries) {
            final i = int.tryParse('$key');
            if (i == null || value is! int || i < 0 || i >= record.parts || record.done.contains(i)) continue;
            final (first, last) = record.range(i);
            if (value > 0 && value <= last - first) record.started[i] = value;
          }
        }
        return record;
      }
    } on FileSystemException {
      // None.
    } on FormatException {
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

/// How much of [file] is in [folder] while its download is unfinished (finished files and the parts of the others),
/// or null when no download of it was started there.
int? downloadedBytes(String folder, ModelFile file) {
  var started = false, bytes = 0;
  for (final name in file.parts) {
    final whole = File(_join(folder, name));
    final record = PartRecord.read(File(_join(folder, '$name.part.json')));
    if (record != null) {
      started = true;
      bytes += record.doneBytes;
    } else if (whole.existsSync()) {
      bytes += whole.lengthSync();
    }
  }
  return started ? bytes : null;
}

/// Deletes [file]'s files in [folder]: the finished ones, an unfinished download's parts and records, and what the
/// engine learned about the model next to it (`<name>.usage.json`).
void deleteModelFiles(String folder, ModelFile file) {
  for (final name in file.parts) {
    for (final path in [name, '$name.part', '$name.part.json', '$name.part.json.tmp', '$name.usage.json']) {
      final f = File(_join(folder, path));
      if (f.existsSync()) f.deleteSync();
    }
  }
}

/// Whether the file at [path] matches [f]'s checksum. Read in its own isolate: a large file takes minutes.
Future<bool> checksumMatches(String path, RemoteFile f) => Isolate.run(() async {
  final stream = File(path).openRead();
  if (f.sha256 != null) return (await sha256.bind(stream).first).toString() == f.sha256;
  // git's SHA-1 of a file is that of "blob <size>\0" followed by the file
  late Digest digest;
  final sink = sha1.startChunkedConversion(ChunkedConversionSink<Digest>.withCallback((d) => digest = d.single));
  sink.add(utf8.encode('blob ${f.size}\x00'));
  await stream.forEach(sink.add);
  sink.close();
  return digest.toString() == f.gitSha1;
});

/// One model's download into [folder]: its files one after another, each fetched in parts over [connections]
/// connections at once, written next to where it goes as `<name>.part` with its [PartRecord] (saved twice a second
/// and when it stops, so a part cut off continues from its last byte written); a finished file is checked against
/// Hugging Face's checksum and only then gets its name. [stop] pauses it (what is written stays).
class ModelDownload {
  ModelDownload(
    this.file,
    this.folder, {
    Uri? server,
    this.connections = 6,
    this.partBytes = 32 << 20,
    this.free = freeBytes,
    this.onProgress,
    this.onVerified,
    this.retryDelay = const Duration(seconds: 1),
  }) : server = server ?? huggingFace;

  final ModelFile file;
  final String folder;
  final Uri server;
  final int connections;

  /// The size of each part fetched with one request (larger parts: fewer requests to Hugging Face, which limits
  /// them; smaller: less lost when the app ends without saving its record).
  final int partBytes;

  /// Free bytes on a drive (tests give their own).
  final Future<int?> Function(String path) free;
  final void Function(DownloadProgress progress)? onProgress;

  /// Called for each file that passed its check and got its name, with its path (updates keep its checksum from it).
  final void Function(String path, RemoteFile file)? onVerified;

  /// The wait before the first retry of a part; each retry waits twice as long.
  final Duration retryDelay;

  HttpClient? _client;
  var _stopped = false;
  var _base = 0, _total = 0, _flowing = 0, _saved = 0;
  PartRecord? _record;
  // the records of the files not finished yet, so their written parts count from the first progress on
  final _kept = <String, PartRecord>{};
  File? _recordFile;
  final _speed = <(int, int)>[];

  /// Stops the download; [run] then returns false. What is written stays, to be continued.
  void stop() {
    _stopped = true;
    _client?.close(force: true);
  }

  int get _done => _base + _kept.values.fold<int>(0, (sum, r) => sum + r.doneBytes) + _flowing;

  /// Downloads every file not yet there. True when all are there and checked; false when [stop] was called. Throws
  /// [DownloadFailure].
  Future<bool> run() async {
    final client = _client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    Timer? ticks;
    try {
      Directory(folder).createSync(recursive: true);
      final List<RemoteFile> files;
      try {
        files = await remoteFiles(client, server, file.repo!, file.parts);
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
          needed += f.size - record.doneBytes;
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
    if (record == null || file == null || record.doneBytes == _saved) return;
    try {
      record.write(file);
      _saved = record.doneBytes;
    } on FileSystemException {
      // The drive is gone or full: the parts' own writes fail and say so.
    }
  }

  void _tell({bool checking = false}) {
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
        checking: checking,
      ),
    );
  }

  /// One file: its missing parts, then the check. False when stopped.
  Future<bool> _fetch(HttpClient client, RemoteFile f) async {
    final part = File(_join(folder, '${f.name}.part'));
    final recordFile = File('${part.path}.json');
    var record = PartRecord.read(recordFile);
    if (record == null || !record.isFor(f) || !part.existsSync()) {
      if (part.existsSync()) part.deleteSync();
      part.createSync();
      record = PartRecord(size: f.size, partBytes: partBytes, sha256: f.sha256, gitSha1: f.gitSha1)..write(recordFile);
    }
    _record = _kept[f.name] = record;
    _recordFile = recordFile;
    _saved = record.doneBytes;
    final url = server.resolve('/${file.repo}/resolve/main/${f.name}');
    final todo = record.missing;
    try {
      // (Waits for every connection, also after one failed, so each has written what it got before the save.)
      await Future.wait([
        for (var w = 0; w < min(connections, todo.length); w++)
          _worker(client, url, part, record, todo).catchError((Object e) {
            stop();
            throw e;
          }),
      ]);
    } finally {
      _save();
      _recordFile = null;
    }
    if (_stopped) return false;

    _tell(checking: true);
    if (!await checksumMatches(part.path, f)) {
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

  /// Takes parts from [todo] until none is left, writing each where it goes in the file.
  Future<void> _worker(HttpClient client, Uri url, File part, PartRecord record, List<int> todo) async {
    // (Append mode opens without cutting the file; each write goes where the position is set.)
    final out = await part.open(mode: FileMode.append);
    try {
      while (todo.isNotEmpty && !_stopped) {
        if (!await _fetchPart(client, url, out, record, todo.removeAt(0))) return;
      }
    } finally {
      await out.close();
    }
  }

  /// Fetches part [i] from its first byte not yet written, retrying a few times when the connection breaks (each
  /// retry asks only for the rest). What came is written and recorded also when it stops. False when stopped.
  Future<bool> _fetchPart(HttpClient client, Uri url, RandomAccessFile out, PartRecord record, int i) async {
    final (first, last) = record.range(i);
    var at = first + (record.started[i] ?? 0), pending = 0;
    final buffer = BytesBuilder(copy: false);
    // The bytes are counted as written only once they are in the file, so the progress never goes back.
    Future<void> flush() async {
      final bytes = buffer.takeBytes();
      // (never past the part's end, whatever the server sent)
      final keep = min(bytes.length, last + 1 - at);
      await out.setPosition(at);
      await out.writeFrom(bytes, 0, keep);
      at += keep;
      pending -= bytes.length;
      _flowing -= bytes.length;
      if (at > last) {
        record.started.remove(i);
        record.done.add(i);
      } else if (at > first) {
        record.started[i] = at - first;
      }
    }

    void drop() {
      buffer.clear();
      _flowing -= pending;
      pending = 0;
    }

    for (var attempt = 1; ; attempt++) {
      try {
        final request = await client.getUrl(url);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$at-$last');
        final response = await request.close();
        final whole = response.statusCode == 200 && at == 0 && last == record.size - 1;
        if (response.statusCode != 206 && !whole) {
          await response.drain<void>();
          throw _Status(response.statusCode);
        }
        await for (final data in response) {
          buffer.add(data);
          pending += data.length;
          _flowing += data.length;
          if (buffer.length >= 4 << 20) await flush();
        }
        await flush();
        if (at == last + 1) return true;
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
        if (at > last) return true;
        if (_stopped) return false;
        if (e is _Status && !_retryable(e.status)) throw DownloadFailure(_refused(e.status));
        if (attempt >= 6) {
          throw const DownloadFailure(
            'The download keeps breaking off. Check the internet connection, then press Resume.',
          );
        }
        await Future<void>.delayed(retryDelay * (1 << (attempt - 1)));
        if (_stopped) return false;
      }
    }
  }
}

class _Status implements Exception {
  const _Status(this.status);
  final int status;
}
