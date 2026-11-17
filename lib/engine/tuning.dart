import 'dart:math';

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

/// Two cards: the first runs the first layers with the expert pool (RAM and SSD behind it), the second runs the last layers
/// completely, as whole layers - one hand-over between the cards per token. The second card's count of whole layers is a sum
/// from its memory; the engine streams the ones that do not fit. Measured on two RTX 3060: Flint 72.8 tok/s against 53.2 on one
/// card, Qwen 25.2 against 19.2, long prompts faster too.
/// shortcut: the two largest cards only, and whole layers as (memory - 2.5 GiB) / one layer's experts; the full autotuner replaces this
List<String> twoCardFlags(List<({String name, int mib})> cards, int layers, int firstMoe, double layerGiB) {
  final pool = cards[0], whole = cards[1];
  final n = min(layers - firstMoe - 2, max(1, ((whole.mib / 1024 - 2.5) / layerGiB).floor()));
  return [
    '--device', '${pool.name},${whole.name}',
    '-ts', '${layers - n},$n',
    '--moe-stream-vram-device', pool.name,
    '--moe-stream-gpu-layers-device', '${whole.name}=${layers - n}-${layers - 1}',
  ];
}

/// The cards from the autotuner's result, largest first. Without a separate card, a built-in GPU that can use 24 GiB or more
/// counts as one (a DGX Spark's GB10, a Strix Halo: Flint 76.7 and 64.8 tok/s on it against 28.2 and 32.1 CPU-only); the small
/// built-in GPUs of ordinary laptops (about half of a smaller RAM) stay unused.
List<({String name, int mib})> cardsFrom(Map<String, dynamic> tune) {
  List<({String name, int mib})> read(String key) =>
      [for (final g in (tune[key] as List?) ?? const []) (name: (g as Map)['name'] as String, mib: g['mib'] as int)]
        ..sort((a, b) => b.mib - a.mib);
  final cards = read('gpus');
  if (cards.isNotEmpty) return cards;
  return read('igpus').where((g) => g.mib >= 24 * 1024).take(1).toList();
}

