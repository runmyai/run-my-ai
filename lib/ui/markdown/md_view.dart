import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../../search/chat_search.dart' show Span;
import '../../system/open_url.dart';
import '../../theme.dart';
import '../buttons.dart';
import 'md_parse.dart';
import 'md_style.dart';
import 'reveal_text.dart';

/// The theme's colours; a plain light or dark set where the app's theme is not in place (some tests).
AppColors mdColors(BuildContext context) {
  final theme = Theme.of(context);
  return theme.extension<AppColors>() ?? (theme.brightness == Brightness.dark ? AppColors.dark3 : AppColors.light);
}

/// A finished reply drawn from its markdown: selectable (all of it, as one), links open in the browser, code blocks
/// can be copied, and the parts in [marks] (places in [text], from search) drawn in [markStyle]. Read and built once
/// per text, look and marks, not again on every rebuild of the chat.
class MarkdownView extends StatefulWidget {
  const MarkdownView({super.key, required this.text, required this.style, this.marks = const [], this.markStyle});

  final String text;
  final TextStyle style;
  final List<Span> marks;
  final TextStyle? markStyle;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  final _taps = <GestureRecognizer>[];
  String? _text;
  List<MdBlock> _blocks = const [];
  MdLook? _look;
  List<Span>? _marks;
  TextStyle? _markStyle;
  Widget? _built;

  @override
  void dispose() {
    _dropTaps();
    super.dispose();
  }

  void _dropTaps() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  Widget build(BuildContext context) {
    final look = MdLook(DefaultTextStyle.of(context).style.merge(widget.style), mdColors(context));
    if (_text != widget.text) {
      _text = widget.text;
      _blocks = parseBlocks(widget.text);
      _built = null;
    }
    if (_look?.base != look.base || _look?.colors != look.colors) {
      _look = look;
      _built = null;
    }
    if (!_sameMarks(_marks, widget.marks) || _markStyle != widget.markStyle) {
      _marks = widget.marks;
      _markStyle = widget.markStyle;
      _built = null;
    }
    if (_built == null) {
      _dropTaps();
      final b = MdBuilder(text: widget.text, marks: widget.marks, markStyle: widget.markStyle, taps: _taps);
      _built = SelectionArea(
        child: mdColumn(b.blocks(_blocks, look), look.gap, empty: b.leaf(const [], look.base, 0, look)),
      );
    }
    return _built!;
  }
}

