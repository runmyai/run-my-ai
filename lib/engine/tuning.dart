import 'dart:convert';

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

/// [args] with the flags the autotuner recommends for this PC and model put in (`recommended_args` of its result [t]:
/// `--moe-stream model`, the thread counts for replies and prompts, the fast cores, the SSD readers, the card of the
/// expert pool or the shared-memory mode). A flag the command names already keeps the command's value. Without a result
/// (the autotuner is missing, failed or was stopped) the command stands as it is: the engine then picks for itself.
List<String> withTuning(List<String> args, Map<String, dynamic>? t) {
  final rec = [for (final a in (t?['recommended_args'] as List?) ?? const []) '$a'];
  final out = [...args];
  for (var i = 0; i < rec.length; i++) {
    // (no recommended value starts with a dash: a model word, counts, a hex mask, a device name)
    final valued = i + 1 < rec.length && !rec[i + 1].startsWith('-');
    if (!out.contains(rec[i])) out.addAll([rec[i], if (valued) rec[i + 1]]);
    if (valued) i++;
  }
  return out;
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

