import 'dart:convert';
import 'dart:math';

import 'commands.dart';
import 'engine_flags.dart';

/// The autotuner's result: the last JSON line it printed (a driver may print its own lines before it), or null.
Map<String, dynamic>? parseAutotunerJson(String stdout) {
  for (final raw in const LineSplitter().convert(stdout).reversed) {
    final line = raw.trim();
    if (!line.startsWith('{') || !line.endsWith('}')) continue;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic> && decoded['threads'] is int) return decoded;
    } on FormatException {
      continue;
    }
  }
  return null;
}

void _setOrAddFlag(List<String> out, String flag, String value) {
  final idx = out.indexOf(flag);
  if (idx >= 0 && idx + 1 < out.length) {
    out[idx + 1] = value;
  } else {
    out.addAll([flag, value]);
  }
}

/// The table's command with the measured settings put in: -t (replies), -tb (prompts), the fast cores, the SSD readers.
List<String> withTuning(List<String> args, Map<String, dynamic>? t) {
  if (t == null) return args;
  final out = [...args];
  final threads = t['threads'] as int;
  // the autotuner names the fast cores only when it measured them clearly faster than all cores, at this thread count: one
  // thread per fast core as a mask, and as a range too when they are numbered in one run from 0
  final mask = t['fast_mask'] as String? ?? '', fast = t['fast_cpus'] as String? ?? '';
  if (mask.isNotEmpty) {
    _setOrAddFlag(out, '--cpu-mask', mask);
  } else if (fast.isNotEmpty) {
    _setOrAddFlag(out, '--cpu-range', fast);
  }
  // prompts are compute-bound and take every core: without this their threads would be kept on the fast cores too
  if (t['logical_cores'] case final int n when n > 1 && (mask.isNotEmpty || fast.isNotEmpty)) {
    _setOrAddFlag(out, '--cpu-range-batch', '0-${n - 1}');
  }
  final i = out.indexOf('-t');
  if (i >= 0 && i + 1 < out.length) out[i + 1] = '$threads';
  if (t['threads_batch'] case final int tb when tb > threads) _setOrAddFlag(out, '-tb', '$tb');
  if (t['io_threads'] case final int io) _setOrAddFlag(out, '--moe-stream-io-threads', '$io');
  return out;
}

const _appSuppliedFlags = {
  '-m', '--model', '-mu', '--model-url', '-hf', '-hfr', '--hf-repo',
  '--host', '--port', '--cache-disk', '--cache-disk-gb', '--cache-disk-checkpoints',
};
final _blockedEnv = RegExp(r'^(LD_|DYLD_|PATH$)');

String _shellWord(String s) =>
    s.isEmpty || s.contains(' ') || s.contains('"') || s.contains("'") ? '"${s.replaceAll('"', r'\"')}"' : s;

