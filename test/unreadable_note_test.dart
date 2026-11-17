// The note at the end of the chat list about chat files that could not be read (lib/ui/chat_list.dart).
// Run: flutter test test/unreadable_note_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/chat_list.dart';

Widget host(List<String> files) => MaterialApp(
      theme: ThemeData(extensions: [AppColors.light]),
      home: Scaffold(body: UnreadableNote(files)),
    );

void main() {
  testWidgets('nothing when every file was read', (tester) async {
    await tester.pumpWidget(host(const []));
    expect(find.byKey(const Key('unreadable-note')), findsNothing);
  });

  testWidgets('one file, then several, and the names on tap', (tester) async {
    await tester.pumpWidget(host(const ['Chat/broken.json']));
    expect(find.text('1 chat file could not be read'), findsOneWidget);
    await tester.pumpWidget(host(const ['Chat/broken.json', 'Code/Odd.json']));
    expect(find.text('2 chat files could not be read'), findsOneWidget);
    await tester.tap(find.byKey(const Key('unreadable-note')));
    await tester.pump();
    expect(find.text('Chat/broken.json\nCode/Odd.json'), findsOneWidget);
  });
}
