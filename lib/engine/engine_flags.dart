/// A command box's text, split into environment settings (leading NAME=value words) and the engine's arguments.
/// Double and single quotes keep spaces inside one word. It only ever becomes arguments of the engine: no shell reads it.
class EngineFlags {
  const EngineFlags({required this.environment, required this.arguments});

  factory EngineFlags.parse(String command) {
    final words = _split(command);
    final environment = <String, String>{};
    var at = 0;
    for (; at < words.length; at++) {
      final setting = _setting.firstMatch(words[at]);
      if (setting == null) break;
      environment[setting[1]!] = setting[2]!;
    }
    return EngineFlags(environment: environment, arguments: words.sublist(at));
  }

  final Map<String, String> environment;
  final List<String> arguments;

  static final _setting = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$');

  static List<String> _split(String text) {
    final words = <String>[];
    final word = StringBuffer();
    var inWord = false;
    String? quote;
    for (final c in text.split('')) {
      if (quote != null) {
        if (c == quote) {
          quote = null;
        } else {
          word.write(c);
        }
      } else if (c == '"' || c == "'") {
        quote = c;
        inWord = true;
      } else if (c.trim().isEmpty) {
        if (inWord) words.add(word.toString());
        word.clear();
        inWord = false;
      } else {
        word.write(c);
        inWord = true;
      }
    }
    if (inWord) words.add(word.toString());
    return words;
  }
}
