import 'dart:convert';

/// Extracts the last JSON object line printed by `autotuner`, ignoring any stray driver/backend lines on stdout.
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

/// The table's command with the measured settings put in: decode `-t`, batch `-tb`, fast-core placement, SSD readers,
/// and (on RAM-constrained hosts) a tighter `-ub` prefill chunk when recommended by the autotuner.
List<String> withTuning(List<String> args, Map<String, dynamic>? t) {
  if (t == null) return args;
  final threads = t['threads'];
  if (threads is! int || threads < 1) return args;
  final out = [...args];

  final i = out.indexOf('-t');
  if (i >= 0 && i + 1 < out.length) out[i + 1] = '$threads';

  // Keep prompt prefill (`-tb`) across all compute cores when decode `-t` is lower (decode is DRAM-bandwidth-bound).
  if (t['threads_batch'] case final int tb when tb > threads && !out.contains('-tb') && !out.contains('--threads-batch')) {
    out.addAll(['-tb', '$tb']);
  }

  // Prefer 1-thread-per-physical-P-core hex mask (`fast_mask`, handles HyperThreading & split Arrow Lake P-cores);
  // fall back to contiguous `--cpu-range` (`fast_cpus`) when only a range is provided.
  final mask = t['fast_mask'] as String? ?? '';
  final fast = t['fast_cpus'] as String? ?? '';
  final placedDecode = mask.isNotEmpty || fast.isNotEmpty;
  if (!out.contains('--cpu-mask') && !out.contains('-C') && !out.contains('--cpu-range') && !out.contains('-Cr')) {
    if (mask.isNotEmpty) {
      out.addAll(['--cpu-mask', mask]);
    } else if (fast.isNotEmpty) {
      out.addAll(['--cpu-range', fast]);
    }
  }
  // When decode is pinned to P-cores, allow compute-bound batch prefill to still use all logical CPUs.
  if (placedDecode && !out.contains('--cpu-range-batch') && !out.contains('-Crb') && !out.contains('--cpu-mask-batch')) {
    if (t['logical_cores'] case final int lc when lc > 1) {
      out.addAll(['--cpu-range-batch', '0-${lc - 1}']);
    }
  }

  if (t['io_threads'] case final int io when !out.contains('--moe-stream-io-threads')) {
    out.addAll(['--moe-stream-io-threads', '$io']);
  }

  // Lower `-ub` (and `-b` if smaller than `-ub`) only when the autotuner found host RAM too tight for 2048-token scratch.
  if (t['ubatch'] case final int ub when ub >= 128) {
    final ui = out.indexOf('-ub');
    if (ui >= 0 && ui + 1 < out.length) {
      final curUb = int.tryParse(out[ui + 1]);
      if (curUb != null && ub < curUb) out[ui + 1] = '$ub';
    }
  }

  return out;
}
