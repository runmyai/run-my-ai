// The order of the chat list (sortChats in lib/state/chats.dart).
// Run: flutter test test/chat_order_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/state/chats.dart';

ChatInfo chat(String id, DateTime updated, {double? sort}) =>
    ChatInfo(id: id, title: id, createdAt: updated, updatedAt: updated, sort: sort);

void main() {
  test('newest day first; within a day, where the user dragged it, else when it was last used', () {
    final chats = [
      chat('old', DateTime(2026, 10, 28, 23)),
      chat('morning', DateTime(2026, 10, 30, 8)),
      chat('noon', DateTime(2026, 10, 30, 12)),
      // Dragged above "noon" though used earlier; the place only counts within its day.
      chat('dragged', DateTime(2026, 10, 30, 7), sort: DateTime(2026, 10, 30, 12).millisecondsSinceEpoch + 1.0),
      chat('yesterday', DateTime(2026, 10, 29, 9), sort: 1e15),
    ];
    expect([for (final c in sortChats(chats)) c.id], ['dragged', 'noon', 'morning', 'yesterday', 'old']);
  });

  test('a new message (no place, a later time) puts the chat at the top of its day', () {
    final dragged = DateTime(2026, 10, 30, 12).millisecondsSinceEpoch.toDouble();
    final chats = [
      chat('a', DateTime(2026, 10, 30, 12), sort: dragged),
      chat('b', DateTime(2026, 10, 30, 11), sort: dragged - 1),
      chat('c', DateTime(2026, 10, 30, 13)),
    ];
    expect([for (final c in sortChats(chats)) c.id], ['c', 'a', 'b']);
  });
}
