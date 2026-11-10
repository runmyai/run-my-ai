// A chat's saved state files: found by the name the engine gives them, and removed.
// Run: flutter test test/chat_states_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/engine/chat_states.dart';
import 'package:runmyai/engine/commands.dart';

void main() {
  const id = '1762000000000000';
  const hash = 'e9a8715fe47d8807';

  test('the name part is the engine\'s, for a chat id', () => expect(chatStateHash(id), hash));

  test('only that chat\'s state and snapshots go', () {
    final dir = Directory.systemTemp.createTempSync('runmyai-states-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final keep = ['chat-0000000000000000.state', 'snap-0000000000000000-00000000000000aa.state', 'prefix-$hash.state'];
    final gone = ['chat-$hash.state', 'snap-$hash-00000000000000aa.state', 'snap-$hash-00000000000000bb.state'];
    for (final name in [...keep, ...gone]) {
      File('${dir.path}/$name').writeAsStringSync('x');
    }
    deleteChatStates(dir.path, id);
    expect(dir.listSync().map((e) => e.uri.pathSegments.last).toSet(), keep.toSet());
  });

  test('a folder that is not there is fine', () => deleteChatStates('/nonexistent/folder', id));

  test('a command cannot set where states are kept', () {
    expect(commandProblem('-c 4096 --cache-disk x', maxContext: 8192), contains('the app sets it'));
    expect(commandProblem('-c 4096 --cache-disk-gb 1', maxContext: 8192), contains('the app sets it'));
  });
}
