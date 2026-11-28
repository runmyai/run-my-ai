// The engine's own numbers: the live counters it serves at GET /moe-stream/stats, and the figures it puts in the
// final response of a request (`timings.moe_stream`). The stats document has the counters since the model was loaded
// under `total`, those of the request going on under `request`, and the engine's layout under `layout`; each of those
// figures has a `prompt` and a `reply` part, per-layer numbers and, with --moe-stream-timing, `time_per_word`. They are
// read leniently: a counter may be at the top of the document or in its `reply` part, under any of the names listed
// here, and a counter the engine does not give leaves its series out of the graphs.

/// The number at the first of [names] that [json] has; a name with dots looks inside nested maps.
double? pickNumber(Map<String, Object?> json, List<String> names) {
  for (final name in names) {
    Object? at = json;
    for (final part in name.split('.')) {
      at = at is Map ? at[part] : null;
    }
    if (at is num && at.isFinite) return at.toDouble();
  }
  return null;
}

const _tokens = ['reply.tokens', 'tokens', 'n_tokens', 'decode.tokens'];
const _stall = ['reply.stall_ms', 'stall_ms', 't_stall_ms', 'decode.stall_ms'];
const _hits = ['reply.hits', 'hits', 'n_hit', 'decode.hits'];
const _misses = ['reply.misses', 'misses', 'n_miss', 'decode.misses'];
const _vramHits = ['reply.vram_hits', 'vram_hits', 'n_vram_hit', 'decode.vram_hits'];
const _reads = ['reply.reads', 'reads', 'n_reads', 'decode.reads'];
const _swaps = ['vram.follow_swaps', 'vram_swaps', 'swaps', 'vram.swaps'];

/// The five things that can happen to a guess of an expert needed soon (names as the engine may give them).
const guessKinds = <(String, String, List<String>)>[
  ('gInTime', 'In time', ['reply.guesses.in_time', 'guesses.in_time', 'guess.in_time', 'guesses_in_time']),
  ('gLate', 'Late', ['reply.guesses.late', 'guesses.late', 'guess.late', 'guesses_late']),
  ('gMissed', 'Missed', ['reply.guesses.missed', 'guesses.missed', 'guess.missed', 'guesses_missed']),
  ('gWasted', 'Wasted', ['reply.guesses.wasted', 'guesses.wasted', 'guess.wasted', 'guesses_wasted']),
  ('gCancelled', 'Cancelled', ['reply.guesses.cancelled', 'guesses.cancelled', 'guess.cancelled', 'guesses_cancelled']),
  ('gIssued', 'Issued', ['reply.guesses.issued', 'guesses.issued', 'guess.issued', 'guesses_issued']),
];

/// The parts a token's time is cut into, as the engine times them (milliseconds per token): they add up to the token's
/// time; the graphics card's kernels run beside the CPU's work and are not part of that sum. The hand-off between the
/// CPU and the GPU is mostly the CPU waiting for the GPU to finish; where the engine also gives the copies' own time
/// it is split into the copies and the waiting.
const _timeParts = <(String, List<String>)>[
  ('SSD wait', ['time_per_word.ssd_wait_ms', 'reply.stall_ms_per_token', 'stall_ms_per_token']),
  ('CPU', ['time_per_word.cpu_ms', 'reply.cpu_ms_per_token', 'cpu_ms_per_token']),
  ('CPU-GPU sync', ['time_per_word.handoff_ms', 'reply.handoff_ms_per_token', 'handoff_ms_per_token']),
  ('Other', ['time_per_word.rest_ms']),
  ('GPU', ['time_per_word.gpu_ms', 'reply.gpu_ms_per_token', 'gpu_ms_per_token']),
];

const _handoffCopies = ['time_per_word.handoff_copies_ms', 'reply.handoff_copies_ms_per_token', 'handoff_copies_ms_per_token'];

/// Splits the 'CPU-GPU sync' part into 'CPU→GPU copies' and the rest, when [copies] is known; older runs and
/// engines without the copies' own time keep the one part.
Map<String, double> _splitHandoff(Map<String, double> parts, double? copies) {
  final waiting = parts['CPU-GPU sync'];
  if (waiting == null || copies == null || copies < 0 || copies > waiting) return parts;
  final out = <String, double>{};
  for (final e in parts.entries) {
    if (e.key == 'CPU-GPU sync') out['CPU→GPU copies'] = copies;
    out[e.key] = e.value;
  }
  out['CPU-GPU sync'] = waiting - copies;
  return out;
}

/// The part of the token's time that runs beside the others (not added to the token).
const timeBesideParts = {'GPU'};

/// Whether [parts] split the token's time at all: the SSD wait alone is no split (an engine started without
/// --moe-stream-timing gives only that).
bool hasTimeSplit(Map<String, double> parts) => parts.keys.any((k) => k != 'SSD wait' && !timeBesideParts.contains(k));

