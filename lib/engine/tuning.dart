import 'dart:convert';
import 'dart:math';

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

/// The table's command with the measured settings put in: -t (replies), -tb (prompts), the fast cores, the SSD readers.
List<String> withTuning(List<String> args, Map<String, dynamic>? t) {
  if (t == null) return args;
  final out = [...args];
  final threads = t['threads'] as int;
  // the autotuner names the fast cores only when it measured them clearly faster than all cores, at this thread count: one
  // thread per fast core as a mask, and as a range too when they are numbered in one run from 0
  final mask = t['fast_mask'] as String? ?? '', fast = t['fast_cpus'] as String? ?? '';
  if (mask.isNotEmpty) {
    out.addAll(['--cpu-mask', mask]);
  } else if (fast.isNotEmpty) {
    out.addAll(['--cpu-range', fast]);
  }
  // prompts are compute-bound and take every core: without this their threads would be kept on the fast cores too
  if (t['logical_cores'] case final int n when n > 1 && (mask.isNotEmpty || fast.isNotEmpty)) {
    out.addAll(['--cpu-range-batch', '0-${n - 1}']);
  }
  final i = out.indexOf('-t');
  if (i >= 0 && i + 1 < out.length) out[i + 1] = '$threads';
  if (t['threads_batch'] case final int tb when tb > threads) out.addAll(['-tb', '$tb']);
  if (t['io_threads'] case final int io) out.addAll(['--moe-stream-io-threads', '$io']);
  return out;
}

/// Several cards share the model, filled fastest first (the autotuner's measured read speed): the faster cards each run a
/// run of the last layers completely, as whole layers - as many as their memory holds - and the slowest card runs the first
/// layers with the expert pool, RAM and SSD behind it. One hand-over between cards per run of layers. Measured with two RTX 3060:
/// Flint 72.8 tok/s against 53.2 on one card, Qwen 25.2 against 19.2, long prompts faster too.
/// Each faster card also keeps [headroomGiB] free for the desktop and other apps (the slowest card's is the engine's own flag).
/// shortcut: whole layers per card as (memory - 2.5 GiB - headroom) / one layer's experts - the engine streams the ones that do not fit
List<String> cardFlags(List<({String name, int mib})> cards, int layers, int firstMoe, double layerGiB, {double headroomGiB = 0}) {
  final pool = cards.last, fast = cards.sublist(0, cards.length - 1);
  var left = layers - firstMoe - 2;   // at least the dense layers and two MoE layers stay with the pool
  final counts = <int>[];
  for (final c in fast) {
    final n = min(left, max(1, ((c.mib / 1024 - 2.5 - headroomGiB) / layerGiB).floor()));
    counts.add(n);
    left -= n;
  }
  final nPool = layers - counts.fold(0, (a, n) => a + n);
  final args = [
    '--device', [pool.name, for (final c in fast) c.name].join(','),
    '-ts', [nPool, ...counts].join(','),
    '--moe-stream-vram-device', pool.name,
  ];
  var first = nPool;
  for (var i = 0; i < fast.length; i++) {
    if (counts[i] > 0) args.addAll(['--moe-stream-gpu-layers-device', '${fast[i].name}=$first-${first + counts[i] - 1}']);
    first += counts[i];
  }
  return args;
}

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

