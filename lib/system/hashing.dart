import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:ffi/ffi.dart';

/// The bytes a [Sha256Hash] takes in one step.
const _blockBytes = 8 << 20;

/// A running SHA-256. It uses the processor's SHA instructions through the system's crypto library (libcrypto on
/// Linux, BCrypt on Windows: several GB/s) and package:crypto where that library cannot be loaded (the same digest,
/// about ten times slower). Bytes are read into [buffer] and taken in with [add].
abstract class Sha256Hash {
  /// The fast one when it can be loaded and [native] is true, else package:crypto's.
  factory Sha256Hash({bool native = true}) => (native ? _nativeHash() : null) ?? _DartHash();

  /// Where the next bytes go before [add].
  Uint8List get buffer;

  /// Whether this is the fast one.
  bool get native;

  /// Takes in the first [n] bytes of [buffer].
  void add(int n);

  /// The digest as hex. The hash is then done with ([close] is not needed).
  String finish();

  /// Frees what it holds without a digest.
  void close();
}

Sha256Hash? _nativeHash() {
  try {
    if (Platform.isLinux) return _OpenSslHash();
    if (Platform.isWindows) return _BCryptHash();
  } on Object {
    // The library or one of its functions is missing: package:crypto instead.
  }
  return null;
}

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class _DartHash implements Sha256Hash {
  _DartHash() {
    _sink = dart_crypto.sha256.startChunkedConversion(
      ChunkedConversionSink<dart_crypto.Digest>.withCallback((d) => _digest = d.single),
    );
  }

  late final ByteConversionSink _sink;
  dart_crypto.Digest? _digest;

  @override
  final buffer = Uint8List(_blockBytes);

  @override
  bool get native => false;

  @override
  void add(int n) => _sink.add(Uint8List.sublistView(buffer, 0, n));

  @override
  String finish() {
    _sink.close();
    return _digest.toString();
  }

  @override
  void close() {}
}

typedef _NewCtx = Pointer<Void> Function();
typedef _FreeCtxC = Void Function(Pointer<Void>);
typedef _FreeCtx = void Function(Pointer<Void>);
typedef _InitC = Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _Init = int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _UpdateC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _Update = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _FinalC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>);
typedef _Final = int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>);

/// OpenSSL 3's EVP digest functions (they pick the SHA instructions when the processor has them).
class _OpenSslHash implements Sha256Hash {
  factory _OpenSslHash() {
    final lib = _libcrypto ??= _openLibcrypto();
    final ctx = lib.lookupFunction<_NewCtx, _NewCtx>('EVP_MD_CTX_new')();
    if (ctx == nullptr) throw StateError('EVP_MD_CTX_new');
    final hash = _OpenSslHash._(
      ctx,
      lib.lookupFunction<_UpdateC, _Update>('EVP_DigestUpdate'),
      lib.lookupFunction<_FinalC, _Final>('EVP_DigestFinal_ex'),
      lib.lookupFunction<_FreeCtxC, _FreeCtx>('EVP_MD_CTX_free'),
    );
    final md = lib.lookupFunction<_NewCtx, _NewCtx>('EVP_sha256')();
    if (lib.lookupFunction<_InitC, _Init>('EVP_DigestInit_ex')(ctx, md, nullptr) != 1) {
      hash.close();
      throw StateError('EVP_DigestInit_ex');
    }
    return hash;
  }

  _OpenSslHash._(this._ctx, this._update, this._final, this._free);

  static DynamicLibrary? _libcrypto;

  static DynamicLibrary _openLibcrypto() {
    try {
      return DynamicLibrary.open('libcrypto.so.3');
    } on ArgumentError {
      return DynamicLibrary.open('libcrypto.so');
    }
  }

  final Pointer<Void> _ctx;
  final _Update _update;
  final _Final _final;
  final _FreeCtx _free;
  final _memory = malloc<Uint8>(_blockBytes);
  var _closed = false;

  @override
  late final buffer = _memory.asTypedList(_blockBytes);

  @override
  bool get native => true;

  @override
  void add(int n) {
    if (_update(_ctx, _memory, n) != 1) throw StateError('EVP_DigestUpdate');
  }

