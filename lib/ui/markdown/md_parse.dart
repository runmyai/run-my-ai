/// Markdown as the models write it, read into blocks and runs that remember where each piece is in the message's
/// text. The places are what let search marks (found in the raw text) and the edge of a reply being written (a place
/// in the raw text) land on the drawn text.
///
/// What is read: paragraphs (a single line break stays a line break, as chat replies mean it), # headings and
/// headings underlined with === or ---, ``` / ~~~ code blocks and code indented by four spaces, > quotes, - * + and
/// 1. 1) lists (nested by indentation, - [ ] task items), pipe tables, --- *** ___ rules, $$ ... $$ and \[ ... \]
/// formulas, [^1]: footnotes; inside text: **bold**, *italic*, ~~struck~~, `code`, [links](url), [^1] footnote
/// marks, <https://...>, bare https:// addresses, $ ... $ and \( ... \) formulas, backslash escapes, and the HTML
/// tags models write: <br>, <b> <strong>, <i> <em>, <u>, <s> <del>, <sup>, <sub>, <kbd>. Anything else stays plain
/// text. Reading never throws: half-written markdown is read as far as it goes.
library;

/// A part of the message's text: from [start] up to [end] (not included).
typedef Seg = ({int start, int end});

sealed class MdBlock {
  MdBlock(this.start, this.end);

  /// Where the block is in the text (from its first line's start to its last line's end).
  final int start;
  final int end;
}

/// Lines of text; [lines] are the text of each line (shown one under the other).
class MdParagraph extends MdBlock {
  MdParagraph(super.start, super.end, this.lines);
  final List<Seg> lines;
}

class MdHeading extends MdBlock {
  MdHeading(super.start, super.end, this.level, this.lines);
  final int level;
  final List<Seg> lines;
}

/// A code block: its language as written after the fence ('' when none), its lines, and whether its closing fence
/// came yet.
class MdCode extends MdBlock {
  MdCode(super.start, super.end, this.language, this.lines, this.closed);
  final String language;
  final List<Seg> lines;
  final bool closed;
}

/// A formula on its own (between $$ or \[ \]): the TeX lines, and whether it was closed yet.
class MdMath extends MdBlock {
  MdMath(super.start, super.end, this.lines, this.closed);
  final List<Seg> lines;
  final bool closed;
}

/// A table: the header row first, every row with one cell per column (a missing cell is an empty part).
class MdTable extends MdBlock {
  MdTable(super.start, super.end, this.aligns, this.rows);

  /// Each column's alignment: -1 left (or not given), 0 centre, 1 right.
  final List<int> aligns;
  final List<List<Seg>> rows;
}

class MdQuote extends MdBlock {
  MdQuote(super.start, super.end, this.children);
  final List<MdBlock> children;
}

class MdList extends MdBlock {
  MdList(super.start, super.end, this.ordered, this.first, this.items, this.loose);
  final bool ordered;

  /// The number of the first item (ordered lists).
  final int first;
  final List<MdItem> items;

  /// Blank lines between its items: drawn a little apart.
  final bool loose;
}

class MdItem {
  MdItem(this.at, this.children, this.checked);

  /// Where its text starts (after the marker).
  final int at;
  final List<MdBlock> children;

  /// A task item's box: ticked or not; null for a normal item.
  final bool? checked;
}

class MdRule extends MdBlock {
  MdRule(super.start, super.end);
}

/// A footnote's text ("[^1]: ..."), drawn with the other notes at the end of the reply: its [label] and its blocks.
class MdFootnote extends MdBlock {
  MdFootnote(super.start, super.end, this.label, this.children);
  final Seg label;
  final List<MdBlock> children;
}

enum RunKind { text, newline, math, displayMath }

/// A piece of drawn text. A text run shows the message's text from [from] to [to]; a newline run is one line break
/// standing for the text from [from] to [to] (the line's end and the next line's indentation); a math run is the
/// formula [tex] written from [from] to [to].
class MdRun {
  const MdRun(this.kind, this.from, this.to, {this.style = 0, this.link, this.tex, this.scope});

  final RunKind kind;
  final int from;
  final int to;

  /// [bold], [italic], [strike], [code], [underline], [sup], [sub] combined.
  final int style;
  final String? link;
  final String? tex;

  /// In a code block: the syntax kind of the piece (a highlight.js scope such as "keyword"), if any.
  final String? scope;

  static const bold = 1;
  static const italic = 2;
  static const strike = 4;
  static const code = 8;
  static const underline = 16;
  static const sup = 32;
  static const sub = 64;

  @override
  String toString() => '$kind($from-$to s$style${link != null ? ' $link' : ''}${tex != null ? ' $tex' : ''})';
}

