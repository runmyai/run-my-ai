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

/// The RAM left free for the system and other apps when the user has not set it.
const defaultHeadroomGiB = 1.5;

/// The graphics card memory (VRAM) left free for the desktop and other apps when the user has not set it, and the least
/// they may set.
const defaultVramHeadroomGiB = 0.5;
const minVramHeadroomGiB = 0.25;

/// The graphics card headroom a run uses: [gib] (null: the default), at least the minimum.
double vramHeadroomOf(double? gib) => max(gib ?? defaultVramHeadroomGiB, minVramHeadroomGiB);

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

/// [command] with its --moe-stream-ram-free set to [gib].
String withRamFree(String command, double gib) {
  final str = gib == gib.roundToDouble() ? '${gib.round()}GiB' : '${gib}GiB';
  final pattern = RegExp(r'(^|\s)--moe-stream-ram-free([ =])\S+');
  if (pattern.hasMatch(command)) {
    return command.replaceFirstMapped(pattern, (m) => '${m[1]}--moe-stream-ram-free${m[2]}$str');
  }
  return '$command --moe-stream-ram-free $str';
}

/// [command] with the value of its --moe-stream-vram-free set to [gib]; a command without that flag (no graphics card
/// memory in use) is unchanged.
String withVramFree(String command, double gib) {
  final pattern = RegExp(r'(^|\s)--moe-stream-vram-free([ =])\S+');
  return command.replaceFirstMapped(pattern, (m) => '${m[1]}--moe-stream-vram-free${m[2]}${(gib * 1024).round()}MiB');
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
