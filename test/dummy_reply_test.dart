// The stand-in backend's replies and the reply's motion (lib/backend/dummy_backend.dart, lib/ui/live_reply.dart).
// Run: flutter test test/dummy_reply_test.dart
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/backend/dummy_backend.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/state/motion.dart';
import 'package:runmyai/ui/dev_speed_control.dart';
import 'package:runmyai/ui/live_reply.dart';

void main() {
  test('a reply split into token-sized pieces joins back into exactly the same text', () {
    final story = File('assets/dummy/story.txt').readAsStringSync().trim();
    for (final text in [story, ...DummyBackend.replies, DummyBackend.replyText]) {
      final tokens = DummyBackend.splitTokens(text);
      expect(tokens.join(), text);
      expect(tokens.every((t) => t.trim().length <= 5), isTrue);
    }
    final words = story.split(RegExp(r'\s+')).length;
    expect(words, inInclusiveRange(4800, 5400));
    // About as many tokens as a model would write for it.
    expect(DummyBackend.splitTokens(story).length / words, inInclusiveRange(1.1, 1.6));
  });

  testWidgets('the reply being written breaks its lines where the finished message does (no jump at the end)',
      (tester) async {
    final story = File('assets/dummy/story.txt').readAsStringSync().trim();
    final text = story.split('\n\n').take(4).join('\n\n');
    const style = TextStyle(fontSize: 15, height: 1.6, color: Color(0xFF000000));
    for (final width in [320.0, 555.0, 720.0]) {
      Widget box(Widget child) => MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: width, child: Align(alignment: Alignment.topLeft, child: child)),
                ),
              ),
            ),
          );
      await tester.pumpWidget(box(const SizedBox(key: Key('done'))));
      await tester.pumpWidget(box(SelectableText(text, key: const Key('done'), style: style)));
      final done = tester.getSize(find.byKey(const Key('done'))).height;
      // Opened while being written: all of it is out, shown by the reply view.
      await tester.pumpWidget(box(LiveReply(
          key: const Key('live'), text: text, live: true, style: style, done: const SizedBox())));
      final live = tester.getSize(find.byKey(const Key('live'))).height;
      expect(live, closeTo(done, 0.5), reason: 'width $width');
    }
  });

  for (final (name, motion) in [
    ('the default motion', const Motion()),
    ('no even pace, no momentum, a sharp edge', const Motion(evenPace: false, momentum: false, softness: 0)),
    ('pen tip and fresh ink, no start slide or finish settle',
        const Motion(penTip: true, freshInk: true, startSlide: false, finishSettle: false)),
  ]) {
    testWidgets('a reply written piece by piece flows in, then becomes the normal message ($name)', (tester) async {
      const style = TextStyle(fontSize: 15, height: 1.6, color: Color(0xFF000000));
      final text = DummyBackend.replies[1];
      final tokens = DummyBackend.splitTokens(text);
      final edge = LiveEdge();
      Widget reply(String so, {required bool live}) => MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  child: LiveReply(
                    text: so,
                    live: live,
                    style: style,
                    motion: motion,
                    edge: edge,
                    done: const SizedBox(key: Key('done')),
                  ),
                ),
              ),
            ),
          );
      var so = '';
      await tester.pumpWidget(reply(so, live: true));
      double? lastTop;
      for (final t in tokens) {
        so += t;
        await tester.pumpWidget(reply(so, live: true), duration: const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 16));
        // The edge only ever moves on (down the lines), and the page can always find it. (While the first line
        // slides in it rises by up to 8 pixels.)
        final line = edge.line;
        if (line != null) {
          if (lastTop != null) expect(line.top, greaterThanOrEqualTo(lastTop - 8.01));
          lastTop = line.top;
        }
      }
      expect(lastTop, isNotNull);
      await tester.pumpWidget(reply(so, live: false));
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.byKey(const Key('done')), findsOneWidget);
      expect(edge.line, isNull, reason: 'the finished message has no edge');
    });
  }

  testWidgets('while written, the reply is exactly as tall as its lines so far: it grows a whole line when a new '
      'line starts, and not at all while a line is written', (tester) async {
    const style = TextStyle(fontSize: 15, height: 1.6, color: Color(0xFF000000));
    final story = File('assets/dummy/story.txt').readAsStringSync().trim();
    final text = story.split('\n\n').take(3).join('\n\n');
    final tokens = DummyBackend.splitTokens(text);
    Widget reply(String so) => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: LiveReply(key: const Key('live'), text: so, live: true, style: style, done: const SizedBox()),
                  ),
                ),
              ),
            ),
          ),
        );
    double height() => tester.getSize(find.byKey(const Key('live'))).height;
    var so = '';
    await tester.pumpWidget(reply(so));
    final heights = <double>{};
    for (final t in tokens) {
      so += t;
      await tester.pumpWidget(reply(so), duration: const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      heights.add(height());
    }
    // Every height it had is a whole number of lines (24 px each).
    for (final h in heights) {
      expect(h % 24, anyOf(lessThan(0.01), greaterThan(23.99)), reason: '$h is whole lines');
    }
    expect(heights.length, greaterThan(10));
  });

  test('token times vary like a real model\'s around the set speed, which is their average', () {
    final costs = DummyBackend.tokenCosts(20000, Random(1));
    final mean = costs.reduce((a, b) => a + b) / costs.length;
    expect(mean, closeTo(1, 0.02), reason: 'the set speed is the average');
    final near = costs.where((c) => c > 0.7 && c < 1.4).length / costs.length;
    final slow = costs.where((c) => c >= 2).length / costs.length;
    expect(near, greaterThan(0.95), reason: 'most close to the average');
    expect(slow, inInclusiveRange(0.01, 0.03), reason: 'about 1 in 50 much slower');
    expect(costs.toSet().length, greaterThan(19000), reason: 'not all the same');
  });

  test('a reply comes at the set speed on average, unevenly, some pieces two at a time', () async {
    final text = List.filled(100, 'one two three four').join(' ');
    final tokens = DummyBackend.splitTokens(text).length;
    final backend = DummyBackend(tokensPerSecond: 400, fixedReply: text, random: Random(2));
    final clock = Stopwatch()..start();
    final pieces = await backend
        .reply(chatId: 'c', model: DummyBackend.catalog.first.files.first, messages: const [ChatMessage(Role.user, 'hi')], run: const EngineRun(flags: '', contextLength: 4096))
        .map((e) => (e as ReplyText).text)
        .toList();
    final seconds = clock.elapsed.inMicroseconds / 1e6;
    expect(pieces.join(), text);
    expect(seconds, inInclusiveRange(tokens / 400 * 0.85, tokens / 400 * 1.4), reason: '$tokens tokens in $seconds s');
    expect(pieces.length, lessThan(tokens), reason: 'some arrive together');
  });

  test('fresh ink is a small hint at the edge at any speed: never more than 3 letters, a touch lighter', () {
    // Letters a second at 5, 20, 100 and 1000 tokens a second (about 4 letters a token), a 0.1 s settle.
    expect(LiveReply.inkLetters(20, 0.1, 3), closeTo(2, 0.001));
    expect(LiveReply.inkLetters(80, 0.1, 3), 3);
    expect(LiveReply.inkLetters(400, 0.1, 3), 3);
    expect(LiveReply.inkLetters(4000, 0.1, 3), 3);
    expect(const Motion().inkShade, 0.85);
  });

  test('everyday messages get their fixed replies (capitals and punctuation aside); others do not', () {
    for (final asked in ['Hi', 'hello!', 'HEY', 'How are you?', 'fun fact', 'What is AI?', 'coffee',
        'How do I make a good cup of coffee?', 'prime code', 'Write a Python function to check if a number is prime.']) {
      expect(DummyBackend.commonReply(asked), isNotNull, reason: asked);
    }
    expect(DummyBackend.commonReply('How are you?')!.split(RegExp(r'[.?!] ')).length, lessThanOrEqualTo(2));
    expect(DummyBackend.commonReply('coffee'), DummyBackend.commonReply('How do I make a good cup of coffee'));
    expect(DummyBackend.commonReply('hi, can you fix my code'), isNull);
    expect(DummyBackend.commonReply('why is the sky blue at night'), isNull);
    for (final text in [for (final a in ['hi', 'fun fact', 'coffee', 'prime code']) DummyBackend.commonReply(a)!]) {
      expect(DummyBackend.splitTokens(text).join(), text);
    }
  });

  testWidgets('while written, the finished paragraphs are built once and drawn on their own layer', (tester) async {
    const style = TextStyle(fontSize: 15, height: 1.6, color: Color(0xFF000000));
    Widget reply(String text) => MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                child: LiveReply(text: text, live: true, style: style, done: const SizedBox()),
              ),
            ),
          ),
        );
    // Opened midway: the first two paragraphs are done, the third is being written.
    var text = 'First paragraph.\nSecond paragraph.\nThird';
    await tester.pumpWidget(reply(text));
    final first = tester.widget<Text>(find.text('First paragraph.'));
    expect(find.ancestor(of: find.text('First paragraph.'), matching: find.byType(RepaintBoundary)), findsWidgets);
    for (final more in [' goes', ' on', ' and on.']) {
      text += more;
      await tester.pumpWidget(reply(text));
      await tester.pump(const Duration(milliseconds: 16));
      expect(identical(tester.widget<Text>(find.text('First paragraph.')), first), isTrue,
          reason: 'not built again as the reply goes on');
    }
  });

  testWidgets('the line being written is drawn up to the edge and not after it', (tester) async {
    // The test font draws every letter as a filled square, so the pixels say what was drawn.
    const style = TextStyle(fontSize: 20, height: 1, color: Color(0xFF000000));
    final key = GlobalKey();
    Widget reply(String text) => MaterialApp(
          home: Scaffold(
            backgroundColor: const Color(0xFFFFFFFF),
            body: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: key,
                child: Container(
                  color: const Color(0xFFFFFFFF),
                  width: 400,
                  child: LiveReply(
                    text: text,
                    live: true,
                    style: style,
                    motion: const Motion(momentum: false, softness: 0, freshInk: false, startSlide: false),
                    done: const SizedBox(),
                  ),
                ),
              ),
            ),
          ),
        );
    Future<int Function(int x, int y)> pixels() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final bytes = (await tester.runAsync(() async => (await boundary.toImage()).toByteData()))!;
      final width = boundary.size.width.round();
      return (x, y) => 255 - bytes.getUint8((y * width + x) * 4);
    }

    // "AAAA " is out; then "BBBB" comes and is written over a moment (even pace).
    await tester.pumpWidget(reply('AAAA '));
    await tester.pumpWidget(reply('AAAA BBBB'));
    await tester.pump(const Duration(milliseconds: 10));
    var dark = await pixels();
    expect(dark(10, 10), greaterThan(200), reason: 'A drawn');
    expect(dark(8 * 20 + 10, 10), lessThan(30), reason: 'the last B, after the edge, not drawn yet');
    await tester.pump(const Duration(milliseconds: 200));
    dark = await pixels();
    expect(dark(8 * 20 + 10, 10), greaterThan(200), reason: 'all of it out: the last B drawn');
  });

  test('momentum eases off as replies get fast: all of it up to 35 tok/s, down to 0.02 s from 45', () {
    expect(LiveReply.reactionAt(0.12, 20), closeTo(0.12, 1e-9));
    expect(LiveReply.reactionAt(0.12, 35), closeTo(0.12, 1e-9));
    expect(LiveReply.reactionAt(0.12, 40), closeTo(0.07, 1e-9));
    expect(LiveReply.reactionAt(0.12, 45), closeTo(0.02, 1e-9));
    expect(LiveReply.reactionAt(0.12, 200), closeTo(0.02, 1e-9));
  });

  test('the speed control shows the speed', () {
    expect(DevSpeedControl.label(0.1), '0.1');
    expect(DevSpeedControl.label(7.25), '7.3');
    expect(DevSpeedControl.label(20), '20');
    expect(DevSpeedControl.label(5000), '5000');
  });
}