/// Synthesizes one Auto command per context length for a Bring-Your-Own-Model GGUF from [tune] (`recommended_flags` and
/// `recommended_env` emitted by `autotuner --file`), falling back to a universal model-agnostic profile before tuning runs.
Map<int, String> commandsFromAutotuner(
  Map<String, dynamic>? tune, {
  int maxContext = 131072,
  bool isMoE = true,
  double largestGpuGiB = 0,
}) {
  final contexts = contextOptions(max(4096, maxContext));
  final recFlags = tune?['recommended_flags'];
  if (recFlags is String && recFlags.trim().isNotEmpty) {
    final parsed = EngineFlags.parse(recFlags);
    final envMap = <String, String>{
      ...parsed.environment,
      if (tune?['recommended_env'] case final Map rawEnv)
        for (final e in rawEnv.entries)
          if (e.key is String && e.value != null && !_blockedEnv.hasMatch(e.key as String))
            e.key as String: '${e.value}',
    };
    envMap.removeWhere((k, _) => _blockedEnv.hasMatch(k));
    final cleanArgs = <String>[];
    var hasCtx = false;
    for (var i = 0; i < parsed.arguments.length; i++) {
      final a = parsed.arguments[i];
      if (_appSuppliedFlags.contains(a)) {
        if (i + 1 < parsed.arguments.length && !parsed.arguments[i + 1].startsWith('-')) i++;
        continue;
      }
      if (_appSuppliedFlags.any((f) => a.startsWith('$f='))) continue;
      if (a == '-c' || a == '--ctx-size') {
        hasCtx = true;
        cleanArgs.addAll(['-c', i + 1 < parsed.arguments.length ? parsed.arguments[++i] : '8192']);
        continue;
      }
      if (a.startsWith('-c=') || a.startsWith('--ctx-size=')) {
        hasCtx = true;
        cleanArgs.addAll(['-c', a.split('=').last]);
        continue;
      }
      cleanArgs.add(a);
    }
    if (!hasCtx) cleanArgs.insertAll(0, ['-c', '8192']);
    final envPrefix = [for (final e in envMap.entries) '${e.key}=${_shellWord(e.value)}'].join(' ');
    final baseBody = [for (final a in cleanArgs) _shellWord(a)].join(' ');
    final baseCmd = envPrefix.isEmpty ? baseBody : '$envPrefix $baseBody';
    return {for (final c in contexts) c: withContextLength(baseCmd, c)};
  }

  if (!isMoE) {
    final ngl = largestGpuGiB >= 4 ? '-ngl 99' : '-ngl 0';
    return {
      for (final c in contexts)
        c: '-c $c -fa on -ctk q8_0 -ctv q8_0 $ngl -np 1 -t 8 -b 2048 -ub 2048',
    };
  }

  final hasGpu = largestGpuGiB >= 4;
  final envPrefix = hasGpu
      ? 'GGML_CUDA_COPY_KERNEL=65536 GGML_CUDA_POOL1D_ROW=1 GGML_CUDA_FUSE_AMAX=1 GGML_CUDA_MOE_MARK_IDS=1 '
      : '';
  final gpuPart = largestGpuGiB >= 10
      ? '-ngl 99 -fit off --moe-stream-vram-free 512MiB --moe-stream-vram-experts auto '
        '--moe-stream-vram-follow 1 --moe-stream-vram-parallel 1 --moe-stream-vram-copyback 1 '
        '--moe-stream-async-h2d 1 --moe-stream-elastic 1'
      : hasGpu
      ? '-ngl 99 -fit off --moe-stream-vram-free 512MiB --moe-stream-gpu-layers 0 --moe-stream-vram-experts 0 '
        '--moe-stream-elastic 1'
      : '-ngl 0 --moe-stream-gpu-layers 0 --moe-stream-vram-experts 0';
  return {
    for (final c in contexts)
      c: '$envPrefix-c $c -fa on -ctk q8_0 -ctv q8_0 -np 1 -t 8 -b 2048 -ub 2048 '
          '--moe-stream model $gpuPart --moe-stream-overlap 1 --moe-stream-io-wake chunk '
          '--moe-stream-promote 1 --moe-stream-guess-cap 2 --moe-stream-policy decay '
          '--moe-stream-plan 1 --moe-stream-drop-stale 1 --moe-stream-needed-early 1 '
          '--moe-stream-lookahead 2 --moe-stream-guess-combined 1 --moe-stream-proj-ready 1 '
          '--moe-stream-protect-named 1 --moe-stream-guess-inflight 4 --moe-stream-guess-gate 1',
  };
}

/// Several cards share the model, filled fastest first (the autotuner's measured read speed): the slowest card runs the first
/// layers with the expert pool, RAM and SSD behind it, and each faster card runs a run of the last layers completely, as
/// whole layers - as many as its memory holds while it keeps its VRAM headroom: the engine counts them (`X=auto`). One
/// hand-over between cards per run of layers. Measured with two RTX 3060: Flint 72.8 tok/s against 53.2 on one card, Qwen
/// 25.2 against 19.2, long prompts faster too.
/// The engine fills the first card named `auto` first (it gets the very last layers), then the next: the faster cards are
/// named fastest first, so the fastest card is filled fully before the next.
List<String> cardFlags(List<({String name, int mib})> cards) {
  final pool = cards.last, fast = cards.sublist(0, cards.length - 1);
  return [
    '--device', [pool.name, for (final c in fast) c.name].join(','),
    '--moe-stream-vram-device', pool.name,
    for (final c in fast) ...['--moe-stream-gpu-layers-device', '${c.name}=auto'],
  ];
}

