// Long sent messages folded to their first lines (lib/ui/folded_text.dart).
// Run: flutter test test/folded_text_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/folded_text.dart';

void main() {
  const style = TextStyle(fontSize: 15, height: 1.6);
  const line = 24.0;

  Future<void> show(WidgetTester tester, String text, {required bool open}) => tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              child: FoldedText(
                key: const Key('folded'),
                text: SelectableText(text, style: style),
                plain: text,
                style: style,
                open: open,
                onToggle: () {},
                arrowKey: const Key('arrow'),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  double textShown(WidgetTester tester) => tester
      .getSize(find.descendant(of: find.byKey(const Key('folded')), matching: find.byType(AnimatedSize)).first)
      .height;

  final long = List.filled(40, 'A long message, pasted in, going on for many lines.').join(' ');

  testWidgets('a message of 8 lines or fewer shows in full, with no arrow', (tester) async {
    await show(tester, List.filled(5, 'Short enough.').join('\n'), open: false);
    expect(find.byKey(const Key('arrow')), findsNothing);
  });

  testWidgets('a longer one shows its first 8 lines and an arrow; opened, all of it, growing smoothly', (tester) async {
    await show(tester, long, open: false);
    expect(find.byKey(const Key('arrow')), findsOneWidget);
    expect(textShown(tester), closeTo(8 * line, 0.5));
    final full = tester.getSize(find.byType(SelectableText)).height;
    expect(full, greaterThan(12 * line));

    await show(tester, long, open: true);
    await tester.pump(const Duration(milliseconds: 60));
    final midway = textShown(tester);
    expect(midway, inExclusiveRange(8 * line, full), reason: 'it grows, not jumps');
    await tester.pumpAndSettle();
    expect(textShown(tester), closeTo(full, 0.5));

    await show(tester, long, open: false);
    await tester.pumpAndSettle();
    expect(textShown(tester), closeTo(8 * line, 0.5), reason: 'folded again');
  });
}