  @override
  String finish() {
    final out = malloc<Uint8>(64), length = malloc<Uint32>();
    try {
      if (_final(_ctx, out, length) != 1) throw StateError('EVP_DigestFinal_ex');
      return _hex(out.asTypedList(length.value));
    } finally {
      malloc
        ..free(out)
        ..free(length);
      close();
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _free(_ctx);
    malloc.free(_memory);
  }
}

typedef _OpenAlgC = Int32 Function(Pointer<Pointer<Void>>, Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _OpenAlg = int Function(Pointer<Pointer<Void>>, Pointer<Utf16>, Pointer<Utf16>, int);
typedef _CreateHashC = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Uint32,
);
typedef _CreateHash = int Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
);
typedef _HashDataC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Uint32);
typedef _HashData = int Function(Pointer<Void>, Pointer<Uint8>, int, int);
typedef _HandleC = Int32 Function(Pointer<Void>);
typedef _Handle = int Function(Pointer<Void>);
typedef _CloseAlgC = Int32 Function(Pointer<Void>, Uint32);
typedef _CloseAlg = int Function(Pointer<Void>, int);

/// Windows' BCrypt (an NTSTATUS of 0 is success; the hash object's memory is kept by BCrypt itself).
class _BCryptHash implements Sha256Hash {
  factory _BCryptHash() {
    final lib = DynamicLibrary.open('bcrypt.dll');
    final openAlg = lib.lookupFunction<_OpenAlgC, _OpenAlg>('BCryptOpenAlgorithmProvider');
    final createHash = lib.lookupFunction<_CreateHashC, _CreateHash>('BCryptCreateHash');
    final closeAlg = lib.lookupFunction<_CloseAlgC, _CloseAlg>('BCryptCloseAlgorithmProvider');
    final handle = calloc<Pointer<Void>>(), name = 'SHA256'.toNativeUtf16();
    try {
      if (openAlg(handle, name, nullptr, 0) != 0) throw StateError('BCryptOpenAlgorithmProvider');
      final alg = handle.value;
      if (createHash(alg, handle, nullptr, 0, nullptr, 0, 0) != 0) {
        closeAlg(alg, 0);
        throw StateError('BCryptCreateHash');
      }
      return _BCryptHash._(
        alg,
        handle.value,
        lib.lookupFunction<_HashDataC, _HashData>('BCryptHashData'),
        lib.lookupFunction<_HashDataC, _HashData>('BCryptFinishHash'),
        lib.lookupFunction<_HandleC, _Handle>('BCryptDestroyHash'),
        closeAlg,
      );
    } finally {
      calloc.free(handle);
      malloc.free(name);
    }
  }

  _BCryptHash._(this._alg, this._hash, this._hashData, this._finishHash, this._destroyHash, this._closeAlg);

  final Pointer<Void> _alg, _hash;
  final _HashData _hashData, _finishHash;
  final _Handle _destroyHash;
  final _CloseAlg _closeAlg;
  final _memory = malloc<Uint8>(_blockBytes);
  var _closed = false;

  @override
  late final buffer = _memory.asTypedList(_blockBytes);

  @override
  bool get native => true;

  @override
  void add(int n) {
    if (_hashData(_hash, _memory, n, 0) != 0) throw StateError('BCryptHashData');
  }