/// The blocks of [text] from [from] to [to] (both at line starts or the text's ends). [live]: the text is still
/// being written and [to] is its end (a half-written last line).
List<MdBlock> parseBlocks(String text, {int from = 0, int? to, bool live = false}) {
  final end = to ?? text.length;
  final lines = <Seg>[];
  var at = from;
  while (at <= end) {
    var stop = text.indexOf('\n', at);
    if (stop < 0 || stop > end) stop = end;
    final cut = stop > at && text.codeUnitAt(stop - 1) == 0x0D ? stop - 1 : stop;
    lines.add((start: at, end: cut));
    at = stop + 1;
  }
  // A trailing newline leaves an empty last line; it changes nothing.
  return _Blocks(text, live).parse(lines);
}

/// The runs of [lines] of text (a paragraph, a heading, a table cell). [live]: the text ends here while still being
/// written, so an opened **, * or ` with text after it already styles that text.
List<MdRun> parseInline(String text, List<Seg> lines, {bool live = false}) => _Inline(text, lines, live).runs();

final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');
final _heading = RegExp(r'^ {0,3}(#{1,6})(?=[ \t]|$)');
final _rule = RegExp(r'^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$');
final _quote = RegExp(r'^ {0,3}>');
final _item = RegExp(r'^( {0,3})([-*+]|\d{1,9}[.)])(?=[ \t]|$)');
final _delimCell = RegExp(r'^:?-+:?$');
final _note = RegExp(r'^ {0,3}\[\^([^\]\s]+)\]:[ \t]?');

class _Blocks {
  _Blocks(this.text, this.live);

  final String text;
  final bool live;

  String _s(Seg l) => text.substring(l.start, l.end);

  bool _blank(Seg l) {
    for (var i = l.start; i < l.end; i++) {
      final c = text.codeUnitAt(i);
      if (c != 0x20 && c != 0x09) return false;
    }
    return true;
  }

