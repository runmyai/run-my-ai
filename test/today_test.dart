// The headings in the chat list (lib/state/today.dart).
// Run: flutter test test/today_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/state/today.dart';

void main() {
  test('Today, Yesterday, then the date; the year only before this year', () {
    final today = DateTime(2026, 10, 30);
    expect(dayLabel(DateTime(2026, 10, 30, 0, 0), today), 'Today');
    expect(dayLabel(DateTime(2026, 10, 30, 23, 59), today), 'Today');
    expect(dayLabel(DateTime(2026, 11, 2), today), 'Today', reason: 'a time after today (clock moved back)');
    expect(dayLabel(DateTime(2026, 10, 29, 23, 59), today), 'Yesterday');
    expect(dayLabel(DateTime(2026, 10, 29, 0, 0), today), 'Yesterday');
    expect(dayLabel(DateTime(2026, 10, 28, 23, 59), today), '28 Oct');
    expect(dayLabel(DateTime(2026, 9, 3), today), '3 Sep');
    expect(dayLabel(DateTime(2026, 1, 1), today), '1 Jan');
    expect(dayLabel(DateTime(2025, 12, 31), today), '31 Dec 2025');
  });

  test('yesterday across a month and a year', () {
    expect(dayLabel(DateTime(2026, 9, 30, 8), DateTime(2026, 10, 1)), 'Yesterday');
    expect(dayLabel(DateTime(2025, 12, 31, 8), DateTime(2026, 1, 1)), 'Yesterday');
    expect(dayLabel(DateTime(2025, 12, 30, 8), DateTime(2026, 1, 1)), '30 Dec 2025');
  });
}
