import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/system/signature.dart';

import 'signing.dart';

void main() {
  test("the release jobs' signature verifies against the built-in key; anything else does not", () {
    // made with the real private key: openssl pkeyutl -sign -rawin over these exact bytes
    final sums = utf8.encode('b3f0  RunMyAI-linux-x64.AppImage\n');
    const sig = 'Hh6iFeuQe6ghiAWXSF0jJHWmcHVd34EWi+2m9gjdOTNuDx9lMYSsc0QJAg6bpoyvY2P+2QM8ObTW0N6ys+iMDg==';
    expect(signedByUs(sums, sig, key: updateKey), isTrue);
    expect(signedByUs(utf8.encode('c3f0  RunMyAI-linux-x64.AppImage\n'), sig, key: updateKey), isFalse, reason: 'other bytes');
    expect(signedByUs(sums, testSign(sums), key: updateKey), isFalse, reason: 'another key');
    expect(signedByUs(sums, 'not base64!', key: updateKey), isFalse);
    expect(signedByUs(sums, base64.encode(List.filled(63, 1)), key: updateKey), isFalse, reason: 'wrong length');
    useTestKey();
    expect(signedByUs(sums, testSign(sums)), isTrue, reason: "the tests' own key, as the fixtures use it");
  });
}
