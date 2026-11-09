import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// The heading a chat last used at [time] goes under: "Today", "Yesterday", then the date ("28 Oct"), with the
/// year only before this year ("12 Dec 2025"). A time after today (the clock was moved back) counts as today.
String dayLabel(DateTime time, DateTime today) {
  final day = DateTime(time.year, time.month, time.day);
  if (!day.isBefore(today)) return 'Today';
  if (day == DateTime(today.year, today.month, today.day - 1)) return 'Yesterday';
  final date = '${day.day} ${_months[day.month - 1]}';
  return day.year == today.year ? date : '$date ${day.year}';
}

/// Today's date (midnight, local time). Checked once a minute, so the headings move on after midnight, and soon
/// after the computer wakes up on another day.
class TodayNotifier extends Notifier<DateTime> {
  @override
  DateTime build() {
    final timer = Timer.periodic(const Duration(minutes: 1), (_) {
      final now = _date();
      if (now != state) state = now;
    });
    ref.onDispose(timer.cancel);
    return _date();
  }

  static DateTime _date() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }
}

final todayProvider = NotifierProvider<TodayNotifier, DateTime>(TodayNotifier.new);
