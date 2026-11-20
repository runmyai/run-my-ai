import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:runmyai/system/signature.dart';

/// The tests' own update key: its public half replaces the app's for the test, its private half signs the fixtures
/// (the real private key is never in the repo).
final _key = ed.newKeyFromSeed(Uint8List(32)..fillRange(0, 32, 7));

void useTestKey() => checkKey = base64.encode(ed.public(_key).bytes);

String testSign(List<int> data) => base64.encode(ed.sign(_key, Uint8List.fromList(data)));
