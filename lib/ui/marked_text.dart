import 'package:flutter/painting.dart';

import '../search/chat_search.dart';

/// [text] as pieces, with the parts in [marks] drawn in [markStyle]. [offset] is where [text] starts in the text the
/// marks were found in (for a piece cut out of a longer message).
List<TextSpan> markedSpans(String text, List<Span> marks, TextStyle markStyle, {int offset = 0}) {
  final pieces = <TextSpan>[];
  var at = 0;
  for (final m in marks) {
    final start = (m.start - offset).clamp(0, text.length);
    final end = (m.end - offset).clamp(0, text.length);
    if (end <= start) continue;
    if (start > at) pieces.add(TextSpan(text: text.substring(at, start)));
    pieces.add(TextSpan(text: text.substring(start, end), style: markStyle));
    at = end;
  }
  if (at < text.length) pieces.add(TextSpan(text: text.substring(at)));
  return pieces;
}
