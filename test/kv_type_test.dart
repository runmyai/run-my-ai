import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/engine/commands.dart';

void main() {
  test('the cache type replaces both -ctk and -ctv, and is added when the command has none', () {
    expect(withKvType('-c 65536 -ctk q8_0 -ctv q8_0 -fa on', 'q4_0'), '-c 65536 -ctk q4_0 -ctv q4_0 -fa on');
    expect(withKvType('-c 65536 -ctk=q8_0 -ctv=q8_0', 'f16'), '-c 65536 -ctk=f16 -ctv=f16');
    expect(withKvType('-c 4096', 'q8_0'), '-c 4096 -ctk q8_0 -ctv q8_0');
  });

  test('the offered types are the engine\'s names', () => expect(kvTypes, ['q4_0', 'q8_0', 'f16']));
}
