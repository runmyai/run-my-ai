// Replies drawn from their markdown (lib/ui/markdown/): reading, drawing, search marks, and replies being written.
// Run: flutter test test/markdown_test.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/live_reply.dart';
import 'package:runmyai/ui/markdown/md_parse.dart';
import 'package:runmyai/ui/markdown/md_view.dart';

const _style = TextStyle(fontSize: 15, height: 1.6);

final _themes = {for (final b in Brightness.values) b: buildTheme(b)};

/// A reply in the app's theme, [width] wide.
Widget _app(Widget child, {double width = 600, Brightness brightness = Brightness.light}) => MaterialApp(
  theme: _themes[brightness],
  home: Scaffold(
    body: SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    ),
  ),
);

/// Every text span drawn under [finder], with its text and style.
List<TextSpan> _spans(WidgetTester tester, [Finder? finder]) {
  final out = <TextSpan>[];
  for (final rich in tester.widgetList<RichText>(
    find.descendant(of: finder ?? find.byType(MarkdownView), matching: find.byType(RichText)),
  )) {
    rich.text.visitChildren((s) {
      if (s is TextSpan && s.text != null) out.add(s);
      return true;
    });
  }
  return out;
}

TextStyle? _styleOf(WidgetTester tester, String text) => _spans(tester).firstWhere((s) => s.text == text).style;

String _shown(String text, List<MdRun> runs) => runs
    .map(
      (r) => switch (r.kind) {
        RunKind.text => text.substring(r.from, r.to),
        RunKind.newline => '\n',
        _ => '[${r.tex}]',
      },
    )
    .join();

const _sample = '''# Title

Some **bold**, *italic*, ***both***, ~~gone~~ and `code` with a [link](https://example.com).

## Steps

1. First
2. Second
   - nested *one*
   - nested two
3. Third

- [x] done
- [ ] open

> A quote
> on two lines

---

```python
def f(x):
    return x * 2  # double
```

| Name | Count | Note |
|:-----|------:|:----:|
| a | 1 | first |
| b | 22 | second |

Inline \$e^{i\\pi} + 1 = 0\$ and \\(a^2\\), money \$5 and \$10.

\$\$
\\int_0^1 x\\,dx = \\frac{1}{2}
\$\$

\\[ \\sum_{k=1}^n k \\]
''';

/// Underlined headings, HTML tags, footnotes (written before the end) and indented code.
const _extra = '''Setext title
===

Water is H<sub>2</sub>O and E = mc<sup>2</sup>; press <kbd>Ctrl</kbd>+<kbd>C</kbd>.<br>A <b>bold</b>, <i>slanted</i>, <u>underlined</u> and <s>struck</s> line, a <span>plain</span> tag.

A claim with a note[^1] and another[^2].

[^1]: The first note.
[^2]: The second note,
    on two lines.

Sub heading
---

    indented code
      second line

Last paragraph.
''';

List<String> _kinds(List<MdBlock> blocks) => [for (final b in blocks) b.runtimeType.toString()];

String _seg(String text, Seg s) => text.substring(s.start, s.end);

