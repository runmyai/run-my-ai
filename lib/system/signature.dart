import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

import 'downloads.dart';

/// The public key of the update key: the release jobs sign each release's SHA256SUMS, and each model's update list, with
/// its private key. Nothing is installed whose checksum is not covered by a signature this key verifies.
const updateKey = 'lShWZZ8GZEQ/xfNza+uGHveSCMOtk+utSJBiE5TyKTw=';

/// A test build's own public key (`flutter build --dart-define=RUNMYAI_TEST_UPDATE_KEY=<base64>`), to test updates from a local
/// stand-in signed with a test key; the release builds never set it.
const _testBuildKey = String.fromEnvironment('RUNMYAI_TEST_UPDATE_KEY');

/// The key signatures are checked against: [updateKey], or a test build's own (tests sign their own releases too).
@visibleForTesting
String checkKey = _testBuildKey.isEmpty ? updateKey : _testBuildKey;

/// Whether [signature] (base64, as in SHA256SUMS.sig) is [key]'s (default [checkKey]) Ed25519 signature of [data].
bool signedByUs(List<int> data, String signature, {String? key}) {
  try {
    final sig = base64.decode(signature.trim());
    if (sig.length != 64) return false;
    return ed.verify(ed.PublicKey(base64.decode(key ?? checkKey)), Uint8List.fromList(data), Uint8List.fromList(sig));
  } on FormatException {
    return false;
  } on ArgumentError {
    return false;
  }
}

/// The body of [url]; throws [DownloadFailure] when it is not there.
Future<List<int>> fetchBytes(HttpClient client, Uri url, String what) async {
  final response = await (await client.getUrl(url)).close();
  final bytes = await response.fold<List<int>>(<int>[], (all, part) => all..addAll(part));
  if (response.statusCode != 200) throw DownloadFailure('$what could not be read (error ${response.statusCode}).');
  return bytes;
}

/// The checksums of a release ([assets] by name), from its SHA256SUMS once SHA256SUMS.sig verifies it. Throws
/// [DownloadFailure] when either is missing or the signature does not verify: nothing of that release is installed then.
Future<Map<String, String>> signedSums(HttpClient client, Map<String, ({Uri url, int size})> assets) async {
  final sums = assets['SHA256SUMS'], sig = assets['SHA256SUMS.sig'];
  if (sums == null || sig == null) throw const DownloadFailure('This release is not signed, so it was not installed.');
  final text = await fetchBytes(client, sums.url, 'The release checksums');
  final signature = utf8.decode(await fetchBytes(client, sig.url, 'The release signature'), allowMalformed: true);
  if (!signedByUs(text, signature)) {
    throw const DownloadFailure('The release signature does not match, so nothing was installed.', broken: true);
  }
  return parseSha256Sums(utf8.decode(text, allowMalformed: true));
}

/// The SHA-256 of [bytes], as hex.
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// The SHA-256 of the file at [path], as hex (in its own isolate).
Future<String> sha256OfFile(String path) =>
    Isolate.run(() async => (await sha256.bind(File(path).openRead()).first).toString());

/// The checksums in a SHA256SUMS file (`sha256  name` per line; a `*` before the name marks binary mode), by name.
Map<String, String> parseSha256Sums(String text) => {
  for (final line in const LineSplitter().convert(text))
    if (RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$').firstMatch(line) case final m?) m[2]!: m[1]!.toLowerCase(),
};
