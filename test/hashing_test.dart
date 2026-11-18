// SHA-256 through the system's crypto library against package:crypto, whole files, and the running hash of a file
// written in any order.
// Run: flutter test test/hashing_test.dart
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/system/hashing.dart';

Uint8List _random(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList([for (var i = 0; i < n; i++) r.nextInt(256)]);
}

String _hash(Sha256Hash h, Uint8List bytes) {
  for (var at = 0; at < bytes.length;) {
    final n = min(h.buffer.length, bytes.length - at);
    h.buffer.setRange(0, n, bytes, at);
    h.add(n);
    at += n;
  }
  return h.finish();
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('runmyai-hash-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('the system library is used on Linux and Windows, and both ways give package:crypto\'s digest', () {
    if (Platform.isLinux || Platform.isWindows) expect(Sha256Hash().native, isTrue);
    expect(Sha256Hash(native: false).native, isFalse);
    // empty, short, one block exactly, and more than one block
    for (final n in [0, 3, 8 << 20, (8 << 20) + 12345]) {
      final bytes = _random(n, n);
      final want = sha256.convert(bytes).toString();
      expect(_hash(Sha256Hash(), bytes), want, reason: 'native, $n bytes');
      expect(_hash(Sha256Hash(native: false), bytes), want, reason: 'package:crypto, $n bytes');
    }
  });

  test('a whole file', () async {
    final bytes = _random(3 << 20, 7);
    final file = File('${dir.path}/f')..writeAsBytesSync(bytes);
    final want = sha256.convert(bytes).toString();
    expect(await sha256OfFile(file.path), want);
    expect(await sha256OfFile(file.path, native: false), want);
  });

  test('the running hash of a file written out of order equals the hash of the whole file', () async {
    for (final native in [true, false]) {
      for (final seed in [1, 2, 3]) {
        const size = 25000, part = 768;
        final bytes = _random(size, seed);
        final file = File('${dir.path}/p$seed$native')..writeAsBytesSync(Uint8List(size));
        final out = file.openSync(mode: FileMode.append);
        final hasher = FileHasher(file.path, native: native);
        final parts = [for (var i = 0; i * part < size; i++) i]..shuffle(Random(seed));
        final done = <int>{};
        for (final i in parts) {
          final end = min(size, (i + 1) * part);
          out
            ..setPositionSync(i * part)
            ..writeFromSync(bytes, i * part, end);
          done.add(i);
          var prefix = 0;
          while (done.contains(prefix)) {
            prefix++;
          }
          hasher.feed(min(size, prefix * part));
        }
        out.closeSync();
        expect(await hasher.digest(size), sha256.convert(bytes).toString(), reason: 'seed $seed, native $native');
      }
    }
  });

  test('a file that cannot be read fails the digest; a closed hasher stops', () async {
    final file = File('${dir.path}/short')..writeAsBytesSync(_random(100, 1));
    await expectLater(FileHasher(file.path).digest(1000), throwsA(isA<FileSystemException>()));
    await expectLater(FileHasher('${dir.path}/none').digest(10), throwsA(isA<FileSystemException>()));
    FileHasher(file.path)
      ..feed(50)
      ..close();
  });
}
