// The Auto commands (lib/engine/auto_commands.dart) are written by tool/sync_auto_commands.sh from the engine's model
// presets; these tests fail when the file and the presets disagree. They need bash and the presets folder next to the app.
// Run: flutter test test/auto_commands_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _script = 'tool/sync_auto_commands.sh';
const _commands = 'lib/engine/auto_commands.dart';

String? _cannotRun() {
  if (Platform.isWindows) return 'needs bash';
  if (!File(_script).existsSync()) return 'the test is not run from the app folder';
  if (!File('../presets/ling.sh').existsSync() ||
      !File('../presets/flint.sh').existsSync() ||
      !File('../presets/qwen38.sh').existsSync() ||
      !File('../presets/inkling2.sh').existsSync()) {
    return 'the presets are not here';
  }
  return null;
}

void main() {
  final skip = _cannotRun();

  test('auto_commands.dart is what the presets give', () {
    final result = Process.runSync('bash', [_script, '--check']);
    expect(result.exitCode, 0, reason: '${result.stderr}\nRun tool/sync_auto_commands.sh to write the file again.');
  }, skip: skip);

  test('a flag changed by hand is found', () {
    final folder = Directory.systemTemp.createTempSync('auto_commands');
    addTearDown(() => folder.deleteSync(recursive: true));
    final edited = File('${folder.path}/auto_commands.dart')
      ..writeAsStringSync(File(_commands).readAsStringSync().replaceFirst('-np 1', '-np 2'));
    final result = Process.runSync('bash', [_script, '--check', edited.path]);
    expect(result.exitCode, 1);
    expect('${result.stderr}', contains('-np 2'));
  }, skip: skip);
}