bool _sameMarks(List<Span>? a, List<Span> b) {
  if (identical(a, b)) return true;
  if (a == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Blocks one under the other, [gap] apart; [empty] when there are none.
Widget mdColumn(List<Widget> blocks, double gap, {Widget? empty}) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  mainAxisSize: MainAxisSize.min,
  children: blocks.isEmpty && empty != null ? [empty] : withGaps(blocks, gap),
);

List<Widget> withGaps(List<Widget> blocks, double gap) => [
  for (var i = 0; i < blocks.length; i++) ...[if (i > 0 && gap > 0) SizedBox(height: gap), blocks[i]],
];

/// Builds the widgets of markdown blocks of [text]. Finished text gets [Text]s ([taps] collects the link taps, so
/// their owner can dispose of them; without it links do not react). With [reveal] the text is the part of a reply
/// being written: [RevealText]s drawn up to the edge, formulas shown as their TeX until they are done; [liveEnd] is
/// where the text written so far ends, when it ends inside these blocks.
class MdBuilder {
  MdBuilder({
    required this.text,
    this.marks = const [],
    this.markStyle,
    this.taps,
    this.reveal,
    this.liveEnd,
    this.codeGroups,
  });

  final String text;
  final List<Span> marks;
  final TextStyle? markStyle;
  final List<GestureRecognizer>? taps;
  final Reveal? reveal;
  final int? liveEnd;

  /// The finished groups of lines of code blocks being written, kept by their place in the text between builds.
  final Map<(int, int), Widget>? codeGroups;

  List<Widget> blocks(List<MdBlock> blocks, MdLook look, {int depth = 0}) => [
    for (final b in blocks) block(b, look, depth: depth),
  ];

  List<MdRun> _inline(List<Seg> lines) =>
      parseInline(text, lines, live: liveEnd != null && lines.isNotEmpty && lines.last.end >= liveEnd!);

  Widget block(MdBlock b, MdLook look, {int depth = 0}) {
    switch (b) {
      case MdParagraph(:final lines):
        return leaf(_inline(lines), look.base, b.start, look);
      case MdHeading(:final level, :final lines):
        return leaf(_inline(lines), look.heading(level), b.start, look);
      case MdCode():
        return _code(b, look);
      case MdMath(:final lines, :final closed):
        final tex = [for (final l in lines) text.substring(l.start, l.end)].join('\n');
        if (reveal != null && !closed) {
          return leaf(_plainRuns(lines), look.code.copyWith(color: look.colors.textMuted), b.start, look);
        }
        return _Sideways(
          center: true,
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: _math(tex, look, display: true)),
        );
      case MdTable():
        return _table(b, look);
      case MdQuote(:final children):
        final inner = look.quoted;
        return Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: look.colors.border, width: 3)),
          ),
          child: mdColumn(
            blocks(children, inner, depth: depth),
            inner.gap,
            empty: leaf(const [], inner.base, b.start, inner),
          ),
        );
      case MdList():
        return _list(b, look, depth);
      case MdRule():
        return Padding(
          padding: EdgeInsets.symmetric(vertical: look.gap / 4),
          child: Container(height: 1, color: look.colors.border),
        );
    }
  }

  /// [lines] as plain text runs.
  List<MdRun> _plainRuns(List<Seg> lines) => [
    for (var k = 0; k < lines.length; k++) ...[
      if (k > 0) MdRun(RunKind.newline, lines[k - 1].end, lines[k].start),
      MdRun(RunKind.text, lines[k].start, lines[k].end),
    ],
  ];

  /// A piece of text: [runs] in [style], starting at [start] in the text.
  Widget leaf(
    List<MdRun> runs,
    TextStyle style,
    int start,
    MdLook look, {
    TextAlign align = TextAlign.start,
    bool wrap = true,
  }) {
    final r = reveal;
    if (r != null) {
      return RevealText(
        text: TextSpan(style: style, children: _liveSpans(runs, style, look)),
        runs: runs,
        start: start,
        reveal: r,
        textAlign: align,
      );
    }
    return _SourceLeaf(
      runs: runs,
      child: Text.rich(
        TextSpan(style: style, children: _spans(runs, style, look)),
        textAlign: align,
        softWrap: wrap,
      ),
    );
  }

  TextStyle _runStyle(MdRun r, TextStyle style, MdLook look) {
    var s = look.styleFor(r.style, style);
    if (r.link != null) s = s.copyWith(decoration: TextDecoration.underline, decorationColor: look.colors.textMuted);
    if (r.scope != null) {
      final scope = r.scope!;
      final dot = scope.indexOf('.');
      final syntax = look.syntax[scope] ?? look.syntax[dot < 0 ? scope : scope.substring(0, dot)];
      if (syntax != null) s = s.merge(syntax);
    }
    return s;
  }

  List<InlineSpan> _liveSpans(List<MdRun> runs, TextStyle style, MdLook look) => [
    for (final r in runs)
      switch (r.kind) {
        RunKind.newline => const TextSpan(text: '\n'),
        RunKind.math || RunKind.displayMath => TextSpan(
          text: r.tex,
          style: look.styleFor(MdRun.code, style).copyWith(color: look.colors.textMuted),
        ),
        RunKind.text => TextSpan(text: text.substring(r.from, r.to), style: _runStyle(r, style, look)),
      },
  ];

  List<InlineSpan> _spans(List<MdRun> runs, TextStyle style, MdLook look) {
    final out = <InlineSpan>[];
    for (final r in runs) {
      switch (r.kind) {
        case RunKind.newline:
          out.add(const TextSpan(text: '\n'));
        case RunKind.math || RunKind.displayMath:
          out.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _math(r.tex!, look, display: r.kind == RunKind.displayMath, style: style),
            ),
          );
        case RunKind.text:
          final s = _runStyle(r, style, look);
          GestureRecognizer? tap;
          final link = r.link;
          if (link != null && taps != null) {
            tap = TapGestureRecognizer()..onTap = () => openUrl(link);
            taps!.add(tap);
          }
          final cursor = tap == null ? MouseCursor.defer : SystemMouseCursors.click;
          var at = r.from;
          for (final m in marks) {
            final a = m.start.clamp(r.from, r.to), b = m.end.clamp(r.from, r.to);
            if (b <= a || a < at) continue;
            if (a > at) out.add(TextSpan(text: text.substring(at, a), style: s, recognizer: tap, mouseCursor: cursor));
            out.add(
              TextSpan(text: text.substring(a, b), style: s.merge(markStyle), recognizer: tap, mouseCursor: cursor),
            );
            at = b;
          }
          if (at < r.to) {
            out.add(TextSpan(text: text.substring(at, r.to), style: s, recognizer: tap, mouseCursor: cursor));
          }
      }
    }
    return out;
  }

  Widget _math(String tex, MdLook look, {required bool display, TextStyle? style}) {
    final s = style ?? look.base;
    return Math.tex(
      tex,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: s,
      onErrorFallback: (_) => Text(display ? '\$\$$tex\$\$' : '\$$tex\$', style: look.styleFor(MdRun.code, s)),
    );
  }

  /// [lines] of code highlighted as [language], as runs of the text (split where the lines join).
  List<MdRun> _codeRuns(List<Seg> lines, String language) {
    final code = [for (final l in lines) text.substring(l.start, l.end)].join('\n');
    final runs = <MdRun>[];
    var line = 0, lineAt = 0;
    for (final p in highlightCode(code, language)) {
      var at = p.at;
      final end = p.at + p.length;
      while (at < end && line < lines.length) {
        final l = lines[line];
        final lineEnd = lineAt + (l.end - l.start);
        if (at >= lineEnd) {
          // The '\n' between this line and the next.
          runs.add(MdRun(RunKind.newline, l.end, line + 1 < lines.length ? lines[line + 1].start : l.end));
          at = lineEnd + 1;
          lineAt = at;
          line++;
          continue;
        }
        final stop = end < lineEnd ? end : lineEnd;
        runs.add(MdRun(RunKind.text, l.start + at - lineAt, l.start + stop - lineAt, scope: p.scope));
        at = stop;
      }
    }
    return runs;
  }

  /// Lines of code a block being written is drawn in: each finished group is highlighted and built once, so a long
  /// block costs no more per token than a short one. (Each group is highlighted on its own; the finished message
  /// highlights the block as a whole.)
  static const _codeGroup = 32;

  Widget _code(MdCode b, MdLook look) {
    final start = b.lines.isEmpty ? b.end : b.lines.first.start;
    final Widget body;
    final groups = codeGroups;
    if (reveal != null && groups != null && b.lines.length > _codeGroup) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var g = 0; g < b.lines.length; g += _codeGroup)
            () {
              final lines = b.lines.sublist(g, g + _codeGroup < b.lines.length ? g + _codeGroup : b.lines.length);
              Widget build() => leaf(_codeRuns(lines, b.language), look.code, lines.first.start, look, wrap: false);
              // Finished: a line comes after it (or the block is closed), so its text no longer changes.
              final finished = lines.length == _codeGroup && (g + _codeGroup < b.lines.length || b.closed);
              return finished ? groups.putIfAbsent((lines.first.start, lines.last.end), build) : build();
            }(),
        ],
      );
    } else {
      body = leaf(_codeRuns(b.lines, b.language), look.code, start, look, wrap: false);
    }
    return _CodeBox(
      language: b.language,
      code: [for (final l in b.lines) text.substring(l.start, l.end)].join('\n'),
      look: look,
      child: body,
    );
  }

  Widget _table(MdTable t, MdLook look) {
    final c = look.colors;
    final align = [for (final a in t.aligns) a == 0 ? TextAlign.center : (a == 1 ? TextAlign.right : TextAlign.left)];
    final bold = look.base.copyWith(fontWeight: FontWeight.w700);
    final rows = <TableRow>[
      for (var r = 0; r < t.rows.length; r++)
        TableRow(
          decoration: r == 0 ? BoxDecoration(color: Color.alphaBlend(c.text.withValues(alpha: 0.05), c.page)) : null,
          children: [
            for (var k = 0; k < t.aligns.length; k++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: leaf(
                  _inline([t.rows[r][k]]),
                  r == 0 ? bold : look.base,
                  t.rows[r][k].start,
                  look,
                  align: align[k],
                ),
              ),
          ],
        ),
    ];
    return _Sideways(
      child: Table(
        defaultColumnWidth: MinColumnWidth(const IntrinsicColumnWidth(), FixedColumnWidth(look.fontSize * 24)),
        border: TableBorder.all(color: c.border),
        children: rows,
      ),
    );
  }

  Widget _list(MdList l, MdLook look, int depth) {
    final gap = l.loose ? look.gap / 2 : 0.0;
    final last = l.first + l.items.length - 1;
    final width = l.ordered ? look.fontSize * (0.62 * '$last'.length + 1.1) : look.fontSize * 1.4;
    final rows = <Widget>[];
    for (var i = 0; i < l.items.length; i++) {
      final item = l.items[i];
      final marker = item.checked != null
          ? Icon(
              item.checked! ? Icons.check_box_outlined : Icons.check_box_outline_blank,
              size: look.fontSize * 1.1,
              color: look.base.color,
            )
          : Text(l.ordered ? '${l.first + i}.' : const ['•', '◦', '▪'][depth % 3], style: look.base);
      final children = blocks(item.children, look, depth: depth + 1);
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            SizedBox(
              width: width,
              child: Align(
                alignment: l.ordered ? Alignment.centerRight : Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.only(
                    right: l.ordered ? look.fontSize * 0.45 : 0,
                    left: l.ordered ? 0 : look.fontSize * 0.35,
                  ),
                  child: marker,
                ),
              ),
            ),
            Expanded(child: mdColumn(children, gap, empty: leaf(const [], look.base, item.at, look))),
          ],
        ),
      );
    }
    return mdColumn(rows, gap);
  }
}

