import 'dart:math';

/// The table's command with the measured settings put in: -t, the fast cores, the SSD readers.
List<String> withTuning(List<String> args, Map<String, dynamic>? t) {
  if (t == null) return args;
  final out = [...args];
  var threads = t['threads'] as int;
  final fast = t['fast_cpus'] as String? ?? '';
  if (fast.isNotEmpty) {
    // shortcut: a CPU with fast and slow cores keeps the threads on its fast cores, named as one run 0-N, two per core
    threads = min(threads, (int.parse(fast.split('-').last) + 1) ~/ 2);
    out.addAll(['--cpu-range', fast, '--cpu-strict', '1']);
  }
  final i = out.indexOf('-t');
  if (i >= 0 && i + 1 < out.length) out[i + 1] = '$threads';
  if (t['io_threads'] case final int io) out.addAll(['--moe-stream-io-threads', '$io']);
  return out;
}
