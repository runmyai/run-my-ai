/// The text a prompt test reads: its story, from the start. (With several sources a prompt takes one passage from each
/// in turn, each passage once.)
class PromptCorpus {
  PromptCorpus(List<String> sources) : _sources = [for (final s in sources) _passages(s)];

  final List<List<String>> _sources;

  /// The longest text it can make, in characters.
  int get capacity {
    var sum = 0;
    for (final source in _sources) {
      for (final p in source) {
        sum += p.length + 2;
      }
    }
    return sum;
  }

  /// A text of about [chars] characters (fewer when the sources hold less), cut at a word.
  String build(int chars) {
    final next = List.filled(_sources.length, 0);
    final out = StringBuffer();
    var length = 0;
    var progressed = true;
    while (length < chars && progressed) {
      progressed = false;
      for (var s = 0; s < _sources.length && length < chars; s++) {
        if (next[s] >= _sources[s].length) continue;
        final passage = _sources[s][next[s]++];
        out
          ..write(passage)
          ..write('\n\n');
        length += passage.length + 2;
        progressed = true;
      }
    }
    var text = out.toString();
    if (text.length > chars) {
      final cut = text.lastIndexOf(RegExp(r'\s'), chars);
      text = text.substring(0, cut > chars ~/ 2 ? cut : chars);
    }
    return text.trimRight();
  }

  /// A source's passages: its paragraphs, with code fences and table lines left out, short bits joined to the next.
  static List<String> _passages(String text) {
    final out = <String>[];
    final buffer = StringBuffer();
    var fenced = false;
    for (final block in text.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'))) {
      final lines = <String>[];
      for (final line in block.split('\n')) {
        if (line.trimLeft().startsWith('```')) {
          fenced = !fenced;
          continue;
        }
        if (fenced || line.trimLeft().startsWith('|')) continue;
        lines.add(line);
      }
      final paragraph = lines.join('\n').trim();
      if (paragraph.isEmpty) continue;
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write(paragraph);
      if (buffer.length >= 240) {
        out.add(buffer.toString());
        buffer.clear();
      }
    }
    if (buffer.isNotEmpty) out.add(buffer.toString());
    return out;
  }
}

/// The two warm-up messages every test sends first, in the same conversation as the measured message. Their replies
/// are not counted.
const warmupMessages = [
  'Hello bro, how are you? what are you doing? tell me in 5 sentences.',
  'Tell me about yourself. In 5 sentences.',
];

/// The measured message of the reply-speed test, and the most tokens its reply may have.
const replySpeedRequest = 'write a long random story of 1500 words.';
const replySpeedMaxTokens = 2000;

/// What the measured message of a prompt test says after its story, and the most tokens its reply may have.
const promptReviewRequest =
    'Write a short review of the story above. If the story feels cut off in the middle, just write the review based '
    'on what is covered so far.';
const promptReviewMaxTokens = 200;

/// About how many tokens the two warm-up messages and their replies take in the conversation: counted against the
/// context length when a prompt test is checked for fitting.
const warmupRoomTokens = 400;

/// A message of [target] tokens, within [tolerance] (a share): the text is cut at a word, followed at the very end by
/// [request], counted by [count] (the engine's own tokenizer) and lengthened or shortened until it is that long.
/// Returns the message and its token count; when the corpus is too short to reach [target], the longest it can make.
Future<({String text, int tokens})> fitPrompt(
  PromptCorpus corpus,
  int target,
  Future<int> Function(String text) count, {
  String request = promptReviewRequest,
  double tolerance = 0.002,
  int attempts = 6,
}) async {
  String message(int chars) => '${corpus.build(chars)}\n\n$request';
  var chars = (target * 4.0).round();
  var text = message(chars);
  var tokens = await count(text);
  for (var i = 0; i < attempts && tokens > 0 && (tokens - target).abs() > target * tolerance; i++) {
    if (tokens > target || chars < corpus.capacity) {
      chars = (chars * target / tokens).round();
      text = message(chars);
      tokens = await count(text);
    } else {
      break;
    }
  }
  return (text: text, tokens: tokens);
}