/// One reading of the engine's counters (they count from when the model was loaded) and gauges.
class EngineSnapshot {
  const EngineSnapshot({required this.counters, required this.gauges, this.layers = const [], this.layout = const {}});

  final Map<String, double> counters;
  final Map<String, double> gauges;

  /// Each streamed layer's own counters (`hits`, `misses`, `stall_ms`), when the engine gives them.
  final List<Map<String, double>> layers;

  /// The engine's layout document (`layout` of the stats), as it came.
  final Map<String, Object?> layout;

  /// Null when [json] is not a document of counters.
  static EngineSnapshot? parse(Object? json) {
    if (json is! Map) return null;
    final doc = json.cast<String, Object?>();
    // (Counters since the model was loaded are the ones that only grow; the request's own start over each time.)
    final total = doc['total'] is Map ? (doc['total']! as Map).cast<String, Object?>() : doc;
    final layout = doc['layout'] is Map ? (doc['layout']! as Map).cast<String, Object?>() : const <String, Object?>{};
    final counters = <String, double>{};
    void count(String id, List<String> names) {
      final v = pickNumber(total, names);
      if (v != null) counters[id] = v;
    }

    count('tokens', _tokens);
    count('stall', _stall);
    count('hits', _hits);
    count('misses', _misses);
    count('vramHits', _vramHits);
    count('reads', _reads);
    count('swaps', _swaps);
    count('cpuMs', ['time_per_word.total_ms.cpu', 'time.cpu_ms', 'cpu_ms', 'reply.cpu_ms']);
    count('gpuMs', ['time_per_word.total_ms.gpu', 'time.gpu_ms', 'gpu_ms', 'reply.gpu_ms']);
    count('handoffMs', ['time_per_word.total_ms.handoff', 'time.handoff_ms', 'handoff_ms', 'reply.handoff_ms']);
    count('handoffCopiesMs', [
      'time_per_word.total_ms.handoff_copies',
      'time.handoff_copies_ms',
      'handoff_copies_ms',
      'reply.handoff_copies_ms',
    ]);
    for (final (id, _, names) in guessKinds) {
      count(id, names);
    }
    // The engine gives the uses and the shares; the counts are worked out from them.
    final uses = pickNumber(total, ['reply.expert_uses']);
    if (uses != null) {
      final ram = pickNumber(total, ['reply.ram_hit_percent']);
      final vram = pickNumber(total, ['reply.vram_hit_percent']);
      if (!counters.containsKey('hits') && ram != null) counters['hits'] = uses * ram / 100;
      if (!counters.containsKey('vramHits') && vram != null) counters['vramHits'] = uses * vram / 100;
    }
    // (A read from the SSD is a miss.)
    if (!counters.containsKey('reads') && counters.containsKey('misses')) counters['reads'] = counters['misses']!;

    final gauges = <String, double>{};
    void gauge(String id, List<String> names) {
      final v = pickNumber(doc, names) ?? pickNumber(layout, names);
      if (v != null) gauges[id] = v;
    }

    gauge('slots', ['slots', 'ram_slots']);
    gauge('layers', ['layout.streamed_layers', 'layers', 'streamed_layers']);
    gauge('vramPerLayer', ['vram_experts_per_layer', 'vram_per_layer']);
    gauge('gpuLayers', ['gpu_layers', 'whole_gpu_layers']);
    gauge('ramExperts', ['layout.ram_slots_total', 'ram_experts', 'ram_experts_filled']);
    gauge('vramExperts', ['layout.vram_experts_total', 'vram_experts', 'vram_experts_filled']);
    if (counters.isEmpty && gauges.isEmpty) return null;

    final raw = total['per_layer'] ?? total['layers_detail'] ?? (total['layers'] is List ? total['layers'] : null);
    final layers = <Map<String, double>>[
      if (raw is List)
        for (final layer in raw)
          if (layer is Map) _layerCounters(layer.cast<String, Object?>()),
    ];
    return EngineSnapshot(counters: counters, gauges: gauges, layers: layers, layout: layout);
  }

  /// The experts the engine keeps in RAM (the pools' size, unless it says how many are filled), and in VRAM.
  double? get ramExperts => gauges['ramExperts'] ?? _product('slots', 'layers');
  double? get ramCapacity => gauges['ramExperts'] ?? _product('slots', 'layers');
  double? get vramExperts => gauges['vramExperts'] ?? _product('vramPerLayer', 'layers');

  double? _product(String a, String b) => gauges[a] == null || gauges[b] == null ? null : gauges[a]! * gauges[b]!;
}

/// One layer's numbers: its `reply` part when it has one (the tokens only), else its own top level.
Map<String, double> _layerCounters(Map<String, Object?> layer) {
  final reply = layer['reply'] is Map ? (layer['reply']! as Map).cast<String, Object?>() : null;
  final out = <String, double>{};
  for (final e in layer.entries) {
    if (e.value is num && (e.value as num).isFinite) out[e.key] = (e.value as num).toDouble();
  }
  if (reply != null) {
    for (final e in reply.entries) {
      if (e.value is num && (e.value as num).isFinite) out[e.key] = (e.value as num).toDouble();
    }
  }
  return out;
}

