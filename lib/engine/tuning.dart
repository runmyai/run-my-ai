/// The table's command with the measured settings put in: -t, the fast cores, the SSD readers.
List<String> withTuning(List<String> args, Map<String, dynamic>? t) {
  if (t == null) return args;
  final out = [...args];
  final threads = t['threads'] as int;
  // the autotuner names the fast cores only when it measured them clearly faster than all cores, at this thread count
  final fast = t['fast_cpus'] as String? ?? '';
  if (fast.isNotEmpty) out.addAll(['--cpu-range', fast]);
  final i = out.indexOf('-t');
  if (i >= 0 && i + 1 < out.length) out[i + 1] = '$threads';
  if (t['io_threads'] case final int io) out.addAll(['--moe-stream-io-threads', '$io']);
  return out;
}
