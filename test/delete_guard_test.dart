// When deleting a chat asks first (lib/state/delete_guard.dart).
// Run: flutter test test/delete_guard_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/state/delete_guard.dart';

void main() {
  late DateTime now;
  late DeleteGuard guard;
  setUp(() {
    now = DateTime(2026, 10, 30, 12);
    guard = DeleteGuard(clock: () => now);
  });
  void after(int seconds) => now = now.add(Duration(seconds: seconds));

  test('the first two deletes ask; then no box while each comes within 2 minutes of the one before', () {
    expect(guard.asks, isTrue);
    guard.deleted();
    after(60);
    expect(guard.asks, isTrue, reason: 'the second delete still asks');
    guard.deleted();
    after(100);
    expect(guard.asks, isFalse);
    guard.deleted();
    after(110);
    expect(guard.asks, isFalse, reason: 'each delete restarts the 2 minutes');
    guard.deleted();
    after(121);
    expect(guard.asks, isTrue, reason: 'more than 2 minutes since the last delete');
  });

  test('after quick mode ends, the next delete counts as a first one again', () {
    guard
      ..deleted()
      ..deleted();
    after(121);
    expect(guard.asks, isTrue);
    guard.deleted();
    after(10);
    expect(guard.asks, isTrue, reason: 'only one delete since quick mode ended');
    guard.deleted();
    expect(guard.asks, isFalse);
  });

  test('a second delete more than 2 minutes after the first counts as a first one', () {
    guard.deleted();
    after(121);
    expect(guard.asks, isTrue);
    guard.deleted();
    after(30);
    expect(guard.asks, isTrue);
  });
}
