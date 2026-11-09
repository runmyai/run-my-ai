// Following the reply being written (lib/ui/follow.dart): each rule agreed with the user, on a list whose last
// item grows like a reply.
// Run: flutter test test/follow_test.dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/ui/follow.dart';

/// A conversation: [messages] of 100 px, then the reply, [reply] px tall. The view is 600 px.
class _Chat extends StatefulWidget {
  const _Chat({super.key});

  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> with TickerProviderStateMixin {
  final scroll = ScrollController();
  late final follow = ReplyFollower(scroll: scroll, vsync: this);
  int messages = 2;
  double reply = 24;
  bool replying = false;

  @override
  void dispose() {
    follow.dispose();
    scroll.dispose();
    super.dispose();
  }

  void update(void Function() change) => setState(change);

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      follow.replying = replying;
      follow.changed();
    });
    return MaterialApp(
      home: Center(
        child: SizedBox(
          width: 400,
          height: 600,
          child: NotificationListener<Notification>(
            onNotification: follow.handle,
            child: follow.scrollbar(
              context,
              ListView(
                controller: scroll,
                physics: follow.physics,
                children: [
                  for (var i = 0; i < messages; i++) const SizedBox(height: 100),
                  SizedBox(height: reply),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  final key = GlobalKey<_ChatState>();
  late WidgetTester t;
  _ChatState chat() => key.currentState!;
  ScrollPosition position() => chat().scroll.position;
  double fromEnd() => position().maxScrollExtent - position().pixels;

  /// Following: within a line of the end (a new line moves the page up to it almost at once).
  const atEnd = 24.0;

  Future<void> start(WidgetTester tester, {int messages = 2}) async {
    t = tester;
    await tester.pumpWidget(_Chat(key: key));
    chat().update(() => chat().messages = messages);
    await tester.pump();
  }

  /// The user sends a message: the follower is asked first, as the app does, then the message and its (empty)
  /// reply are added.
  Future<void> send() async {
    chat().follow.sent();
    chat().update(() {
      chat().messages += 2;
      chat().reply = 24;
      chat().replying = true;
    });
    await t.pump(const Duration(milliseconds: 16));
  }

  /// The reply grows [px] a frame for [frames] frames.
  Future<void> grow(int frames, {double px = 4}) async {
    for (var i = 0; i < frames; i++) {
      chat().update(() => chat().reply += px);
      await t.pump(const Duration(milliseconds: 16));
    }
  }

  /// The reply ends, and the room below it closes by [closes] px (as a real reply's does).
  Future<void> finish({double closes = 20, int frames = 10}) async {
    chat().update(() {
      chat().replying = false;
      chat().reply -= closes;
    });
    for (var i = 0; i < frames; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> wheel(double dy) async {
    await t.sendEventToBinding(
      PointerScrollEvent(position: t.getCenter(find.byType(ListView)), scrollDelta: Offset(0, dy)),
    );
    await t.pump(const Duration(milliseconds: 16));
  }

  testWidgets('1. a chat that fits on the screen counts as at the bottom: a reply that spills past it is followed', (
    tester,
  ) async {
    await start(tester);
    expect(position().maxScrollExtent, 0, reason: 'it fits');
    await send();
    await grow(150);
    expect(position().maxScrollExtent, greaterThan(300), reason: 'the reply spilled past the screen');
    expect(fromEnd(), lessThan(atEnd), reason: 'followed to its end');
    expect(chat().follow.below.value, isFalse);
  });

  testWidgets('2. following is on when a chat opens, and at the very bottom', (tester) async {
    await start(tester, messages: 20);
    expect(chat().follow.following, isTrue);
    chat().follow.stop();
    chat().follow.reset();
    expect(chat().follow.following, isTrue, reason: 'a chat opened');
  });

  testWidgets('3. only the user turns it off: scrolling up, even a little; then the page stays put', (tester) async {
    await start(tester, messages: 10);
    await send();
    await grow(30);
    expect(fromEnd(), lessThan(atEnd));
    // The app moving the page, and the list putting itself back after its content shrank, do not.
    chat().update(() => chat().reply -= 10);
    await tester.pump(const Duration(milliseconds: 16));
    expect(chat().follow.following, isTrue, reason: 'the content shrank: not the user');
    await grow(5);
    await wheel(-40);
    expect(chat().follow.following, isFalse, reason: 'the user scrolled up');
    final at = position().pixels;
    await grow(60);
    expect(position().pixels, at, reason: 'the page stayed put while the reply grew');
    expect(chat().follow.below.value, isTrue, reason: 'text below: the jump button shows');
  });

  testWidgets('4. it comes back on at the very bottom, or with the jump button', (tester) async {
    await start(tester, messages: 10);
    await send();
    await grow(30);
    await wheel(-200);
    expect(chat().follow.following, isFalse);
    await wheel(100000);
    expect(chat().follow.following, isTrue, reason: 'scrolled back to the very bottom');
    await grow(30);
    expect(fromEnd(), lessThan(atEnd), reason: 'following again');
    expect(chat().follow.below.value, isFalse);

    await wheel(-300);
    expect(chat().follow.following, isFalse);
    chat().follow.resume();
    await grow(60);
    expect(chat().follow.following, isTrue);
    expect(fromEnd(), lessThan(atEnd), reason: 'the jump button: following again');
  });

  testWidgets('5. sent while following: followed; sent while scrolled up: the page stays where it is', (tester) async {
    await start(tester, messages: 10);
    await send();
    await grow(30);
    await finish();
    await send();
    await grow(30);
    expect(fromEnd(), lessThan(atEnd), reason: 'sent at the bottom: followed');
    await finish();

    await wheel(-200);
    final at = position().pixels;
    await send();
    await grow(60);
    expect(chat().follow.following, isFalse);
    expect(position().pixels, at, reason: 'sent while scrolled up: the page stayed');
    expect(chat().follow.below.value, isTrue);
  });

  testWidgets('5. sent while the view shows the very end (though following was off): followed', (tester) async {
    await start(tester, messages: 10);
    await send();
    await grow(30);
    await finish();
    // Off, but the view is at the very end (a search match at the end, say).
    chat().follow.stop();
    expect(fromEnd(), lessThan(atEnd));
    await send();
    expect(chat().follow.following, isTrue);
    await grow(30);
    expect(fromEnd(), lessThan(atEnd), reason: 'followed');
  });

  testWidgets('6. a reply that ends (its room closing) does not stop following: the next message is followed', (
    tester,
  ) async {
    await start(tester, messages: 10);
    await send();
    await grow(60);
    await finish(closes: 24);
    expect(chat().follow.following, isTrue, reason: 'nothing the user did');
    expect(fromEnd(), lessThan(atEnd), reason: 'still at the bottom');
    await send();
    await grow(60);
    expect(fromEnd(), lessThan(atEnd), reason: 'the next reply is followed');
  });

  testWidgets('6. a message sent the moment the last reply ends (its room still closing) is followed', (tester) async {
    await start(tester, messages: 10);
    await send();
    await grow(60);
    await finish(closes: 24, frames: 1);
    await send();
    await grow(60);
    expect(chat().follow.following, isTrue);
    expect(fromEnd(), lessThan(atEnd), reason: 'the next reply is followed');
  });

  testWidgets('6. scrolled up, a reply that ends does not put following back: the next message is not followed', (
    tester,
  ) async {
    await start(tester, messages: 10);
    await send();
    await grow(60);
    await wheel(-200);
    final at = position().pixels;
    await grow(30);
    await finish();
    expect(chat().follow.following, isFalse);
    await send();
    await grow(60);
    expect(position().pixels, at, reason: 'the page stayed where the user left it');
  });

  testWidgets('7. the jump button shows only while not following and with text below', (tester) async {
    await start(tester, messages: 10);
    await send();
    for (var i = 0; i < 40; i++) {
      await grow(1, px: 6);
      expect(chat().follow.below.value, isFalse, reason: 'following: no button');
    }
    await wheel(-100);
    expect(chat().follow.below.value, isTrue);
    await wheel(100000);
    expect(chat().follow.below.value, isFalse, reason: 'at the end');
  });

  testWidgets('a new line moves the page up almost at once: a good part in the first frame, all of it in about a '
      'tenth of a second; nothing moves while a line is written', (tester) async {
    await start(tester, messages: 10);
    await send();
    await grow(20);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(fromEnd(), lessThan(0.5));
    final still = position().pixels;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(position().pixels, still, reason: 'no new line: nothing moves');
    // A new line.
    chat().update(() => chat().reply += 24);
    await tester.pump(const Duration(milliseconds: 16));
    final gaps = <double>[fromEnd()];
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      gaps.add(fromEnd());
    }
    expect(gaps.first, 24, reason: 'the new line is there');
    expect(24 - gaps[1], inInclusiveRange(8, 23), reason: 'a good part at once, not all of it (it eases in)');
    expect(gaps.last, lessThan(0.5), reason: 'all of it within about a tenth of a second ($gaps)');
  });

  testWidgets('a message sent at the bottom: the page moves to it almost at once', (tester) async {
    await start(tester, messages: 10);
    await send();
    await grow(30);
    await finish();
    await send();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(fromEnd(), lessThan(0.5));
  });

  testWidgets('a very fast reply (lines a frame): the page stays within two lines of the end', (tester) async {
    await start(tester, messages: 10);
    await send();
    for (var i = 0; i < 40; i++) {
      await grow(1, px: 120);
      // (Once following has started, a frame or two after the message is sent.)
      if (i >= 2) expect(fromEnd(), lessThanOrEqualTo(48 + 120 + 0.5), reason: 'frame $i');
    }
  });

  testWidgets('the end of a reply still coming out after it is done is followed', (tester) async {
    await start(tester, messages: 10);
    await send();
    await grow(30);
    // The model is done, but the last words keep coming out for a moment.
    chat().update(() => chat().replying = false);
    await grow(20, px: 8);
    expect(fromEnd(), lessThan(atEnd));
  });

  testWidgets('the scroll bar does not show while the page follows; it shows when the user scrolls', (tester) async {
    await start(tester, messages: 10);
    double shown() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((p) => p.foregroundPainter)
        .whereType<ScrollbarPainter>()
        .single
        .fadeoutOpacityAnimation
        .value;
    await send();
    for (var i = 0; i < 40; i++) {
      await grow(1, px: i % 6 == 0 ? 24 : 0);
      expect(shown(), 0, reason: 'frame $i: following, no scroll bar');
    }
    expect(position().pixels, greaterThan(0), reason: 'the page did follow');
    await wheel(-60);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(shown(), greaterThan(0), reason: 'the user scrolled: it shows');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('8. a search match jumped to turns following off', (tester) async {
    await start(tester, messages: 10);
    await send();
    await grow(20);
    chat().follow.stop();
    chat().follow.jumpTo(100);
    await tester.pump(const Duration(milliseconds: 16));
    await grow(30);
    expect(position().pixels, 100, reason: 'stays at the match');
  });
}