  /// The line's indentation in columns (a tab is 4).
  int _indent(Seg l) {
    var n = 0;
    for (var i = l.start; i < l.end; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x20) {
        n++;
      } else if (c == 0x09) {
        n += 4 - n % 4;
      } else {
        break;
      }
    }
    return n;
  }

  /// The line without its first [cols] columns of indentation.
  Seg _strip(Seg l, int cols) {
    var i = l.start;
    var n = 0;
    while (i < l.end && n < cols) {
      final c = text.codeUnitAt(i);
      if (c == 0x20) {
        n++;
      } else if (c == 0x09) {
        n += 4 - n % 4;
      } else {
        break;
      }
      i++;
    }
    return (start: i, end: l.end);
  }

  /// The line without the whitespace at its ends.
  Seg _trim(Seg l) {
    var a = l.start, b = l.end;
    while (a < b && _isSpace(text.codeUnitAt(a))) {
      a++;
    }
    while (b > a && _isSpace(text.codeUnitAt(b - 1))) {
      b--;
    }
    return (start: a, end: b);
  }

  bool _mathStart(Seg l) {
    final t = _s(_trim(l));
    return _indent(l) < 4 && (t.startsWith(r'$$') || t.startsWith(r'\['));
  }

  /// A list item starting on [l]: its marker, number (ordered), where its text starts and how far its lines are
  /// indented; null when [l] does not start one.
  ({bool ordered, int number, Seg content, int width, bool empty})? _itemAt(Seg l) {
    final m = _item.firstMatch(_s(l));
    if (m == null) return null;
    final marker = m.group(2)!;
    final ordered = marker.length > 1 || (marker.codeUnitAt(0) >= 0x30 && marker.codeUnitAt(0) <= 0x39);
    final afterMarker = l.start + m.end;
    var spaces = 0;
    var i = afterMarker;
    while (i < l.end && (text.codeUnitAt(i) == 0x20 || text.codeUnitAt(i) == 0x09)) {
      i++;
      spaces++;
    }
    final empty = i >= l.end;
    // Five or more spaces after the marker: the text starts after the first one (CommonMark).
    if (empty || spaces > 4) {
      i = afterMarker + (empty ? 0 : 1);
      spaces = 1;
    }
    return (
      ordered: ordered,
      number: ordered ? int.parse(marker.substring(0, marker.length - 1)) : 0,
      content: (start: i, end: l.end),
      width: m.group(1)!.length + marker.length + spaces,
      empty: empty,
    );
  }

  /// The cells of a table row.
  List<Seg> _cells(Seg l) {
    final t = _trim(l);
    var a = t.start, b = t.end;
    if (a < b && text.codeUnitAt(a) == 0x7C) a++;
    if (b > a && text.codeUnitAt(b - 1) == 0x7C && (b - 2 < a || text.codeUnitAt(b - 2) != 0x5C)) b--;
    final cells = <Seg>[];
    var cell = a;
    for (var i = a; i < b; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x5C) {
        i++;
      } else if (c == 0x7C) {
        cells.add(_trim((start: cell, end: i)));
        cell = i + 1;
      }
    }
    cells.add(_trim((start: cell, end: b)));
    return cells;
  }

  /// The column alignments when [l] is a table's delimiter row (|---|:---:|) for a header of [columns] cells.
  List<int>? _delimiters(Seg l, int columns) {
    if (!_s(l).contains('|')) return null;
    final cells = _cells(l);
    if (cells.length != columns) return null;
    final aligns = <int>[];
    for (final c in cells) {
      final s = _s(c).replaceAll(' ', '');
      if (!_delimCell.hasMatch(s)) return null;
      final left = s.startsWith(':'), right = s.endsWith(':');
      aligns.add(left && right ? 0 : (right ? 1 : -1));
    }
    return aligns;
  }

  bool _tableAt(List<Seg> lines, int i) =>
      i + 1 < lines.length &&
      _indent(lines[i]) < 4 &&
      _s(lines[i]).contains('|') &&
      _delimiters(lines[i + 1], _cells(lines[i]).length) != null;

  /// Whether [l] starts a block that ends a paragraph above it.
  bool _interrupts(List<Seg> lines, int i) {
    final l = lines[i];
    if (_indent(l) >= 4) return false;
    final s = _s(l);
    if (_fence.hasMatch(s) ||
        _heading.hasMatch(s) ||
        _rule.hasMatch(s) ||
        _quote.hasMatch(s) ||
        _note.hasMatch(s) ||
        _mathStart(l)) {
      return true;
    }
    final item = _itemAt(l);
    if (item != null && !item.empty && (!item.ordered || item.number == 1)) return true;
    return _tableAt(lines, i);
  }

  /// The level of a heading underlined by line [j] (=== 1, --- 2), or 0 when [j] is not such an underline. While
  /// written, a last line of one or two dashes may still become a list item, so it waits.
  int _underline(List<Seg> lines, int j) {
    final l = lines[j];
    if (_indent(l) >= 4) return 0;
    final t = _s(_trim(l));
    if (RegExp(r'^=+$').hasMatch(t)) return 1;
    if (RegExp(r'^-+$').hasMatch(t) && !(live && l.end >= text.length && t.length < 3)) return 2;
    return 0;
  }

  List<MdBlock> parse(List<Seg> lines) {
    final blocks = <MdBlock>[];
    var i = 0;
    while (i < lines.length) {
      final l = lines[i];
      if (_blank(l)) {
        i++;
        continue;
      }
      final s = _s(l);
      final indent = _indent(l);

      // Code indented by four spaces (or a tab), blank lines inside it kept.
      if (indent >= 4) {
        final content = <Seg>[];
        var j = i;
        while (j < lines.length && (_blank(lines[j]) || _indent(lines[j]) >= 4)) {
          content.add(_strip(lines[j], 4));
          j++;
        }
        while (_blank(lines[j - 1])) {
          content.removeLast();
          j--;
        }
        blocks.add(MdCode(l.start, lines[j - 1].end, '', content, !live || j < lines.length));
        i = j;
        continue;
      }

      // A code block.
      final fence = indent < 4 ? _fence.firstMatch(s) : null;
      if (fence != null && !(fence.group(1)![0] == '`' && fence.group(2)!.contains('`'))) {
        final mark = fence.group(1)!;
        final language = fence.group(2)!.trim().split(RegExp(r'\s+')).first;
        final content = <Seg>[];
        var closed = false;
        var j = i + 1;
        for (; j < lines.length; j++) {
          final t = _s(_trim(lines[j]));
          if (_indent(lines[j]) < 4 && t.length >= mark.length && t.replaceAll(mark[0], '').isEmpty) {
            closed = true;
            break;
          }
          content.add(_strip(lines[j], indent));
        }
        // While written, a last line that is only the start of the closing fence is not code.
        if (!closed && live && content.isNotEmpty) {
          final t = _s(_trim(content.last));
          if (t.isNotEmpty && t.replaceAll(mark[0], '').isEmpty) content.removeLast();
        }
        final last = closed ? lines[j] : lines[j - 1];
        blocks.add(MdCode(l.start, last.end, language, content, closed));
        i = closed ? j + 1 : j;
        continue;
      }

      // A formula on its own lines.
      if (_mathStart(l)) {
        final t = _trim(l);
        final dollars = text.startsWith(r'$$', t.start);
        final close = dollars ? r'$$' : r'\]';
        final body = (start: t.start + 2, end: t.end);
        final bodyText = _s(body);
        if (bodyText.endsWith(close) && bodyText.length >= 2) {
          // All on one line: $$ x $$.
          blocks.add(MdMath(l.start, l.end, [(start: body.start, end: body.end - 2)], true));
          i++;
          continue;
        }
        if (!bodyText.contains(close)) {
          final content = <Seg>[if (body.start < body.end) body];
          var closed = false;
          var j = i + 1;
          for (; j < lines.length; j++) {
            final lt = _trim(lines[j]);
            if (_s(lt).endsWith(close)) {
              if (lt.end - 2 > lt.start) content.add((start: lt.start, end: lt.end - 2));
              closed = true;
              break;
            }
            content.add(lines[j]);
          }
          final last = closed ? lines[j] : lines[j - 1];
          blocks.add(MdMath(l.start, last.end, content, closed));
          i = closed ? j + 1 : j;
          continue;
        }
        // Closed with more text after it on the line: a paragraph (the formula is read inside it).
      }

      // A heading.
      final heading = indent < 4 ? _heading.firstMatch(s) : null;
      if (heading != null) {
        var content = _trim((start: l.start + heading.end, end: l.end));
        // Closing #s: "## Title ##".
        final closing = RegExp(r'(^|[ \t])#+$').firstMatch(_s(content));
        if (closing != null) content = _trim((start: content.start, end: content.start + closing.start));
        blocks.add(MdHeading(l.start, l.end, heading.group(1)!.length, [content]));
        i++;
        continue;
      }

      // A rule (before lists: "* * *" is a rule).
      if (indent < 4 && _rule.hasMatch(s)) {
        blocks.add(MdRule(l.start, l.end));
        i++;
        continue;
      }

      // A footnote's text: its first line, lines indented under it, and lines that carry on its paragraph.
      final note = indent < 4 ? _note.firstMatch(s) : null;
      if (note != null) {
        final at = l.start + s.indexOf('[^') + 2;
        final inner = <Seg>[(start: l.start + note.end, end: l.end)];
        var end = l.end;
        var j = i + 1;
        var blankBefore = false;
        while (j < lines.length) {
          final n = lines[j];
          if (_blank(n)) {
            inner.add((start: n.start, end: n.start));
            blankBefore = true;
          } else if (_indent(n) >= 4) {
            inner.add(_strip(n, 4));
            blankBefore = false;
            end = n.end;
          } else if (!blankBefore && !_interrupts(lines, j)) {
            inner.add(n);
            end = n.end;
          } else {
            break;
          }
          j++;
        }
        while (inner.length > 1 && inner.last.start == inner.last.end) {
          inner.removeLast();
        }
        blocks.add(MdFootnote(l.start, end, (start: at, end: at + note.group(1)!.length), parse(inner)));
        i = j;
        continue;
      }

      // A quote: its lines without the ">".
      if (indent < 4 && _quote.hasMatch(s)) {
        final inner = <Seg>[];
        var j = i;
        while (j < lines.length && !_blank(lines[j]) && _quote.hasMatch(_s(lines[j]))) {
          final q = text.indexOf('>', lines[j].start) + 1;
          final after = q < lines[j].end && text.codeUnitAt(q) == 0x20 ? q + 1 : q;
          inner.add((start: after, end: lines[j].end));
          j++;
        }
        blocks.add(MdQuote(l.start, lines[j - 1].end, parse(inner)));
        i = j;
        continue;
      }

      // A list.
      final item = indent < 4 ? _itemAt(l) : null;
      if (item != null) {
        i = _list(lines, i, item.ordered, item.number, blocks);
        continue;
      }

      // A table.
      if (_tableAt(lines, i)) {
        final header = _cells(l);
        final aligns = _delimiters(lines[i + 1], header.length)!;
        List<Seg> fit(List<Seg> cells, int at) => [
          for (var c = 0; c < aligns.length; c++) c < cells.length ? cells[c] : (start: at, end: at),
        ];
        final rows = [fit(header, l.end)];
        var j = i + 2;
        while (j < lines.length && !_blank(lines[j]) && !_interrupts(lines, j)) {
          rows.add(fit(_cells(lines[j]), lines[j].end));
          j++;
        }
        blocks.add(MdTable(l.start, lines[j - 1].end, aligns, rows));
        i = j;
        continue;
      }

      // A paragraph: its first line without the indentation, the next ones as written. Underlined by === or ---,
      // it is a heading.
      final content = <Seg>[_trim(l)];
      var j = i + 1;
      var underline = 0;
      while (j < lines.length && !_blank(lines[j])) {
        underline = _underline(lines, j);
        if (underline > 0 || _interrupts(lines, j)) break;
        final t = lines[j];
        var b = t.end;
        while (b > t.start && _isSpace(text.codeUnitAt(b - 1))) {
          b--;
        }
        content.add((start: t.start, end: b));
        j++;
      }
      if (underline > 0) {
        blocks.add(MdHeading(l.start, lines[j].end, underline, content));
        i = j + 1;
        continue;
      }
      blocks.add(MdParagraph(l.start, lines[j - 1].end, content));
      i = j;
    }
    return blocks;
  }

  /// Reads the list starting at line [i] into [out]; returns the line after it.
  int _list(List<Seg> lines, int i, bool ordered, int first, List<MdBlock> out) {
    final items = <MdItem>[];
    final start = lines[i].start;
    var end = lines[i].end;
    var loose = false;
    while (i < lines.length) {
      final item = _itemAt(lines[i]);
      if (item == null || item.ordered != ordered || _indent(lines[i]) >= 4) break;
      final inner = <Seg>[item.content];
      end = lines[i].end;
      i++;
      var blankBefore = false;
      while (i < lines.length) {
        final l = lines[i];
        if (_blank(l)) {
          inner.add((start: l.start, end: l.start));
          blankBefore = true;
          i++;
          continue;
        }
        if (_indent(l) >= item.width) {
          if (blankBefore) loose = true;
          inner.add(_strip(l, item.width));
        } else if (!blankBefore && !_interrupts(lines, i) && _itemAt(l) == null) {
          // A paragraph's line written without the indentation (lazy continuation).
          inner.add(l);
        } else {
          break;
        }
        end = l.end;
        blankBefore = false;
        i++;
      }
      // The blank lines after an item part it from the next one.
      while (inner.length > 1 && inner.last.start == inner.last.end) {
        inner.removeLast();
      }
      if (blankBefore && i < lines.length && _itemAt(lines[i]) != null) loose = true;
      // A task item: "[ ] " or "[x] " before its text.
      bool? checked;
      final head = inner.first;
      final h = _s(head);
      if (RegExp(r'^\[[ xX]\](?:[ \t]|$)').hasMatch(h)) {
        checked = h[1] != ' ';
        inner[0] = (start: (head.start + 4).clamp(head.start, head.end), end: head.end);
      }
      items.add(MdItem(inner.first.start, parse(inner), checked));
    }
    out.add(MdList(start, end, ordered, first, items, loose));
    return i;
  }
}

bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

bool _isPunct(int c) =>
    (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E);

bool _isAlnum(int c) => (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

/// A token of the inline reader, in places of the joined text (the lines with '\n' between them).
sealed class _Tok {}

class _Txt extends _Tok {
  _Txt(this.from, this.to);
  final int from, to;
}

class _Delim extends _Tok {
  _Delim(this.char, this.a, this.b, this.canOpen, this.canClose) : count = b - a;
  final int char;

  /// The part not used up yet: an opener uses its right end, a closer its left end.
  int a, b;
  final int count;
  final bool canOpen, canClose;
  bool dead = false;
  int get left => b - a;
}

class _Code extends _Tok {
  _Code(this.from, this.to);
  final int from, to;
}

class _Math extends _Tok {
  _Math(this.from, this.to, this.display, this.at, this.until);

  /// The formula's text, and the whole of it with its delimiters ([at] to [until]).
  final int from, to;
  final bool display;
  final int at, until;
}

class _Link extends _Tok {
  _Link(this.runs, this.url);
  final List<_SRun> runs;
  final String url;
}

class _Break extends _Tok {
  _Break(this.from, this.to);
  final int from, to;
}

/// A footnote mark: its label.
class _Note extends _Tok {
  _Note(this.from, this.to);
  final int from, to;
}

/// An HTML tag that styles text: the style it gives, whether it closes, and the tag itself.
class _Tag extends _Tok {
  _Tag(this.bit, this.close, this.from, this.to);
  final int bit;
  final bool close;
  final int from, to;
  bool used = false;
}

const _tagStyles = {
  'b': MdRun.bold,
  'strong': MdRun.bold,
  'i': MdRun.italic,
  'em': MdRun.italic,
  'u': MdRun.underline,
  's': MdRun.strike,
  'del': MdRun.strike,
  'strike': MdRun.strike,
  'sup': MdRun.sup,
  'sub': MdRun.sub,
  'kbd': MdRun.code,
};

final _tagRe = RegExp(r'^(/?)([a-z]+)(?:\s[^<>]*)?$', caseSensitive: false);

/// Whether [rest] (the text from a "<" to its end) is the start of a tag that is read: "<", "<su", "</b", "<br".
bool _halfTag(String rest) {
  final m = RegExp(r'^</?([A-Za-z]*)$').firstMatch(rest);
  if (m == null) return false;
  final name = m.group(1)!.toLowerCase();
  return 'br'.startsWith(name) || _tagStyles.keys.any((t) => t.startsWith(name));
}

/// A run in places of the joined text.
class _SRun {
  _SRun(this.kind, this.from, this.to, this.style, [this.link, this.tex]);
  final RunKind kind;
  final int from, to;
  int style;
  String? link;
  final String? tex;
}

class _Inline {
  _Inline(this.text, this.lines, this.live) {
    final b = StringBuffer();
    for (var k = 0; k < lines.length; k++) {
      _offsets.add(b.length);
      b.write(text.substring(lines[k].start, lines[k].end));
      if (k < lines.length - 1) b.write('\n');
    }
    s = b.toString();
  }

  final String text;
  final List<Seg> lines;
  final bool live;
  late final String s;
  final _offsets = <int>[];

  List<MdRun> runs() {
    final out = <MdRun>[];
    for (final r in _parse(0, s.length, live)) {
      _emit(r, out);
    }
    return out;
  }

  /// The line of joined place [p] (the last line starting at or before it).
  int _lineOf(int p) {
    var lo = 0, hi = _offsets.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_offsets[mid] <= p) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// The text's place for joined place [p] (a join's '\n' is the line's end).
  int _src(int p) {
    final k = _lineOf(p);
    return lines[k].start + (p - _offsets[k]).clamp(0, lines[k].end - lines[k].start);
  }

  /// Turns a joined-text run into runs of the message's text, split where lines join.
  void _emit(_SRun r, List<MdRun> out) {
    if (r.kind == RunKind.math || r.kind == RunKind.displayMath) {
      out.add(MdRun(r.kind, _src(r.from), _src(r.to), style: r.style, link: r.link, tex: r.tex));
      return;
    }
    if (r.kind == RunKind.newline) {
      out.add(MdRun(RunKind.newline, _src(r.from), _src(r.to)));
      return;
    }
    var p = r.from;
    while (p < r.to) {
      final k = _lineOf(p);
      final lineEnd = _offsets[k] + (lines[k].end - lines[k].start);
      if (p >= lineEnd) {
        // The join between line k and the next.
        out.add(MdRun(RunKind.newline, lines[k].end, k + 1 < lines.length ? lines[k + 1].start : lines[k].end));
        p = lineEnd + 1;
        continue;
      }
      final stop = r.to < lineEnd ? r.to : lineEnd;
      out.add(MdRun(RunKind.text, _src(p), _src(p) + (stop - p), style: r.style, link: r.link));
      p = stop;
    }
  }

  int _c(int i) => i >= 0 && i < s.length ? s.codeUnitAt(i) : 0x20;

  /// The runs of joined text [from] to [to].
  List<_SRun> _parse(int from, int to, bool live) {
    final toks = <_Tok>[];
    var text = from;
    void flush(int i) {
      if (i > text) toks.add(_Txt(text, i));
    }

    var i = from;
    while (i < to) {
      final c = s.codeUnitAt(i);
      // Escapes, and \( \) \[ \] formulas.
      if (c == 0x5C && i + 1 < to) {
        final n = s.codeUnitAt(i + 1);
        if (n == 0x28 || n == 0x5B) {
          final close = s.indexOf(n == 0x28 ? r'\)' : r'\]', i + 2);
          if (close >= 0 && close + 2 <= to && close > i + 2) {
            flush(i);
            toks.add(_Math(i + 2, close, n == 0x5B, i, close + 2));
            i = text = close + 2;
            continue;
          }
        }
        if (_isPunct(n)) {
          flush(i);
          toks.add(_Txt(i + 1, i + 2));
          i += 2;
          text = i;
          continue;
        }
        i++;
        continue;
      }
      // Code.
      if (c == 0x60) {
        var n = i;
        while (n < to && s.codeUnitAt(n) == 0x60) {
          n++;
        }
        final ticks = n - i;
        var close = -1;
        var j = n;
        while (j < to) {
          final k = s.indexOf('`', j);
          if (k < 0 || k >= to) break;
          var e = k;
          while (e < to && s.codeUnitAt(e) == 0x60) {
            e++;
          }
          if (e - k == ticks) {
            close = k;
            break;
          }
          j = e;
        }
        if (close < 0 && live && n < to) close = to;
        if (close >= 0) {
          flush(i);
          var a = n, b = close;
          if (b - a >= 2 &&
              s.codeUnitAt(a) == 0x20 &&
              s.codeUnitAt(b - 1) == 0x20 &&
              s.substring(a, b).trim().isNotEmpty) {
            a++;
            b--;
          }
          toks.add(_Code(a, b));
          i = text = close == to ? to : close + ticks;
          continue;
        }
        i = n;
        continue;
      }
      // Formulas: $$ ... $$ and $ ... $.
      if (c == 0x24) {
        if (_c(i + 1) == 0x24) {
          final close = s.indexOf(r'$$', i + 2);
          if (close >= 0 && close + 2 <= to && close > i + 2) {
            flush(i);
            toks.add(_Math(i + 2, close, true, i, close + 2));
            i = text = close + 2;
            continue;
          }
          i += 2;
          continue;
        }
        final close = _dollarClose(i, to);
        if (close > 0) {
          flush(i);
          toks.add(_Math(i + 1, close, false, i, close + 1));
          i = text = close + 1;
          continue;
        }
        i++;
        continue;
      }
      // Emphasis and strikethrough.
      if (c == 0x2A || c == 0x5F || c == 0x7E) {
        var n = i;
        while (n < to && s.codeUnitAt(n) == c) {
          n++;
        }
        if (c == 0x7E && n - i != 2) {
          i = n;
          continue;
        }
        final before = i == from ? 0x20 : _c(i - 1), after = n >= to ? 0x20 : _c(n);
        final leftFlank = !_isSpace(after) && (!_isPunct(after) || _isSpace(before) || _isPunct(before));
        final rightFlank = !_isSpace(before) && (!_isPunct(before) || _isSpace(after) || _isPunct(after));
        final bool open, close;
        if (c == 0x5F) {
          open = leftFlank && (!rightFlank || _isPunct(before));
          close = rightFlank && (!leftFlank || _isPunct(after));
        } else {
          open = leftFlank;
          close = rightFlank;
        }
        flush(i);
        toks.add(_Delim(c, i, n, open, close));
        i = text = n;
        continue;
      }
      // A footnote mark: [^label]. While written, a half-written one at the end is not shown yet.
      if (c == 0x5B && _c(i + 1) == 0x5E) {
        var e = i + 2;
        while (e < to && !_isSpace(s.codeUnitAt(e)) && s.codeUnitAt(e) != 0x5D && s.codeUnitAt(e) != 0x5B) {
          e++;
        }
        if (e > i + 2 && e < to && s.codeUnitAt(e) == 0x5D) {
          flush(i);
          toks.add(_Note(i + 2, e));
          i = text = e + 1;
          continue;
        }
        if (live && e == to) {
          flush(i);
          i = text = to;
          continue;
        }
      }
      // Links and images.
      if (c == 0x5B || (c == 0x21 && _c(i + 1) == 0x5B)) {
        final open = c == 0x21 ? i + 1 : i;
        final link = _linkAt(open, to);
        if (link != null) {
          flush(i);
          final inner = _parse(open + 1, link.textEnd, false);
          for (final r in inner) {
            r.link ??= link.url;
          }
          toks.add(_Link(inner, link.url));
          i = text = link.end;
          continue;
        }
        i++;
        continue;
      }
      // <https://...>, <br> and the tags that style text. While written, a half-written tag at the end is not
      // shown yet.
      if (c == 0x3C) {
        final close = s.indexOf('>', i + 1);
        if (close > 0 && close < to) {
          final inside = s.substring(i + 1, close);
          if (RegExp(r'^br\s*/?$', caseSensitive: false).hasMatch(inside)) {
            flush(i);
            toks.add(_Break(i, close + 1));
            i = text = close + 1;
            continue;
          }
          final tag = _tagRe.firstMatch(inside);
          final bit = tag == null ? null : _tagStyles[tag.group(2)!.toLowerCase()];
          if (bit != null && !(tag!.group(1)!.isNotEmpty && inside.contains(' '))) {
            flush(i);
            toks.add(_Tag(bit, tag.group(1)!.isNotEmpty, i, close + 1));
            i = text = close + 1;
            continue;
          }
          if (RegExp(r'^https?://[^\s<>]+$').hasMatch(inside)) {
            flush(i);
            toks.add(_Link([_SRun(RunKind.text, i + 1, close, 0, inside)], inside));
            i = text = close + 1;
            continue;
          }
        } else if (live && _halfTag(s.substring(i, to))) {
          flush(i);
          i = text = to;
          continue;
        }
        i++;
        continue;
      }
      // A bare web address.
      if (c == 0x68 && (s.startsWith('https://', i) || s.startsWith('http://', i)) && !_isAlnum(_c(i - 1))) {
        var e = i;
        while (e < to && !_isSpace(s.codeUnitAt(e)) && s.codeUnitAt(e) != 0x3C) {
          e++;
        }
        // Not the punctuation after it, nor a closing bracket it did not open.
        while (e > i && '.,:;!?\'"*_~'.contains(s[e - 1])) {
          e--;
        }
        while (e > i &&
            s[e - 1] == ')' &&
            ')'.allMatches(s.substring(i, e)).length > '('.allMatches(s.substring(i, e)).length) {
          e--;
        }
        final url = s.substring(i, e);
        if (url.length > 8) {
          flush(i);
          toks.add(_Link([_SRun(RunKind.text, i, e, 0, url)], url));
          i = text = e;
          continue;
        }
        i = e > i ? e : i + 1;
        continue;
      }
      i++;
    }
    flush(to);
    return _resolve(toks, to, live);
  }

  /// The closing $ of a formula opened at [i], or -1. The $ is followed by text (not a space), the closing one has
  /// text before it and no digit after it, so "$5 and $10" stays money.
  int _dollarClose(int i, int to) {
    final first = _c(i + 1);
    if (i + 1 >= to || _isSpace(first)) return -1;
    var j = i + 1;
    while (true) {
      final k = s.indexOf(r'$', j);
      if (k < 0 || k >= to) return -1;
      if (k > i + 1 &&
          !_isSpace(s.codeUnitAt(k - 1)) &&
          s.codeUnitAt(k - 1) != 0x5C &&
          !(_c(k + 1) >= 0x30 && _c(k + 1) <= 0x39)) {
        return k;
      }
      j = k + 1;
    }
  }

  /// A [text](url) link whose "[" is at [i]: where its text ends, its address and where it ends.
  ({int textEnd, String url, int end})? _linkAt(int i, int to) {
    var depth = 0;
    var j = i;
    for (; j < to; j++) {
      final c = s.codeUnitAt(j);
      if (c == 0x5C) {
        j++;
      } else if (c == 0x5B) {
        depth++;
      } else if (c == 0x5D) {
        depth--;
        if (depth == 0) break;
      }
    }
    if (j >= to || j + 1 >= to || s.codeUnitAt(j + 1) != 0x28) return null;
    var parens = 0;
    var k = j + 1;
    for (; k < to; k++) {
      final c = s.codeUnitAt(k);
      if (c == 0x28) {
        parens++;
      } else if (c == 0x29) {
        parens--;
        if (parens == 0) break;
      } else if (c == 0x0A) {
        return null;
      }
    }
    if (k >= to) return null;
    var url = s.substring(j + 2, k).trim().split(RegExp(r'\s+')).first;
    if (url.startsWith('<') && url.endsWith('>')) url = url.substring(1, url.length - 1);
    return (textEnd: j, url: url, end: k + 1);
  }

  /// Pairs the emphasis marks (CommonMark's way, simplified) and turns the tokens into runs.
  List<_SRun> _resolve(List<_Tok> toks, int to, bool live) {
    final style = List<int>.filled(toks.length, 0);
    void apply(int from, int until, int bit) {
      for (var t = from; t < until; t++) {
        style[t] |= bit;
      }
    }

    int bitFor(int char, int use) => char == 0x7E ? MdRun.strike : (use == 2 ? MdRun.bold : MdRun.italic);

    for (var ci = 0; ci < toks.length; ci++) {
      final closer = toks[ci];
      if (closer is! _Delim || !closer.canClose) continue;
      while (closer.left > 0) {
        var oi = ci - 1;
        for (; oi >= 0; oi--) {
          final o = toks[oi];
          if (o is! _Delim || o.dead || !o.canOpen || o.left == 0 || o.char != closer.char) continue;
          if (o.char == 0x7E && (o.left < 2 || closer.left < 2)) continue;
          // The rule of 3: "*a**" does not pair the * with the **.
          if ((o.canClose || closer.canOpen) &&
              (o.count + closer.count) % 3 == 0 &&
              !(o.count % 3 == 0 && closer.count % 3 == 0)) {
            continue;
          }
          break;
        }
        if (oi < 0) break;
        final o = toks[oi] as _Delim;
        final use = o.char == 0x7E ? 2 : (o.left >= 2 && closer.left >= 2 ? 2 : 1);
        o.b -= use;
        closer.a += use;
        apply(oi + 1, ci, bitFor(o.char, use));
        for (var k = oi + 1; k < ci; k++) {
          if (toks[k] case final _Delim d) d.dead = true;
        }
      }
    }
    // While written: an opened mark with text after it styles the rest already.
    if (live) {
      for (var t = 0; t < toks.length; t++) {
        final d = toks[t];
        if (d is! _Delim || d.dead || !d.canOpen || d.left == 0 || t == toks.length - 1) continue;
        if (d.char == 0x7E && d.left < 2) continue;
        final use = d.char == 0x7E ? 2 : (d.left >= 2 ? 2 : 1);
        d.b -= use;
        apply(t + 1, toks.length, bitFor(d.char, use));
      }
    }

    // The HTML tags: a closing tag styles what is between it and the nearest unused opening one of its kind. While
    // written, an opening tag with text after it styles the rest already; else an unpaired tag shows as written.
    for (var ci = 0; ci < toks.length; ci++) {
      final closer = toks[ci];
      if (closer is! _Tag || !closer.close) continue;
      for (var oi = ci - 1; oi >= 0; oi--) {
        final o = toks[oi];
        if (o is _Tag && !o.close && !o.used && o.bit == closer.bit) {
          o.used = closer.used = true;
          apply(oi + 1, ci, closer.bit);
          break;
        }
      }
    }
    if (live) {
      for (var t = 0; t < toks.length - 1; t++) {
        final o = toks[t];
        if (o is _Tag && !o.close && !o.used) {
          o.used = true;
          apply(t + 1, toks.length, o.bit);
        }
      }
    }

    final runs = <_SRun>[];
    for (var t = 0; t < toks.length; t++) {
      final st = style[t];
      switch (toks[t]) {
        case _Txt(:final from, :final to):
          runs.add(_SRun(RunKind.text, from, to, st));
        case final _Delim d:
          if (d.left > 0) runs.add(_SRun(RunKind.text, d.a, d.b, st));
        case _Code(:final from, :final to):
          runs.add(_SRun(RunKind.text, from, to, st | MdRun.code));
        case _Math(:final from, :final to, :final display, :final at, :final until):
          runs.add(_SRun(display ? RunKind.displayMath : RunKind.math, at, until, st, null, s.substring(from, to)));
        case final _Link link:
          for (final r in link.runs) {
            r.style |= st;
            runs.add(r);
          }
        case _Break(:final from, :final to):
          runs.add(_SRun(RunKind.newline, from, to, 0));
        case _Note(:final from, :final to):
          runs.add(_SRun(RunKind.text, from, to, st | MdRun.sup));
        case final _Tag tag:
          if (!tag.used) runs.add(_SRun(RunKind.text, tag.from, tag.to, st));
      }
    }
    return runs;
  }
}
