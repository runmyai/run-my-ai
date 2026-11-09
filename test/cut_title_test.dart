// Chat titles too long for the sidebar (lib/ui/chat_list.dart, CutTitle): cut with "…", and a card with all of it.
// Run: flutter test test/cut_title_test.dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/chat_list.dart';

void main() {
  Future<void> show(WidgetTester tester, String title) => tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 200,
          child: CutTitle(TextSpan(text: title, style: const TextStyle(fontSize: 14)), full: title),
        ),
      ),
    ),
  );

  testWidgets('a title that fits: no card', (tester) async {
    await show(tester, 'Short title');
    expect(find.byType(Tooltip), findsNothing);
  });

  testWidgets('a title cut short: held under the pointer, a card shows all of it', (tester) async {
    const long = 'A very long chat title that cannot fit in the sidebar at all';
    await show(tester, long);
    expect(find.byType(Tooltip), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(CutTitle)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(long), findsOneWidget, reason: 'only the title itself: no card at once');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text(long), findsNWidgets(2), reason: 'the title and the card, after a moment');
    final card = tester.getRect(find.text(long).last);
    final row = tester.getRect(find.byType(CutTitle));
    expect(card.left, greaterThan(row.right + 46), reason: 'to the right, past the sidebar');
    expect(card.center.dy, closeTo(row.center.dy, 1), reason: 'level with the chat');
    await mouse.removePointer();
  });
}