  @override
  String finish() {
    final out = malloc<Uint8>(32);
    try {
      if (_finishHash(_hash, out, 32, 0) != 0) throw StateError('BCryptFinishHash');
      return _hex(out.asTypedList(32));
    } finally {
      malloc.free(out);
      close();
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _destroyHash(_hash);
    _closeAlg(_alg, 0);
    malloc.free(_memory);
  }
}

/// Reads [file] from where it is up to [end] into [hash].
void _hashRange(RandomAccessFile file, Sha256Hash hash, int at, int end) {
  while (at < end) {
    final n = file.readIntoSync(hash.buffer, 0, min(hash.buffer.length, end - at));
    if (n <= 0) throw FileSystemException('The file is shorter than expected', file.path);
    hash.add(n);
    at += n;
  }
}

/// The SHA-256 of the file at [path], as hex, worked out in its own isolate.
Future<String> sha256OfFile(String path, {bool native = true}) => Isolate.run(() {
  final hash = Sha256Hash(native: native);
  final file = File(path).openSync();
  try {
    _hashRange(file, hash, 0, file.lengthSync());
    return hash.finish();
  } catch (_) {
    hash.close();
    rethrow;
  } finally {
    file.closeSync();
  }
});

/// The SHA-256 of a file that is written in any order, worked out as the stretch finished from its start grows: each
/// [feed] hands the hash the bytes up to that point, read back from the file in its own isolate (just written, so they
/// come from memory, not the drive). [digest] then needs only what is left. The hash state lives in memory only.
class FileHasher {
  FileHasher(this.path, {bool native = true}) {
    _replies = RawReceivePort(_reply);
    unawaited(
      Isolate.spawn(
        _hashLoop,
        (_replies.sendPort, path, native),
        onExit: _replies.sendPort,
        debugName: 'sha256',
      ).then<void>((_) {}, onError: (Object _) => _reply(null)),
    );
  }

  final String path;
  late final RawReceivePort _replies;
  SendPort? _inbox;
  final _waiting = <Object>[];
  Completer<String>? _digest;
  // the isolate's last word: a digest, an error, or null when it ended without either
  Object? _result;
  var _ended = false, _asked = 0;

  /// How far [feed] has asked for so far.
  int get asked => _asked;

  void _send(Object message) => _inbox == null ? _waiting.add(message) : _inbox!.send(message);

  void _reply(Object? message) {
    if (message is SendPort) {
      _inbox = message;
      _waiting.forEach(message.send);
      _waiting.clear();
      return;
    }
    if (_ended) return;
    _ended = true;
    _result = message;
    _replies.close();
    _answer();
  }

  void _answer() {
    final digest = _digest;
    if (digest == null || digest.isCompleted || !_ended) return;
    if (_result case final String hex) {
      digest.complete(hex);
    } else {
      digest.completeError(
        FileSystemException(_result is List ? '${(_result as List).last}' : 'The checksum stopped', path),
      );
    }
  }

  /// Hashes the file up to byte [end] (the bytes before it must be written). Returns at once.
  void feed(int end) {
    if (end <= _asked || _digest != null) return;
    _asked = end;
    _send(end);
  }

  /// The digest of the file's first [size] bytes, as hex. Throws a [FileSystemException] when the file could not be
  /// read.
  Future<String> digest(int size) {
    if (_digest case final d?) return d.future;
    final d = _digest = Completer<String>();
    _send(('finish', size));
    _answer();
    return d.future;
  }

  /// Ends it without a digest.
  void close() {
    if (_digest != null) return;
    _digest = Completer<String>()..future.ignore();
    _send('close');
  }
}

void _hashLoop((SendPort, String, bool) start) {
  final (reply, path, native) = start;
  final inbox = RawReceivePort();
  final hash = Sha256Hash(native: native);
  var at = 0;
  Object? error;

  // The file is open only while a block is read, so it can be renamed or deleted (Windows refuses that for an open
  // file) while the hash waits for more.
  void feed(int end) {
    if (error != null || end <= at) return;
    try {
      while (at < end) {
        final file = File(path).openSync();
        final int n;
        try {
          file.setPositionSync(at);
          n = file.readIntoSync(hash.buffer, 0, min(hash.buffer.length, end - at));
        } finally {
          file.closeSync();
        }
        if (n <= 0) throw FileSystemException('The file is shorter than expected', path);
        hash.add(n);
        at += n;
      }
    } on Object catch (e) {
      error = e;
    }
  }

  inbox.handler = (Object? message) {
    switch (message) {
      case final int upTo:
        feed(upTo);
      case ('finish', final int size):
        feed(size);
        inbox.close();
        if (error == null && at == size) {
          reply.send(hash.finish());
        } else {
          hash.close();
          reply.send(['error', error?.toString() ?? 'The file was read past its size']);
        }
      default:
        inbox.close();
        hash.close();
    }
  };
  reply.send(inbox.sendPort);
}