/// A size of graphics card memory as the engine reads it, in MiB.
String vramSize(double gib) => '${(gib * 1024).round()}MiB';

/// The value of `--moe-stream-vram-free`: each card's own VRAM headroom ([headroomGiB], one per card in the order of [cards]).
/// Named cards get the list form (`POOL=512MiB,FAST=...`, the pool's card first), which also keeps the headroom free when the
/// engine fits whole layers; cards without a name yet (read before the autotuner's first run) the pool's single size.
String vramFreeValue(List<({String name, int mib})> cards, List<double> headroomGiB) {
  if (cards.any((c) => c.name.isEmpty)) return vramSize(headroomGiB.last);
  final last = cards.length - 1;
  return [
    for (final i in [last, for (var i = 0; i < last; i++) i]) '${cards[i].name}=${vramSize(headroomGiB[i])}',
  ].join(',');
}

/// What each card's setting is saved under: its name as the engine lists it (with its place in the list when two cards
/// share a name); the one unnamed card read before the autotuner's first run is "gpu".
List<String> cardKeys(List<({String name, int mib})> cards) => [
  for (var i = 0; i < cards.length; i++)
    cards[i].name.isEmpty
        ? 'gpu'
        : cards.where((c) => c.name == cards[i].name).length > 1
        ? '${cards[i].name}#$i'
        : cards[i].name,
];

/// The cards from the autotuner's result, fastest first. Without a separate card, a built-in GPU that can use 24 GiB or more
/// counts as one (a DGX Spark's GB10, a Strix Halo: Flint 76.7 and 64.8 tok/s on it against 28.2 and 32.1 CPU-only); the small
/// built-in GPUs of ordinary laptops (about half of a smaller RAM) stay unused.
List<({String name, int mib})> cardsFrom(Map<String, dynamic> tune) {
  // fastest first by the measured read speed, then the larger
  List<({String name, int mib})> read(String key) {
    final list = [for (final g in (tune[key] as List?) ?? const []) g as Map];
    list.sort((a, b) {
      final s = ((b['gbps'] as num?) ?? 0).compareTo((a['gbps'] as num?) ?? 0);
      return s != 0 ? s : (b['mib'] as int) - (a['mib'] as int);
    });
    return [for (final g in list) (name: g['name'] as String, mib: g['mib'] as int)];
  }
  final cards = read('gpus');
  if (cards.isNotEmpty) return cards;
  return read('igpus').where((g) => g.mib >= 24 * 1024).take(1).toList();
}

/// Whether this PC's NVIDIA cards need the engine built with CUDA 12, from `nvidia-smi --query-gpu=compute_cap,driver_version
/// --format=csv,noheader` (one "7.5, 580.65.06" line per card): CUDA 13 runs neither cards older than the RTX 20 series
/// (compute capability under 7.5: Maxwell, Pascal, Volta) nor drivers older than 580. Null output = no NVIDIA card (no need);
/// output that does not read as such lines = a driver too old for the query, which CUDA 13 cannot use either.
bool needsCuda12(String? nvidiaSmi) {
  if (nvidiaSmi == null) return false;
  final lines = nvidiaSmi.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
  if (lines.isEmpty) return false;
  for (final l in lines) {
    final f = l.split(',').map((x) => x.trim()).toList();
    final cc = f.isNotEmpty ? double.tryParse(f[0]) : null;
    final driver = f.length > 1 ? int.tryParse(f[1].split('.').first) : null;
    if (cc == null || driver == null || cc < 7.5 || driver < 580) return true;
  }
  return false;
}