void main() {
  group('reading', () {
    test('the blocks of a reply, and where each piece of text is', () {
      final blocks = parseBlocks(_sample);
      expect(blocks.map((b) => b.runtimeType.toString()).toList(), [
        'MdHeading', 'MdParagraph', 'MdHeading', 'MdList', 'MdList', 'MdQuote', 'MdRule', 'MdCode', 'MdTable', //
        'MdParagraph', 'MdMath', 'MdMath',
      ]);
      final heading = blocks[0] as MdHeading;
      expect(heading.level, 1);
      expect(_sample.substring(heading.lines.first.start, heading.lines.first.end), 'Title');

      final list = blocks[3] as MdList;
      expect(list.ordered, isTrue);
      expect(list.first, 1);
      expect(list.items, hasLength(3));
      final nested = list.items[1].children.last as MdList;
      expect(nested.ordered, isFalse);
      expect(nested.items, hasLength(2));
      final tasks = blocks[4] as MdList;
      expect(tasks.items.map((i) => i.checked).toList(), [true, false]);

      final code = blocks[7] as MdCode;
      expect(code.language, 'python');
      expect(code.closed, isTrue);
      expect(code.lines.map((l) => _sample.substring(l.start, l.end)).toList(), [
        'def f(x):',
        '    return x * 2  # double',
      ]);

      final table = blocks[8] as MdTable;
      expect(table.aligns, [-1, 1, 0]);
      expect(table.rows, hasLength(3));
      expect(_sample.substring(table.rows[2][1].start, table.rows[2][1].end), '22');

      final math = blocks[10] as MdMath;
      expect(math.closed, isTrue);
      expect(_sample.substring(math.lines.first.start, math.lines.first.end), r'\int_0^1 x\,dx = \frac{1}{2}');
    });

    test('text styles, links and formulas inside a line; every run points at its own text', () {
      final blocks = parseBlocks(_sample);
      final p = blocks[1] as MdParagraph;
      final runs = parseInline(_sample, p.lines);
      expect(_shown(_sample, runs), 'Some bold, italic, both, gone and code with a link.');
      MdRun run(String t) => runs.firstWhere((r) => r.kind == RunKind.text && _sample.substring(r.from, r.to) == t);
      expect(run('bold').style, MdRun.bold);
      expect(run('italic').style, MdRun.italic);
      expect(run('both').style, MdRun.bold | MdRun.italic);
      expect(run('gone').style, MdRun.strike);
      expect(run('code').style, MdRun.code);
      expect(run('link').link, 'https://example.com');

      final m = blocks[9] as MdParagraph;
      final mathRuns = parseInline(_sample, m.lines);
      expect(mathRuns.where((r) => r.kind == RunKind.math).map((r) => r.tex).toList(), [r'e^{i\pi} + 1 = 0', 'a^2']);
      expect(_shown(_sample, mathRuns), endsWith(r'money $5 and $10.'), reason: 'money is not a formula');
    });

    test('plain text stays as it is: stars between spaces, snake_case, line breaks, an unclosed mark', () {
      const text = 'Use 2 * 3 * 4 and my_var_name.\nNext line.\nA lone * star and **unclosed';
      final runs = parseInline(text, (parseBlocks(text).single as MdParagraph).lines);
      expect(_shown(text, runs), text);
      expect(runs.every((r) => r.style == 0), isTrue);
    });

    test('while written, an opened mark already styles what follows it', () {
      const text = 'Some **bold so far';
      final runs = parseInline(text, (parseBlocks(text).single as MdParagraph).lines, live: true);
      expect(_shown(text, runs), 'Some bold so far');
      expect(runs.last.style, MdRun.bold);
    });

    test('code indented by four spaces, but not a list item\'s indented text or a paragraph\'s next line', () {
      const text = 'Text\n\n    code line\n\n      more\n\nAfter\n    still after\n\n- item\n\n    item text\n';
      final blocks = parseBlocks(text);
      expect(_kinds(blocks), ['MdParagraph', 'MdCode', 'MdParagraph', 'MdList']);
      final code = blocks[1] as MdCode;
      expect(code.lines.map((l) => _seg(text, l)).toList(), ['code line', '', '  more']);
      expect(code.language, '');
      expect(code.closed, isTrue);
      expect((blocks[2] as MdParagraph).lines, hasLength(2));
      expect(_kinds((blocks[3] as MdList).items.single.children), ['MdParagraph', 'MdParagraph']);
      // While written, the last code line may still grow.
      expect((parseBlocks('    code', live: true).single as MdCode).closed, isFalse);
    });

    test('headings underlined with === and ---; --- after a blank line is still a rule, tables are untouched', () {
      const text = 'Big title\n===\n\nTwo line\nsmall title\n---\n\nText\n\n---\n\n| a | b |\n|---|---|\n| 1 | 2 |\n';
      final blocks = parseBlocks(text);
      expect(_kinds(blocks), ['MdHeading', 'MdHeading', 'MdParagraph', 'MdRule', 'MdTable']);
      final h1 = blocks[0] as MdHeading, h2 = blocks[1] as MdHeading;
      expect(h1.level, 1);
      expect(_seg(text, h1.lines.single), 'Big title');
      expect(h2.level, 2);
      expect(h2.lines.map((l) => _seg(text, l)).toList(), ['Two line', 'small title']);
      expect((blocks[4] as MdTable).rows, hasLength(2));
    });

    test('while written, an underline arriving later makes the line a heading; a dash starting a list does not', () {
      expect(_kinds(parseBlocks('Title', live: true)), ['MdParagraph']);
      expect(_kinds(parseBlocks('Title\n', live: true)), ['MdParagraph']);
      expect((parseBlocks('Title\n=', live: true).single as MdHeading).level, 1);
      expect((parseBlocks('Title\n---', live: true).single as MdHeading).level, 2);
      for (final part in ['Steps:\n-', 'Steps:\n- ', 'Steps:\n--']) {
        expect(_kinds(parseBlocks(part, live: true)), ['MdParagraph'], reason: part);
      }
      expect(_kinds(parseBlocks('Steps:\n- one', live: true)), ['MdParagraph', 'MdList']);
    });

    test('footnotes: the marks as raised labels, the notes as blocks of their own', () {
      final blocks = parseBlocks(_extra);
      expect(_kinds(blocks), [
        'MdHeading', 'MdParagraph', 'MdParagraph', 'MdFootnote', 'MdFootnote', 'MdHeading', 'MdCode', 'MdParagraph', //
      ]);
      final claim = parseInline(_extra, (blocks[2] as MdParagraph).lines);
      expect(_shown(_extra, claim), 'A claim with a note1 and another2.');
      expect(claim.where((r) => r.style == MdRun.sup).map((r) => _seg(_extra, (start: r.from, end: r.to))), ['1', '2']);
      final first = blocks[3] as MdFootnote, second = blocks[4] as MdFootnote;
      expect(_seg(_extra, first.label), '1');
      expect(_seg(_extra, second.label), '2');
      final secondText = second.children.single as MdParagraph;
      expect(secondText.lines.map((l) => _seg(_extra, l)).toList(), ['The second note,', 'on two lines.']);
      expect((blocks[6] as MdCode).lines.map((l) => _seg(_extra, l)).toList(), ['indented code', '  second line']);
    });

    test('while written: a half-written mark is not shown, and a note can come after its mark', () {
      const half = 'A claim[^';
      expect(_shown(half, parseInline(half, [(start: 0, end: half.length)], live: true)), 'A claim');
      const mark = 'A claim[^1] here.';
      final runs = parseInline(mark, (parseBlocks(mark, live: true).single as MdParagraph).lines, live: true);
      expect(runs.firstWhere((r) => r.style == MdRun.sup).from, mark.indexOf('1'));
      const later = '$mark\n\n[^1]: The no';
      expect(_kinds(parseBlocks(later, live: true)), ['MdParagraph', 'MdFootnote']);
    });

    test('HTML tags: the common ones style the text, others show as written', () {
      final p = parseBlocks(_extra)[1] as MdParagraph;
      final runs = parseInline(_extra, p.lines);
      expect(
        _shown(_extra, runs),
        'Water is H2O and E = mc2; press Ctrl+C.\nA bold, slanted, underlined and struck line, a <span>plain</span> tag.',
      );
      int styleOf(String t) =>
          runs.firstWhere((r) => r.kind == RunKind.text && _seg(_extra, (start: r.from, end: r.to)) == t).style;
      expect(styleOf('2'), MdRun.sub);
      expect(styleOf('Ctrl'), MdRun.code);
      expect(styleOf('bold'), MdRun.bold);
      expect(styleOf('slanted'), MdRun.italic);
      expect(styleOf('underlined'), MdRun.underline);
      expect(styleOf('struck'), MdRun.strike);
      expect(runs.where((r) => r.style == MdRun.sup), hasLength(1));
      const more = '<strong>s</strong> <em>e</em> <del>d</del> <B>caps</B> <b>open';
      final r2 = parseInline(more, [(start: 0, end: more.length)]);
      expect(_shown(more, r2), 's e d caps <b>open', reason: 'an unclosed tag of a finished reply shows as written');
      expect(r2.firstWhere((r) => _seg(more, (start: r.from, end: r.to)) == 'caps').style, MdRun.bold);
    });

    test('while written, a half-written tag is not shown and an opened one styles what follows', () {
      List<MdRun> live(String t) => parseInline(t, [(start: 0, end: t.length)], live: true);
      expect(_shown('H<su', live('H<su')), 'H');
      expect(_shown('H</', live('H</')), 'H');
      expect(_shown('a < b', live('a < b')), 'a < b', reason: 'a comparison is not a tag');
      final open = live('E = mc<sup>2');
      expect(_shown('E = mc<sup>2', open), 'E = mc2');
      expect(open.last.style, MdRun.sup);
    });

    test('every beginning of a reply reads without an error (half-written markdown)', () {
      for (var n = 0; n <= _sample.length + _extra.length; n++) {
        final part = '$_sample\n$_extra'.substring(0, n);
        for (final live in [false, true]) {
          void walk(List<MdBlock> blocks) {
            for (final b in blocks) {
              expect(b.start, inInclusiveRange(0, part.length));
              expect(b.end, inInclusiveRange(b.start, part.length));
              switch (b) {
                case MdParagraph(:final lines) || MdHeading(:final lines):
                  parseInline(part, lines, live: live);
                case MdTable(:final rows):
                  for (final row in rows) {
                    for (final cell in row) {
                      parseInline(part, [cell], live: live);
                    }
                  }
                case MdQuote(:final children) || MdFootnote(:final children):
                  walk(children);
                case MdList(:final items):
                  for (final i in items) {
                    walk(i.children);
                  }
                default:
              }
            }
          }

          walk(parseBlocks(part, live: live));
        }
      }
    });
  });

  group('drawing', () {
    testWidgets('bold, italic, headings and lists (nested too)', (tester) async {
      await tester.pumpWidget(_app(MarkdownView(text: _sample, style: _style)));
      expect(tester.takeException(), isNull);
      expect(find.text('**'), findsNothing);
      expect(_styleOf(tester, 'bold')!.fontWeight, FontWeight.w700);
      expect(_styleOf(tester, 'italic')!.fontStyle, FontStyle.italic);
      expect(_styleOf(tester, 'both')!.fontWeight, FontWeight.w700);
      expect(_styleOf(tester, 'both')!.fontStyle, FontStyle.italic);
      expect(_styleOf(tester, 'gone')!.decoration, TextDecoration.lineThrough);
      expect(_styleOf(tester, 'code')!.fontFamily, 'monospace');
      expect(_styleOf(tester, 'link')!.decoration, TextDecoration.underline);
      expect(_styleOf(tester, 'Title')!.fontSize, greaterThan(_styleOf(tester, 'Steps')!.fontSize!));
      expect(_styleOf(tester, 'Steps')!.fontSize, greaterThan(15));
      // The list's numbers and bullets, the nested list deeper in.
      for (final marker in ['1.', '2.', '3.', '◦']) {
        expect(find.text(marker), findsWidgets, reason: marker);
      }
      expect(tester.getTopLeft(find.text('◦').first).dx, greaterThan(tester.getTopLeft(find.text('1.')).dx));
      expect(find.byIcon(Icons.check_box_outlined), findsOneWidget);
      expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
      expect(find.byType(SelectionArea), findsOneWidget, reason: 'all of it selectable');
    });

    testWidgets('a code block: boxed, monospace, coloured by its language, with a copy button', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _app(
            MarkdownView(text: _sample, style: _style),
            brightness: brightness,
          ),
        );
        final code = _spans(tester)
            .where((s) => s.style?.fontFamily == 'monospace' && s.text!.contains('def'))
            .toList();
        expect(code, isNotEmpty);
        final keyword = _spans(tester).firstWhere((s) => s.text == 'def');
        final comment = _spans(tester).firstWhere((s) => s.text == '# double');
        final c = brightness == Brightness.light ? AppColors.light : AppColors.dark3;
        expect(keyword.style!.color, isNot(c.text), reason: 'keywords coloured');
        expect(comment.style!.color, isNot(keyword.style!.color));
        expect(find.text('python'), findsOneWidget);
      }
      await tester.ensureVisible(find.byKey(const Key('copy-code')));
      await tester.tap(find.byKey(const Key('copy-code')));
      await tester.pump();
      expect(copied, 'def f(x):\n    return x * 2  # double');
      expect(find.byIcon(Icons.check_rounded), findsOneWidget, reason: 'shows it was copied');
      await tester.pump(const Duration(seconds: 2));
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
    });

    testWidgets('a table is a real table; a wide one scrolls sideways inside the reply', (tester) async {
      await tester.pumpWidget(_app(MarkdownView(text: _sample, style: _style)));
      final table = tester.widget<Table>(find.byType(Table));
      expect(table.children, hasLength(3));
      expect(table.children.first.children, hasLength(3));
      expect(_styleOf(tester, 'Name')!.fontWeight, FontWeight.w700, reason: 'the header row is bold');
      final row = '| ${List.generate(12, (i) => 'Column number $i').join(' | ')} |';
      final wide = '$row\n|${List.filled(12, '---').join('|')}|\n$row\n';
      await tester.pumpWidget(_app(MarkdownView(text: wide, style: _style), width: 320));
      expect(tester.takeException(), isNull, reason: 'no overflow');
      expect(tester.getSize(find.byType(Table)).width, greaterThan(320));
      expect(tester.getSize(find.byType(MarkdownView)).width, lessThanOrEqualTo(320));
    });

    testWidgets('a table uses the width it has: a long column gets the room, a short one stays narrow', (tester) async {
      final long = List.generate(40, (i) => 'word$i').join(' ');
      final text = '| Key | Description |\n|---|---|\n| a | $long |\n| b | short |\n';
      Size cell(String start) =>
          tester.getSize(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith(start)).first);
      await tester.pumpWidget(_app(MarkdownView(text: text, style: _style), width: 800));
      expect(tester.takeException(), isNull);
      expect(cell('word0').width, greaterThan(_style.fontSize! * 24), reason: 'wider than the old cap');
      expect(tester.getSize(find.byType(Table)).width, lessThanOrEqualTo(800), reason: 'wraps instead of scrolling');
      expect(cell('Key').width, lessThan(60));
      // Six words fit beside the short column on one line (the old cap wrapped them; the test font's letters are
      // as wide as they are high).
      final six = List.generate(6, (i) => 'word$i').join(' ');
      await tester.pumpWidget(
        _app(MarkdownView(text: '| Key | Description |\n|---|---|\n| a | $six |\n', style: _style), width: 800),
      );
      expect(cell('word0').width, greaterThan(_style.fontSize! * 24));
      expect(cell('word0').height, lessThan(30), reason: 'one line');
    });

    testWidgets('footnotes are drawn at the end, marks raised; tags and underlined headings drawn', (tester) async {
      await tester.pumpWidget(_app(const MarkdownView(text: _extra, style: _style)));
      expect(tester.takeException(), isNull);
      double top(String start) => tester
          .getTopLeft(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith(start)).first)
          .dy;
      expect(top('The first note'), greaterThan(top('Last paragraph')));
      expect(top('The second note'), greaterThan(top('The first note')));
      expect(find.text('1.'), findsOneWidget);
      expect(_styleOf(tester, 'Setext title')!.fontSize, greaterThan(_styleOf(tester, 'Sub heading')!.fontSize!));
      expect(_styleOf(tester, 'Sub heading')!.fontSize, greaterThan(15));
      expect(_styleOf(tester, 'underlined')!.decoration, TextDecoration.underline);
      expect(_styleOf(tester, 'struck')!.decoration, TextDecoration.lineThrough);
      expect(_styleOf(tester, 'Ctrl')!.fontFamily, 'monospace');
      expect(find.textContaining('<span>plain</span>'), findsOneWidget);
      expect(find.text('code'), findsOneWidget, reason: 'the indented code is in a code box');
      // The raised mark sits higher than the text beside it.
      final mark = find.text('1').first;
      expect(tester.getSize(mark).height, lessThan(20));
      expect(tester.getTopLeft(mark).dy, lessThan(top('A claim') - 1));
    });

    testWidgets('formulas: inline and on their own, drawn as formulas', (tester) async {
      await tester.pumpWidget(_app(MarkdownView(text: _sample, style: _style)));
      expect(tester.takeException(), isNull);
      final shown = tester.widgetList<Math>(find.byType(Math)).toList();
      // Two inline, two on their own.
      expect(shown, hasLength(4));
      expect(shown.map((m) => m.mathStyle).where((s) => s == MathStyle.display), hasLength(2));
      expect(shown.every((m) => m.parseError == null), isTrue);
      expect(find.textContaining(r'$5 and $10'), findsOneWidget, reason: 'money stays text');
      // A formula that does not read shows its TeX instead.
      await tester.pumpWidget(_app(const MarkdownView(text: r'Broken $\frac{1}{$ here', style: _style)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('search marks land on the drawn words, and the page can find where they are', (tester) async {
      const text = 'Plain words and **a bold kumquat** here.\n\n- a kumquat in a list';
      final first = text.indexOf('kumquat'), second = text.lastIndexOf('kumquat');
      const mark = TextStyle(backgroundColor: Color(0xFFFFFF00));
      await tester.pumpWidget(
        _app(
          MarkdownView(
            text: text,
            style: _style,
            marks: [(start: first, end: first + 7), (start: second, end: second + 7)],
            markStyle: mark,
          ),
        ),
      );
      final marked = _spans(tester).where((s) => s.style?.backgroundColor == mark.backgroundColor).toList();
      expect(marked.map((s) => s.text).toList(), ['kumquat', 'kumquat']);
      expect(marked.first.style!.fontWeight, FontWeight.w700, reason: 'still bold');
      final root = tester.renderObject(find.byType(MarkdownView));
      final top1 = markdownOffsetTop(root, first)!, top2 = markdownOffsetTop(root, second)!;
      expect(top2, greaterThan(top1 + 20));
      expect(top1, closeTo(tester.getTopLeft(find.byType(MarkdownView)).dy, 2));
    });

    testWidgets('a plain reply looks as it did before formatting: lines and blank lines', (tester) async {
      const text = 'One line\nanother line\n\nA new paragraph.';
      await tester.pumpWidget(_app(const MarkdownView(text: text, style: _style)));
      // Three lines and one blank line of 24 pixels each.
      expect(tester.getSize(find.byType(MarkdownView)).height, closeTo(4 * 24, 0.5));
    });
  });

  group('while written', () {
    Widget reply(String text, {required bool live, double width = 600}) => _app(
      LiveReply(
        text: text,
        live: live,
        style: _style,
        done: MarkdownView(text: text, style: _style),
      ),
      width: width,
    );

    testWidgets('nothing moves when the finished message takes over (formulas aside)', (tester) async {
      final noMath = _sample.substring(0, _sample.indexOf('Inline'));
      final longCode = '```dart\n${List.generate(70, (k) => 'final v$k = $k;').join('\n')}\n```\n\nAfter it.';
      const notesLast = 'Text with a note[^1].\n\n[^1]: The note, written last.';
      for (final text in [noMath, longCode, _extra, notesLast]) {
        for (final width in [600.0, 300.0]) {
          Widget box(Widget child) => _app(
            Align(alignment: Alignment.topLeft, child: child),
            width: width,
          );
          await tester.pumpWidget(box(MarkdownView(key: const Key('done'), text: text, style: _style)));
          final done = tester.getSize(find.byKey(const Key('done'))).height;
          // Opened while being written: all of it is out, drawn by the reply view.
          await tester.pumpWidget(
            box(LiveReply(key: const Key('live'), text: text, live: true, style: _style, done: const SizedBox())),
          );
          expect(tester.getSize(find.byKey(const Key('live'))).height, closeTo(done, 0.5), reason: 'width $width');
        }
      }
    });

    testWidgets('half-written markdown draws sensibly at every step and never throws', (tester) async {
      for (final (width, all) in [(600.0, _sample), (260.0, _sample), (600.0, _extra)]) {
        await tester.pumpWidget(reply('', live: true, width: width));
        // A few characters at a time, as tokens come.
        for (var n = 0; n <= all.length; n += 3) {
          await tester.pumpWidget(reply(all.substring(0, n), live: true, width: width));
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.takeException(), isNull, reason: 'after ${all.substring(0, n)}');
        }
        await tester.pumpWidget(reply(all, live: false, width: width));
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(tester.takeException(), isNull);
        expect(find.byType(SelectionArea), findsOneWidget, reason: 'the finished message took over');
      }
    });

    testWidgets('an unclosed code block, a half table row and a lone star show as far as they go', (tester) async {
      Future<void> show(String text) async {
        await tester.pumpWidget(reply(text, live: true));
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      }

      await show('Look:\n\n```dart\nvoid main() {\n  print(1);');
      expect(find.text('dart'), findsOneWidget, reason: 'the code box is there before its end');
      expect(find.byKey(const Key('copy-code')), findsOneWidget);
      await show('| a | b |\n|---|---|\n| 1 | 2 |\n| 3 ');
      expect(find.byType(Table), findsOneWidget);
      await show('A lone * star and **half bold');
      await show(r'Sum: $$\frac{1}{');
    });

    testWidgets('finished blocks are kept while the reply grows; a long reply stays quick to update', (tester) async {
      final parts = [
        for (var i = 0; i < 40; i++) ...[
          'Paragraph $i has **bold** words, `code` and a [link](https://example.com) in it, long enough to wrap '
              'onto a second line at this width.',
          if (i % 8 == 3) '```python\n${List.generate(30, (k) => 'value_$k = compute($k)  # line $k').join('\n')}\n```',
          if (i % 8 == 6)
            '| a | b | c |\n|---|---|---|\n${List.generate(10, (k) => '| $k | ${k * k} | row $k |').join('\n')}',
          if (i % 8 == 1) List.generate(6, (k) => '- item $k of list $i').join('\n'),
        ],
      ];
      // Ending in a long code block: its lines must not cost more per token as it grows.
      final text =
          '${parts.join('\n\n')}\n\n```python\n${List.generate(300, (k) => 'value_$k = compute($k, "text")  # line $k').join('\n')}';
      final times = <int>[];
      final clock = Stopwatch();
      await tester.pumpWidget(reply('', live: true));
      for (var n = 0; n < text.length; n += 12) {
        clock
          ..reset()
          ..start();
        await tester.pumpWidget(reply(text.substring(0, n), live: true), duration: const Duration(milliseconds: 30));
        await tester.pump(const Duration(milliseconds: 16));
        clock.stop();
        times.add(clock.elapsedMicroseconds);
      }
      expect(tester.takeException(), isNull);
      double average(Iterable<int> t) => t.reduce((a, b) => a + b) / t.length / 1000;
      final early = average(times.take(200)), late = average(times.skip(times.length - 200));
      times.sort();
      final p99 = times[(times.length * 0.99).floor()] / 1000;
      // ignore: avoid_print
      print('updates: ${times.length}, text ${text.length} chars, ms per update: early $early, late $late, p99 $p99');
      // The end of a long reply costs about what its start did: what is finished is not built again.
      expect(late, lessThan(early * 2 + 1));
    });
  });
}
