import 'dart:io';
import 'dart:math';

import 'engine_flags.dart';

/// The context length a command runs with (its -c flag); null if it has none or it is not a number.
int? contextOf(String command) {
  final args = EngineFlags.parse(command).arguments;
  for (var i = 0; i < args.length; i++) {
    for (final flag in const ['-c', '--ctx-size']) {
      if (args[i] == flag && i + 1 < args.length) return int.tryParse(args[i + 1]);
      if (args[i].startsWith('$flag=')) return int.tryParse(args[i].substring(flag.length + 1));
    }
  }
  return null;
}

/// A context length as it is shown: 65536 as "65k", 10485760 as "10M".
String contextLabel(int tokens) => tokens >= 1000000 ? '${tokens ~/ 1000000}M' : '${tokens ~/ 1000}k';

const _standardContexts = [
  4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 5242880, 10485760, //
];

/// The context lengths offered for a model whose longest is [maxContext]: the standard ones up to it. Above the last
/// standard one the model's own longest is added; when the longest shows as a standard label, that one option is
/// the full longest.
List<int> contextOptions(int maxContext) {
  final options = [for (final n in _standardContexts) if (n <= maxContext) n];
  final label = contextLabel(maxContext);
  final same = _standardContexts.where((n) => contextLabel(n) == label).firstOrNull;
  if (same != null) {
    return [...options.where((n) => n != same), maxContext]..sort();
  }
  if (maxContext > _standardContexts.last) options.add(maxContext);
  return options;
}

/// [command] with its context length set to [length].
String withContextLength(String command, int length) =>
    command.replaceFirstMapped(RegExp(r'(^|\s)(-c|--ctx-size)([ =])\d+'), (m) => '${m[1]}${m[2]}${m[3]}$length');

/// The RAM the engine leaves free for the system and other apps when the user has not set Memory headroom: the engine's own
/// default (no --moe-stream-ram-free is passed then), 1.25 GiB on Linux, 2 GiB on a Linux PC without swap, 1.5 GiB elsewhere.
final double defaultHeadroomGiB = () {
  if (!Platform.isLinux) return 1.5;
  try {
    final swap = RegExp(r'SwapTotal:\s+(\d+) kB').firstMatch(File('/proc/meminfo').readAsStringSync());
    return swap != null && swap[1] == '0' ? 2.0 : 1.25;
  } on IOException {
    return 1.25;
  }
}();

/// The graphics card memory (VRAM) left free for the desktop and other apps when the user has not set it, and the least
/// they may set.
const defaultVramHeadroomGiB = 0.5;
const minVramHeadroomGiB = 0.25;

/// The graphics card memory left free on each card: the user's value per card (by [cardKeys]), and [others] for a card
/// without one of its own (the single value older versions saved, else the default). Never under the minimum.
class VramHeadroom {
  const VramHeadroom({this.byCard = const {}, this.others = defaultVramHeadroomGiB});

  final Map<String, double> byCard;
  final double others;

  double of(String card) => max(byCard[card] ?? others, minVramHeadroomGiB);

  /// The same settings give the same text, so an engine started with them can be told from one started with others.
  String get key => '$others ${(byCard.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}').join(',')}';
}

/// The context cache types the app offers: the engine's names.
const kvTypes = ['q4_0', 'q8_0', 'f16'];

/// [command] with its context cache (keys and values) of type [type] (one of [kvTypes]).
String withKvType(String command, String type) {
  for (final flag in ['-ctk', '-ctv']) {
    final pattern = RegExp('(^|\\s)$flag([ =])\\S+');
    command = pattern.hasMatch(command)
        ? command.replaceFirstMapped(pattern, (m) => '${m[1]}$flag${m[2]}$type')
        : '$command $flag $type';
  }
  return command;
}

String _withRamFreeText(String command, String str) {
  final pattern = RegExp(r'(^|\s)--moe-stream-ram-free([ =])\S+');
  if (pattern.hasMatch(command)) {
    return command.replaceFirstMapped(pattern, (m) => '${m[1]}--moe-stream-ram-free${m[2]}$str');
  }
  return '$command --moe-stream-ram-free $str';
}

/// [command] with the value of its --moe-stream-vram-free set to [value] (a size, or a list per card); a command without
/// that flag (no graphics card memory in use) is unchanged.
String withVramFree(String command, String value) {
  final pattern = RegExp(r'(^|\s)--moe-stream-vram-free([ =])\S+');
  return command.replaceFirstMapped(pattern, (m) => '${m[1]}--moe-stream-vram-free${m[2]}$value');
}

/// [command] without --moe-stream-ram-free: the engine then leaves its own default free ([defaultHeadroomGiB]).
String withoutRamFree(String command) =>
    command.replaceAll(RegExp(r'(^|\s)--moe-stream-ram-free([ =])\S+'), '').trim();

/// [row] (an Auto command as the table gives it now) with what the user chose in [chosen] (the command the Settings made):
/// Memory headroom (--moe-stream-ram-free, or none) and the context cache type.
String withUserChoices(String row, String chosen) {
  final free = RegExp(r'(^|\s)--moe-stream-ram-free[ =](\S+)').firstMatch(chosen);
  row = free == null ? withoutRamFree(row) : _withRamFreeText(row, free[2]!);
  final kv = RegExp(r'(^|\s)-ctk[ =](\S+)').firstMatch(chosen);
  return kv == null ? row : withKvType(row, kv[2]!);
}

/// [args] with the model's data taken from separate files next to the model file at [modelPath] where they exist
/// (`<model>.correction`, `<model>.vram-experts.json`), instead of the copy inside the model file (`model`): an update of
/// that data then downloads a few MB, not the model. [exists] is for tests.
List<String> withModelData(List<String> args, String modelPath, {bool Function(String path)? exists}) {
  final there = exists ?? (String p) => File(p).existsSync();
  const files = {'--moe-stream-correction': '.correction', '--moe-stream-vram-experts-file': '.vram-experts.json'};
  return [
    for (var i = 0; i < args.length; i++)
      if (i > 0 && args[i] == 'model' && files[args[i - 1]] != null && there('$modelPath${files[args[i - 1]]}'))
        '$modelPath${files[args[i - 1]]}'
      else
        args[i],
  ];
}

/// The smallest context length a command may use.
const minContextLength = 1024;

// The app supplies these itself.
const _suppliedByApp = [
  '-m', '--model', '-mu', '--model-url', '-hf', '-hfr', '--hf-repo', '--host', '--port', //
  '--cache-disk', '--cache-disk-gb', '--cache-disk-checkpoints',
];

// Settings that would make the engine load another program's code.
final _unsafeSetting = RegExp(r'^(LD_|DYLD_|PATH$)');

/// What is wrong with [command] for a profile, in plain words; null when it can be saved. [taken]: the context lengths
/// the profile's other commands use.
String? commandProblem(String command, {required int maxContext, Iterable<int> taken = const []}) {
  final flags = EngineFlags.parse(command);
  for (final name in flags.environment.keys) {
    if (_unsafeSetting.hasMatch(name)) return '$name cannot be set here.';
  }
  for (final arg in flags.arguments) {
    for (final supplied in _suppliedByApp) {
      if (arg == supplied || arg.startsWith('$supplied=')) return 'Leave out $supplied: the app sets it.';
    }
  }
  final length = contextOf(command);
  if (length == null) return 'The command needs a context length: -c and a number.';
  if (length < minContextLength || length > maxContext) {
    return 'The context length must be between $minContextLength and $maxContext.';
  }
  if (taken.contains(length)) return 'This profile already has a command for $length.';
  return null;
}