/// Wide content (a table, a code block, a formula) scrolls sideways inside the reply instead of overflowing it.
class _Sideways extends StatelessWidget {
  const _Sideways({required this.child, this.center = false});

  final Widget child;
  final bool center;

  @override
  Widget build(BuildContext context) {
    if (!center) return SingleChildScrollView(scrollDirection: Axis.horizontal, child: child);
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: box.maxWidth),
          child: Center(child: child),
        ),
      ),
    );
  }
}

/// A code block: a box with the language and a copy button over the code, which scrolls sideways when wide.
class _CodeBox extends StatefulWidget {
  const _CodeBox({required this.language, required this.code, required this.look, required this.child});

  final String language;
  final String code;
  final MdLook look;
  final Widget child;

  @override
  State<_CodeBox> createState() => _CodeBoxState();
}

class _CodeBoxState extends State<_CodeBox> {
  bool _copied = false;
  Timer? _copiedOff;

  @override
  void dispose() {
    _copiedOff?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    setState(() => _copied = true);
    _copiedOff?.cancel();
    _copiedOff = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final look = widget.look;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: look.codeFill,
        border: Border.all(color: look.codeBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 3, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.language.isEmpty ? 'code' : widget.language,
                    style: TextStyle(fontSize: 12, color: look.colors.textMuted),
                  ),
                ),
                AppIconButton(
                  key: const Key('copy-code'),
                  icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
                  tooltip: _copied ? 'Copied' : 'Copy code',
                  onTap: _copy,
                  size: 26,
                  iconSize: 15,
                  radius: 5,
                  muted: true,
                ),
              ],
            ),
          ),
          _Sideways(
            child: Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 10), child: widget.child),
          ),
        ],
      ),
    );
  }
}

