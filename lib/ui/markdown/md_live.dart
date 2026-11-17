import 'package:flutter/material.dart';

import 'md_parse.dart';
import 'md_style.dart';
import 'md_view.dart';
import 'reveal_text.dart';

/// A reply being written, drawn from its markdown as far as [edge] (a place in [text]): the text is read up to the
/// end of the edge's line. The blocks before the last one read are finished: built once each (as the finished
/// message builds them, so nothing moves when it takes over) and drawn on a layer of their own. The last block is
/// the one being written: read and built again only when the edge reaches a new line (or the text grows while the
/// edge is on its last line), drawn up to the edge by [reveal]. [text] must only grow; a new view (key) is needed
/// for a text that is not a continuation.
class MarkdownLive extends StatefulWidget {
  const MarkdownLive({super.key, required this.text, required this.edge, required this.style, required this.reveal});

  final String text;
  final double edge;
  final TextStyle style;
  final Reveal reveal;

  @override
  State<MarkdownLive> createState() => _MarkdownLiveState();
}

class _MarkdownLiveState extends State<MarkdownLive> {
  MdLook? _look;

  /// The finished blocks' widgets, and them as one layer (built again only when one is added). Finished footnotes
  /// are kept apart: they are drawn at the end, as the finished message draws them.
  final _done = <Widget>[];
  Widget? _doneLayer;
  final _notes = <Widget>[];
  bool _openNote = false;

  /// Where the block being written starts, where the text read for it ended, and its widget.
  int _from = 0;
  int _readTo = -1;
  Widget? _open;

  /// The finished groups of lines of the code block being written (see [MdBuilder.codeGroups]).
  final _codeGroups = <(int, int), Widget>{};

  @override
  Widget build(BuildContext context) {
    final look = MdLook(DefaultTextStyle.of(context).style.merge(widget.style), mdColors(context));
    if (_look?.base != look.base || _look?.colors != look.colors) {
      // A new look (the theme): everything is built again with it.
      _look = look;
      _done.clear();
      _doneLayer = null;
      _notes.clear();
      _from = 0;
      _readTo = -1;
      _codeGroups.clear();
    }
    final text = widget.text;
    var to = text.indexOf('\n', widget.edge.floor().clamp(0, text.length));
    if (to < 0) to = text.length;
    if (to != _readTo) {
      _readTo = to;
      final writing = to == text.length;
      final blocks = parseBlocks(text, from: _from, to: to, live: writing);
      if (blocks.length > 1) {
        final finished = MdBuilder(text: text);
        for (final b in blocks.take(blocks.length - 1)) {
          (b is MdFootnote ? _notes : _done).add(finished.block(b, look));
        }
        _doneLayer = null;
        _from = blocks.last.start;
        _codeGroups.clear();
      }
      final open = MdBuilder(text: text, reveal: widget.reveal, liveEnd: writing ? to : null, codeGroups: _codeGroups);
      _open = blocks.isEmpty ? open.leaf(const [], look.base, _from, look) : open.block(blocks.last, look);
      _openNote = blocks.isNotEmpty && blocks.last is MdFootnote;
    }
    if (_done.isNotEmpty) {
      _doneLayer ??= RepaintBoundary(child: mdColumn(List.of(_done), look.gap));
    }
    final notes = [..._notes, if (_openNote) _open!];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: withGaps([?_doneLayer, if (!_openNote) _open!, if (notes.isNotEmpty) mdNotes(notes, look)], look.gap),
    );
  }
}