/// Turns the engine's running counters into values per token and shares, from one reading to the next.
class EngineStatsTracker {
  EngineSnapshot? _before;

  /// The series values for this reading; empty ones (no tokens written since the reading before) are left out.
  Map<String, double?> add(EngineSnapshot now) {
    final before = _before;
    _before = now;
    final out = <String, double?>{};
    final ram = now.ramExperts;
    if (ram != null) out['eng.expRam'] = ram;
    if (now.ramCapacity != null) out['eng.expRamMax'] = now.ramCapacity;
    if (now.vramExperts != null) out['eng.expVram'] = now.vramExperts;
    if (before == null) return out;
    double delta(String id) => (now.counters[id] ?? 0) - (before.counters[id] ?? 0);
    final tokens = delta('tokens');
    if (tokens > 0) {
      if (now.counters.containsKey('stall')) out['eng.stall'] = delta('stall') / tokens;
      if (now.counters.containsKey('reads')) out['eng.reads'] = delta('reads') / tokens;
      if (now.counters.containsKey('swaps')) out['eng.swaps'] = delta('swaps') / tokens;
    }
    final streamed = delta('hits') + delta('misses');
    if (streamed > 0) out['eng.ramHit'] = 100 * delta('hits') / streamed;
    final all = streamed + delta('vramHits');
    if (now.counters.containsKey('vramHits') && all > 0) out['eng.vramHit'] = 100 * delta('vramHits') / all;
    var guesses = 0.0;
    for (final (id, _, _) in guessKinds) {
      guesses += delta(id);
    }
    if (guesses > 0) {
      for (final (id, _, _) in guessKinds) {
        if (now.counters.containsKey(id)) out['eng.$id'] = 100 * delta(id) / guesses;
      }
    }
    return out;
  }
}

/// How the time of a token divides between the parts the engine measures, in milliseconds per token (`SSD wait`, `CPU`,
/// the hand-off to the GPU, `Other`, and the `GPU`'s kernels beside them), from the final response's `timings.moe_stream`;
/// empty when it gives none.
Map<String, double> timeParts(Map<String, Object?> moeStream) {
  final parts = <String, double>{for (final (label, names) in _timeParts) label: ?pickNumber(moeStream, names)};
  final waiting = parts['CPU-GPU sync'];
  return _splitHandoff(parts, waiting == null ? null : pickNumber(moeStream, _handoffCopies));
}

/// The same split worked out from two readings of the counters (one at the first token, one at the last), for an engine
/// that gives its times as running counters; empty when they have none.
Map<String, double> timePartsBetween(EngineSnapshot start, EngineSnapshot end) {
  final tokens = (end.counters['tokens'] ?? 0) - (start.counters['tokens'] ?? 0);
  if (tokens <= 0) return const {};
  double? part(String id) =>
      end.counters.containsKey(id) ? ((end.counters[id] ?? 0) - (start.counters[id] ?? 0)) / tokens : null;
  final parts = {
    for (final (label, id) in const [('SSD wait', 'stall'), ('CPU', 'cpuMs'), ('GPU', 'gpuMs'), ('CPU-GPU sync', 'handoffMs')])
      label: ?part(id),
  };
  return _splitHandoff(parts, part('handoffCopiesMs'));
}

/// What is counted per layer (the rest of a layer's entry, such as its place, is a fact and stays as it is).
const _countedPerLayer = {'hits', 'misses', 'vram_hits', 'stall_ms'};

/// Each layer's numbers over the reply: the counters at the end less those at the first token, with the share of
/// expert uses found in RAM. Empty when the engine does not give them per layer.
List<Map<String, double>> layersBetween(EngineSnapshot start, EngineSnapshot end) {
  if (end.layers.isEmpty) return const [];
  return [
    for (var i = 0; i < end.layers.length; i++)
      _withHitRate({
        for (final e in end.layers[i].entries)
          e.key: _countedPerLayer.contains(e.key) ? e.value - (i < start.layers.length ? start.layers[i][e.key] ?? 0 : 0) : e.value,
      }),
  ];
}

/// The layers of a request's own figures (`per_layer` of `timings.moe_stream`: counters since the request began);
/// empty when it has none.
List<Map<String, double>> layersOf(Map<String, Object?> moeStream) {
  final raw = moeStream['per_layer'];
  if (raw is! List) return const [];
  return [for (final l in raw) if (l is Map) _withHitRate(_layerCounters(l.cast<String, Object?>()))];
}

Map<String, double> _withHitRate(Map<String, double> layer) {
  final hits = layer['hits'], misses = layer['misses'];
  if (hits != null && misses != null && hits + misses > 0 && !layer.containsKey('hit_rate_percent')) {
    layer['hit_rate_percent'] = 100 * hits / (hits + misses);
  }
  return layer;
}