/// A finished piece of text and the runs it shows, so a place in the reply's text can be found on screen.
class _SourceLeaf extends SingleChildRenderObjectWidget {
  const _SourceLeaf({required this.runs, required super.child});

  final List<MdRun> runs;

  @override
  _RenderSourceLeaf createRenderObject(BuildContext context) => _RenderSourceLeaf(runs);

  @override
  void updateRenderObject(BuildContext context, _RenderSourceLeaf renderObject) => renderObject.runs = runs;
}

class _RenderSourceLeaf extends RenderProxyBox {
  _RenderSourceLeaf(this.runs);
  List<MdRun> runs;
}

/// Where the text at [offset] of a reply drawn by [MarkdownView] under [root] is on screen: the global top of its
/// line; null when no drawn text holds it.
double? markdownOffsetTop(RenderObject root, int offset) {
  _RenderSourceLeaf? found;
  void visit(RenderObject o) {
    if (found != null) return;
    if (o is _RenderSourceLeaf && o.runs.isNotEmpty && o.runs.first.from <= offset && offset <= o.runs.last.to) {
      found = o;
    } else {
      o.visitChildren(visit);
    }
  }

  visit(root);
  final leaf = found;
  if (leaf == null) return null;
  RenderParagraph? text;
  void down(RenderObject o) {
    if (text != null) return;
    if (o is RenderParagraph) {
      text = o;
    } else {
      o.visitChildren(down);
    }
  }

  down(leaf);
  final paragraph = text;
  if (paragraph == null || !paragraph.attached || !paragraph.hasSize) return null;
  // The place in the drawn text: a formula is one place there.
  var plain = 0;
  for (final r in leaf.runs) {
    if (offset < r.from) break;
    final n = r.kind == RunKind.text ? r.to - r.from : 1;
    if (offset >= r.to) {
      plain += n;
      continue;
    }
    if (r.kind == RunKind.text) plain += offset - r.from;
    break;
  }
  final caret = paragraph.getOffsetForCaret(TextPosition(offset: plain), Rect.zero);
  return paragraph.localToGlobal(caret).dy;
}
