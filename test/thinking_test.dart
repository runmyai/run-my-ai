// The thinking block (lib/ui/thinking_block.dart) and what it remembers per message (lib/state/thinking.dart).
// Run: flutter test test/thinking_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/state/thinking.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/thinking_block.dart';

typedef _Shown = ({bool show, bool thinking, String text, int? millis});

void main() {
  group('the length of a thought', () {
    test('is rounded to seconds, at least one', () {
      expect(thoughtLength(0), '1 s');
      expect(thoughtLength(1499), '1 s');
      expect(thoughtLength(1500), '2 s');
      expect(thoughtLength(11999), '12 s');
      expect(thoughtLength(59499), '59 s');
      expect(thoughtLength(59500), '1 min 0 s');
      expect(thoughtLength(125000), '2 min 5 s');
    });

    test('is the number the clock shows the moment before the thinking ends', () {
      // The delay to the next change lands exactly where the number changes, so a live title and a finished one
      // (both [thoughtLength]) never disagree.
      for (var ms = 0; ms < 200000; ms += 137) {
        final next = ms + millisToNextLength(ms);
        expect(millisToNextLength(ms), greaterThan(0));
        expect(thoughtLength(next - 1), thoughtLength(ms));
        expect(thoughtLength(next), isNot(thoughtLength(ms)));
      }
    });
  });

  group('ThinkingNotifier', () {
    late ProviderContainer container;
    late Duration now;
    setUp(() {
      now = Duration.zero;
      container = ProviderContainer(overrides: [thinkingClockProvider.overrideWithValue(() => now)]);
      addTearDown(container.dispose);
    });

    const a = (chatId: 'a', index: 1);
    const b = (chatId: 'b', index: 1);

    test('begin starts the clock and closes the block', () {
      final notifier = container.read(thinkingProvider.notifier);
      now = const Duration(seconds: 5);
      notifier.begin(a);
      now = const Duration(milliseconds: 7500);
      expect(notifier.elapsedMillis(a), 2500);
      expect(notifier.elapsedMillis(b), isNull);
      expect(container.read(thinkingProvider)[a]!.open, isFalse);
    });

    test('toggle opens and closes, and keeps the clock', () {
      final notifier = container.read(thinkingProvider.notifier);
      notifier.begin(a);
      notifier.toggle(a);
      expect(container.read(thinkingProvider)[a]!.open, isTrue);
      now = const Duration(seconds: 3);
      expect(notifier.elapsedMillis(a), 3000);
      notifier.toggle(a);
      expect(container.read(thinkingProvider)[a]!.open, isFalse);
      // A saved message has no clock, and can still be opened.
      notifier.toggle(b);
      expect(container.read(thinkingProvider)[b]!.open, isTrue);
      expect(notifier.elapsedMillis(b), isNull);
    });

    test('begin again (a reply written again) closes it and restarts the clock', () {
      final notifier = container.read(thinkingProvider.notifier);
      notifier.begin(a);
      notifier.toggle(a);
      now = const Duration(seconds: 4);
      notifier.begin(a);
      expect(container.read(thinkingProvider)[a]!.open, isFalse);
      expect(notifier.elapsedMillis(a), 0);
    });

    test('forgetFrom drops the blocks of a chat from a place on', () {
      final notifier = container.read(thinkingProvider.notifier);
      notifier.begin((chatId: 'a', index: 1));
      notifier.begin((chatId: 'a', index: 3));
      notifier.begin(b);
      notifier.forgetFrom('a', 2);
      expect(container.read(thinkingProvider).keys, {(chatId: 'a', index: 1), b});
      notifier.forgetFrom('a');
      expect(container.read(thinkingProvider).keys, {b});
    });
  });

  group('ThinkingBlock', () {
    late ValueNotifier<_Shown> shown;
    late Duration now;

    Future<ProviderContainer> start(WidgetTester tester, {String text = 'First line', bool thinking = true, int? millis}) async {
      now = Duration.zero;
      shown = ValueNotifier((show: true, thinking: thinking, text: text, millis: millis));
      addTearDown(shown.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [thinkingClockProvider.overrideWithValue(() => now)],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  child: ValueListenableBuilder<_Shown>(
                    valueListenable: shown,
                    builder: (context, s, _) => s.show
                        ? ThinkingBlock(chatId: 'chat', index: 1, text: s.text, thinking: s.thinking, millis: s.millis)
                        : const SizedBox(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
      if (thinking) {
        container.read(thinkingProvider.notifier).begin((chatId: 'chat', index: 1));
        await tester.pump();
      }
      return container;
    }

    void update({bool? show, bool? thinking, String? text, int? millis}) {
      final s = shown.value;
      shown.value = (
        show: show ?? s.show,
        thinking: thinking ?? s.thinking,
        text: text ?? s.text,
        millis: millis ?? s.millis,
      );
    }

    /// Lets the animations run (a ticker's first frame counts from zero, so one frame starts them).
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }

    Future<void> end(WidgetTester tester) async {
      update(show: false);
      await tester.pump();
    }

    final title = find.byKey(const Key('thinking-title'));
    final preview = find.byKey(const Key('thinking-preview'));

    String titleText(WidgetTester tester) =>
        tester.widget<Text>(find.descendant(of: title, matching: find.byType(Text))).data!;

    testWidgets('counts while it thinks, and says the same number once it has thought', (tester) async {
      await start(tester);
      expect(titleText(tester), 'Thinking… 1 s');
      now = const Duration(milliseconds: 11400);
      await tester.pump(const Duration(seconds: 2));
      expect(titleText(tester), 'Thinking… 11 s');

      update(thinking: false, millis: 11400);
      await tester.pump();
      expect(titleText(tester), 'Thought for 11 s');
      await end(tester);
    });

    testWidgets('the header is the same row before and after the thinking ends', (tester) async {
      await start(tester);
      now = const Duration(milliseconds: 12000);
      await tester.pump(const Duration(seconds: 2));
      final topLeft = tester.getTopLeft(title);
      final height = tester.getSize(title).height;
      final arrow = tester.getTopLeft(find.byIcon(Icons.keyboard_arrow_down));

      update(thinking: false, millis: 12000);
      await tester.pump();
      expect(tester.getTopLeft(title), topLeft);
      expect(tester.getSize(title).height, height);
      expect(tester.getTopLeft(find.byIcon(Icons.keyboard_arrow_down)), arrow);
      await end(tester);
    });

    testWidgets('is closed while it thinks, with the latest line under the header', (tester) async {
      await start(tester, text: 'First line\nSecond line');
      expect(preview, findsOneWidget);
      expect(find.descendant(of: preview, matching: find.text('Second line')), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);

      update(text: 'First line\nSecond line\nThird line');
      await settle(tester);
      expect(find.descendant(of: preview, matching: find.text('Third line')), findsOneWidget);
      expect(find.text('Second line'), findsNothing);
      await end(tester);
    });

    testWidgets('the preview goes when the thinking ends, and the block stays closed', (tester) async {
      await start(tester, text: 'One\nTwo');
      update(thinking: false, millis: 3000);
      await settle(tester);
      expect(preview, findsNothing);
      expect(find.byType(SelectableText), findsNothing);
      await end(tester);
    });

    testWidgets('a click opens it while it thinks and again after, and closes it', (tester) async {
      await start(tester, text: 'One\nTwo');
      await tester.tap(title);
      await settle(tester);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(preview, findsNothing);

      update(thinking: false, millis: 3000);
      await settle(tester);
      // It stays open as the user left it.
      expect(find.byType(SelectableText), findsOneWidget);

      await tester.tap(title);
      await settle(tester);
      expect(find.byType(SelectableText), findsNothing);
      await tester.tap(title);
      await settle(tester);
      expect(find.byType(SelectableText), findsOneWidget);
      await end(tester);
    });

    testWidgets('the time and the open state belong to the message, not to the widget', (tester) async {
      await start(tester, text: 'One\nTwo');
      await tester.tap(title);
      await settle(tester);
      now = const Duration(seconds: 7);

      // Scrolled away: the widget is gone. Back: the same count, still open.
      update(show: false);
      await tester.pump();
      expect(title, findsNothing);
      update(show: true);
      await settle(tester);
      expect(titleText(tester), 'Thinking… 7 s');
      expect(find.byType(SelectableText), findsOneWidget);
      await end(tester);
    });

    testWidgets('the header pulses while it thinks and rests when it is done', (tester) async {
      await start(tester);
      double opacity() => tester.widget<FadeTransition>(find.ancestor(of: title, matching: find.byType(FadeTransition)).first).opacity.value;
      await tester.pump(const Duration(milliseconds: 750));
      expect(opacity(), lessThan(1));
      update(thinking: false, millis: 3000);
      await tester.pump();
      await settle(tester);
      expect(opacity(), 1);
      await end(tester);
    });

    testWidgets('open, the thought follows its end unless the user scrolled up', (tester) async {
      String lines(int n) => [for (var i = 1; i <= n; i++) 'Line $i of the thought, long enough to count.'].join('\n');
      await start(tester, text: lines(30));
      await tester.tap(title);
      await settle(tester);
      await tester.pump();
      ScrollPosition position() => tester
          .state<ScrollableState>(find.descendant(of: find.byType(SingleChildScrollView), matching: find.byType(Scrollable)).first)
          .position;
      expect(position().maxScrollExtent, greaterThan(0));
      expect(position().pixels, position().maxScrollExtent);

      // More comes in: it follows.
      update(text: lines(40));
      await tester.pump();
      await tester.pump();
      expect(position().pixels, position().maxScrollExtent);

      // The user scrolls up to read: it stays where they are.
      position().jumpTo(0);
      await tester.pump();
      update(text: lines(50));
      await tester.pump();
      await tester.pump();
      expect(position().pixels, 0);
      await end(tester);
    });
  });
}
