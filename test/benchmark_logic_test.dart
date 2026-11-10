// The logic behind the Benchmark tab, with no window and no engine: the series of readings, percentiles, the rules that
// mark a run as disturbed, the engine's counters, the memory layout, comparing runs, the long prompts, and the history
// in the database.
// Run: flutter test test/benchmark_logic_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/benchmark/benchmark.dart';
import 'package:runmyai/benchmark/compare.dart';
import 'package:runmyai/benchmark/disturbance.dart';
import 'package:runmyai/benchmark/engine_stats.dart';
import 'package:runmyai/benchmark/memory_layout.dart';
import 'package:runmyai/benchmark/metrics.dart';
import 'package:runmyai/benchmark/prompts.dart';
import 'package:runmyai/benchmark/series.dart';
import 'package:runmyai/benchmark/summary.dart';
import 'package:runmyai/data/chat_db.dart';
import 'package:sqlite3/sqlite3.dart';

BenchmarkResult _run({
  double speed = 40,
  int loadMillis = 1000,
  String flags = '-c 4096 --temp 0',
  List<double> words = const [10, 20, 30],
  RunSeries? series,
  Map<String, Object?> stats = const {},
}) => BenchmarkResult(
  at: DateTime(2026, 1, 2, 3, 4),
  modelName: 'M',
  contextLength: 4096,
  profileName: 'Auto',
  flags: flags,
  memoryCapGiB: null,
  promptLabel: 'Story chat',
  replyLength: 10,
  warmups: const ['w'],
  loadMillis: loadMillis,
  firstWordMillis: 2000,
  promptTokens: 100,
  promptMillis: 50,
  replyTokens: 50,
  replyMillis: 50 * 1000 / speed,
  wordGaps: const [],
  wordMillis: words,
  engineStats: stats,
  log: const ['l'],
  disturbed: const [],
  series: series,
);

/// A series of [n] ticks half a second apart, with the series [make] gives for each tick.
RunSeries _ticks(int n, Map<String, double?> Function(int i) make) {
  final s = RunSeries();
  for (var i = 0; i < n; i++) {
    s.add(i * 0.5, make(i));
  }
  return s;
}

void main() {
  group('the series of readings', () {
    test('a series that starts late has gaps before it, and one that stops has gaps after', () {
      final s = RunSeries()
        ..add(0, {'a': 1})
        ..add(0.5, {'a': 2, 'b': 10})
        ..add(1, {'b': 11});
      expect(s.series('a'), [1, 2, null]);
      expect(s.series('b'), [null, 10, 11]);
      expect((s.length, s.end), (3, 1.0));
      expect(s.at('b', 2), 11);
      expect(s.at('zzz', 0), isNull);
    });

    test('the tick nearest to a moment', () {
      final s = _ticks(5, (i) => {'a': i.toDouble()});
      expect([s.indexAt(-3), s.indexAt(0.6), s.indexAt(0.8), s.indexAt(1.1), s.indexAt(99)], [0, 1, 2, 2, 4]);
      expect(RunSeries().indexAt(1), -1);
    });

    test('phases cover the run, the one before ending where the next begins', () {
      final s = RunSeries()
        ..beginPhase(PhaseBand.load, 0)
        ..beginPhase(PhaseBand.prompt, 4)
        ..beginPhase(PhaseBand.reply, 6)
        ..endPhases(10);
      expect(s.phases.map((p) => (p.name, p.start, p.end)), [('Load', 0.0, 4.0), ('Prompt', 4.0, 6.0), ('Reply', 6.0, 10.0)]);
      expect(s.phaseAt(5)!.name, 'Prompt');
      expect(s.phaseAt(-1), isNull);
    });

    test('averages and peaks over a stretch, ignoring gaps', () {
      final s = _ticks(4, (i) => {'a': i == 1 ? null : i.toDouble()});
      expect(s.average('a'), closeTo(5 / 3, 1e-9));
      expect(s.peak('a'), 3);
      expect(s.peak('a', from: 0, to: 1.0), 2);
      expect(s.average('none'), isNull);
    });

    test('shrinking merges neighbours: values averaged, flag bits kept', () {
      final s = _ticks(8, (i) => {'x': i.toDouble(), 'gpu.0.reasons': i == 3 ? 4 : 0});
      final small = s.shrunk(4);
      expect(small.length, 4);
      expect(small.series('x'), [0.5, 2.5, 4.5, 6.5]);
      expect(small.series('gpu.0.reasons'), [0, 4, 0, 0]);
      expect(identical(s.shrunk(100).series('x'), s.series('x')), isFalse, reason: 'a copy');
      expect(s.shrunk(100).length, 8);
    });

    test('it comes back whole from JSON, a constant series as one number', () {
      final s = _ticks(5, (i) => {'limit': 140, 'v': i * 1.234, 'gap': i == 2 ? null : 1.5})
        ..beginPhase(PhaseBand.load, 0)
        ..endPhases(2);
      final json = s.toJson();
      expect((json['s']! as Map)['limit'], 140);
      final again = RunSeries.fromJson((jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>());
      expect(again.times, s.times);
      expect(again.series('limit'), List.filled(5, 140.0));
      expect(again.series('v')![3], 3.7);
      expect(again.series('gap'), [1.5, 1.5, null, 1.5, 1.5]);
      expect(again.phases.single.name, 'Load');
    });
  });

  group('the numbers of a run', () {
    test('percentiles of the words', () {
      final words = [for (var i = 1; i <= 100; i++) i.toDouble()];
      expect(percentile(words, 0.5), 51);
      expect(percentile(words, 0.99), 99);
      expect(percentile([], 0.5), 0);
      final stats = WordStats.of(words);
      expect((stats.p90, stats.max, stats.mean), (90, 100, 50.5));
    });

    test('the spread counts every word, the slow ones in the last step', () {
      expect(histogram([1, 2, 3, 9, 50], 10, 5), [1, 2, 0, 0, 2]);
      expect(histogram([1], 0, 3), [0, 0, 0]);
    });

    test('a result is kept whole, and a result saved before these numbers existed still opens', () {
      final result = _run(stats: {'reply': {'stall_ms_per_token': 2.5, 'hit_rate_percent': 97.0}}, series: _ticks(3, (i) => {'a': 1}));
      final again = BenchmarkResult.fromJson(jsonDecode(jsonEncode(result.toJson())) as Map<String, Object?>);
      expect((again.tokensPerSecond, again.promptTokensPerSecond, again.millisPerWord), (40.0, 2000.0, 25.0));
      expect((again.slowestWord, again.ssdWaitPerWord, again.hitRate, again.flags), (30.0, 2.5, 97.0, '-c 4096 --temp 0'));
      expect(again.series!.length, 3);

      final old = {
        'at': 1,
        'modelName': 'M',
        'contextLength': 4096,
        'profileName': 'Auto',
        'flags': '-c 4096',
        'memoryCapGiB': null,
        'promptLabel': 'Story chat',
        'replyLength': 10,
        'warmups': ['w'],
        'loadMillis': 1,
        'firstWordMillis': 2,
        'promptTokens': 100,
        'promptMillis': 50,
        'replyTokens': 50,
        'replyMillis': 1000,
        'wordGaps': [10, 20, 30],
        'engineStats': {'decode': {'stall_ms_per_token': 3.0}},
        'log': ['l'],
        'disturbed': ['The laptop was on battery.'],
      };
      final opened = BenchmarkResult.fromJson(old);
      expect((opened.slowestWord, opened.ssdWaitPerWord), (30.0, 3.0));
      expect(opened.series, isNull);
      expect(opened.wordMillis, isEmpty);
      expect(opened.words, [10, 20, 30], reason: 'the gaps stand in for the engine\'s own times');
    });

    test('a word has its place on the time axis', () {
      final s = RunSeries()
        ..beginPhase(PhaseBand.load, 0)
        ..beginPhase(PhaseBand.reply, 10)
        ..endPhases(11);
      final r = _run(words: [500, 250, 250], series: s);
      expect(replyStartSeconds(r), 10);
      expect([wordTimeSeconds(r, 0), wordTimeSeconds(r, 1), wordTimeSeconds(r, 2)], [10.5, 10.75, 11.0]);
      expect(wordTimeSeconds(r, 3), isNull);
      expect([wordAtSeconds(r, 10.6), wordAtSeconds(r, 11), wordAtSeconds(r, 20), wordAtSeconds(r, 9)], [1, 2, 2, null]);
      expect(wordTimeSeconds(_run(), 0), isNull, reason: 'no graphs, no place');
    });

    test('numbers are written with spaces between thousands', () {
      expect(formatNumber(1234567.8, 1), '1 234 567.8');
      expect(formatNumber(999, 0), '999');
      expect(formatNumber(12345, 0), '12 345');
      expect(formatNumber(-5.26, 1), '-5.3');
      expect(formatBytes(70147512048), '70.1 GB');
      expect(stopReasonText('length'), contains('longest'));
    });
  });

  group('lines of the live view', () {
    test('a value is written with its limit', () {
      final s = _ticks(2, (i) => {'gpu.0.power': 112, 'gpu.0.powerLimit': 140, 'gpu.0.load': 74});
      final rows = metricRows(s);
      final gpu = rows.firstWhere((r) => r.id == 'gpu.0');
      expect(gpu.lines[1].text(s, 0), '112 of 140 W');
      expect(gpu.lines[0].text(s, 0), '74 of 100 %');
      expect(gpu.summary(s, 1), '74 of 100 %  ·  112 of 140 W');
      expect(rows.map((r) => r.id), containsAll(['speed', 'gpu.0', 'cpu', 'ram', 'ssd', 'engine']));
    });

    test('a line without a limit is measured against its own highest value', () {
      final s = _ticks(3, (i) => {'ssd.iops': [100.0, 400.0, 200.0][i]});
      final line = metricRows(s).firstWhere((r) => r.id == 'ssd').lines.firstWhere((l) => l.id == 'ssd.iops');
      expect(line.scale(s), 400);
      expect(line.limitAt(s, 0), isNull);
    });

    test('the limit that moved is the one at that moment', () {
      final s = _ticks(3, (i) => {'gpu.0.power': 40, 'gpu.0.powerLimit': i == 0 ? 140 : 46});
      final power = metricRows(s).firstWhere((r) => r.id == 'gpu.0').lines[1];
      expect([power.limitAt(s, 0), power.limitAt(s, 2)], [140, 46]);
    });

    test('a card with no reading has a row that says so; the engine row says so without numbers', () {
      final s = _ticks(2, (i) => {'cpu.load': 5});
      final rows = metricRows(s);
      expect(rows.where((r) => r.id.startsWith('gpu')).single.hasData(s), isFalse);
      expect(rows.firstWhere((r) => r.id == 'engine').note, contains('Not available'));
      expect(rows.firstWhere((r) => r.id == 'cpu').hasData(s), isTrue);
    });
  });

  group('why a run is marked disturbed', () {
    List<String> check(RunSeries s, {StartState? before}) => disturbances(s, before: before);

    test('a calm run has no reasons', () {
      final s = _ticks(20, (i) => {
        'sys.battery': 0,
        'cpu.other': 2,
        'gpu.0.load': 90,
        'gpu.0.power': 120,
        'gpu.0.powerLimit': 140,
        'gpu.0.powerMax': 140,
        'gpu.0.clock': 2400,
        'gpu.0.clockMax': 2500,
        'gpu.0.reasons': 0,
      });
      expect(check(s, before: const StartState(cpuPercent: 3, gpuPercent: 1)), isEmpty);
    });

    test('on battery, at any moment or at the start', () {
      final s = _ticks(6, (i) => {'sys.battery': i == 4 ? 1 : 0});
      expect(check(s).single, contains('battery'));
      expect(check(_ticks(2, (i) => {'sys.battery': 0}), before: const StartState(onBattery: true)).single, contains('battery'));
    });

    test('other programs busy at the start', () {
      final s = _ticks(3, (i) => {'cpu.other': 1});
      expect(check(s, before: const StartState(cpuPercent: 60)).single, contains('busy'));
      expect(check(s, before: const StartState(gpuPercent: 45)).single, contains('busy'));
    });

    test('other programs using the CPU on average, or in a long burst', () {
      expect(check(_ticks(20, (i) => {'cpu.other': 20})).single, contains('Other programs used the CPU (20 %'));
      expect(check(_ticks(20, (i) => {'cpu.other': 4})), isEmpty);
      final burst = _ticks(60, (i) => {'cpu.other': i >= 20 && i < 34 ? 31 : 1});
      expect(check(burst).single, contains('up to 31 %'));
      final brief = _ticks(60, (i) => {'cpu.other': i >= 20 && i < 28 ? 45 : 1});
      expect(check(brief), isEmpty, reason: '4 seconds is not a burst');
    });

    test('a card whose clock stays far under its highest, while it is working', () {
      final held = _ticks(10, (i) => {'gpu.0.load': 90, 'gpu.0.clock': 900, 'gpu.0.clockMax': 2500});
      expect(check(held).single, allOf(contains('held down'), contains('900 of 2500 MHz')));
      final idle = _ticks(10, (i) => {'gpu.0.load': 5, 'gpu.0.clock': 300, 'gpu.0.clockMax': 2500});
      expect(check(idle), isEmpty, reason: 'an idle card is allowed to rest');
      final short = _ticks(3, (i) => {'gpu.0.load': 90, 'gpu.0.clock': 900, 'gpu.0.clockMax': 2500});
      expect(check(short), isEmpty, reason: 'too few busy moments to judge');
    });

    test('a card drawing far less than its limit while the driver slows it', () {
      final capped = _ticks(10, (i) => {
        'gpu.0.load': 80,
        'gpu.0.power': 46,
        'gpu.0.powerLimit': 140,
        'gpu.0.reasons': 4,
        'gpu.0.clock': 2400,
        'gpu.0.clockMax': 2500,
      });
      expect(check(capped).single, contains('far less than its power limit'));
      final lowDrawNoReason = _ticks(10, (i) => {
        'gpu.0.load': 80,
        'gpu.0.power': 46,
        'gpu.0.powerLimit': 140,
        'gpu.0.reasons': 0,
        'gpu.0.clock': 2400,
        'gpu.0.clockMax': 2500,
      });
      expect(check(lowDrawNoReason), isEmpty, reason: 'drawing little is fine when nothing slows it');
    });

    test('a power limit set far below what the card can be given', () {
      final s = _ticks(10, (i) => {
        'gpu.0.load': 80,
        'gpu.0.power': 45,
        'gpu.0.powerLimit': 46,
        'gpu.0.powerMax': 140,
        'gpu.0.clock': 2400,
        'gpu.0.clockMax': 2500,
      });
      expect(check(s).single, allOf(contains('held down'), contains('46 W'), contains('140 W')));
    });

    test('each card is judged alone, and named when there are several', () {
      final s = _ticks(10, (i) => {
        'gpu.0.load': 90,
        'gpu.0.clock': 2400,
        'gpu.0.clockMax': 2500,
        'gpu.1.load': 90,
        'gpu.1.clock': 500,
        'gpu.1.clockMax': 2500,
      });
      expect(check(s).single, startsWith('GPU 2'));
    });

    test('the moments a card was slowed, for the summary', () {
      final s = _ticks(10, (i) => {'gpu.0.reasons': i >= 2 && i <= 4 ? 4 : (i == 8 ? 0x40 : 0)});
      final moments = slowdownMoments(s);
      expect([for (final m in moments) [m.from, m.to, ...m.reasons]], [
        [1.0, 2.5, 'software power cap'],
        [4.0, 4.5, 'hardware thermal slowdown'],
      ]);
    });
  });

  group('the engine\'s counters', () {
    test('they are found at the top or in the reply part, under their several names', () {
      final flat = EngineSnapshot.parse({'tokens': 10, 'stall_ms': 50, 'hits': 90, 'misses': 10, 'slots': 191, 'layers': 41})!;
      expect(flat.counters, {'tokens': 10, 'stall': 50, 'hits': 90, 'misses': 10, 'reads': 10}, reason: 'a read from the SSD is a miss');
      expect((flat.ramCapacity, flat.ramExperts), (191 * 41, 191 * 41));
      final nested = EngineSnapshot.parse({
        'reply': {'tokens': 4, 'stall_ms': 8},
        'guesses': {'in_time': 7, 'late': 1},
        'vram_experts_per_layer': 62,
        'layers': 41,
      })!;
      expect(nested.counters['tokens'], 4);
      expect(nested.counters['gInTime'], 7);
      expect(nested.vramExperts, 62 * 41);
      expect(EngineSnapshot.parse({'nothing': 'here'}), isNull);
      expect(EngineSnapshot.parse('text'), isNull);
    });

    test('per word and per share, from one reading to the next', () {
      final tracker = EngineStatsTracker();
      final first = tracker.add(EngineSnapshot.parse({
        'tokens': 100, 'stall_ms': 100, 'hits': 900, 'misses': 100, 'vram_hits': 0, 'reads': 100,
        'guesses': {'in_time': 0, 'late': 0, 'missed': 0, 'wasted': 0, 'cancelled': 0},
        'slots': 10, 'layers': 4,
      })!);
      expect(first.keys, containsAll(['eng.expRam', 'eng.expRamMax']), reason: 'the first reading has only the levels');
      expect(first['eng.stall'], isNull);
      final second = tracker.add(EngineSnapshot.parse({
        'tokens': 110, 'stall_ms': 150, 'hits': 1000, 'misses': 110, 'vram_hits': 100, 'reads': 130,
        'guesses': {'in_time': 6, 'late': 2, 'missed': 1, 'wasted': 1, 'cancelled': 0},
        'slots': 10, 'layers': 4,
      })!);
      expect(second['eng.stall'], 5, reason: '50 ms over 10 words');
      expect(second['eng.reads'], 3);
      expect(second['eng.ramHit'], closeTo(100 * 100 / 110, 1e-9));
      expect(second['eng.vramHit'], closeTo(100 * 100 / 210, 1e-9));
      expect(second['eng.gInTime'], 60);
      expect(second['eng.gLate'], 20);
      expect(second['eng.gCancelled'], 0);
    });

    test('the parts of a word, from the response or from two readings', () {
      expect(timeParts({'reply': {'stall_ms_per_token': 5.0, 'cpu_ms_per_token': 12.0, 'gpu_ms_per_token': 8.0}}), {
        'SSD wait': 5.0,
        'CPU': 12.0,
        'GPU': 8.0,
      });
      expect(timeParts({'layers': 40}), isEmpty);
      final a = EngineSnapshot.parse({'tokens': 10, 'stall_ms': 10, 'cpu_ms': 100, 'handoff_ms': 5})!;
      final b = EngineSnapshot.parse({'tokens': 30, 'stall_ms': 50, 'cpu_ms': 300, 'handoff_ms': 25})!;
      expect(timePartsBetween(a, b), {'SSD wait': 2.0, 'CPU': 10.0, 'CPU-GPU sync': 1.0});
      expect(timePartsBetween(a, a), isEmpty);
    });

    test('each layer over the reply: the counters less those at its start', () {
      final a = EngineSnapshot.parse({'tokens': 1, 'per_layer': [{'misses': 5, 'stall_ms': 2}, {'misses': 1}]})!;
      final b = EngineSnapshot.parse({'tokens': 9, 'per_layer': [{'misses': 15, 'stall_ms': 6, 'hit_rate_percent': 90}, {'misses': 4}]})!;
      expect(layersBetween(a, b), [
        {'misses': 10.0, 'stall_ms': 4.0, 'hit_rate_percent': 90.0},
        {'misses': 3.0},
      ]);
      expect(layersBetween(a, EngineSnapshot.parse({'tokens': 2})!), isEmpty);
    });
  });

  group('the stats document of the engine\'s route', () {
    // Shaped as GET /moe-stream/stats answers: the figures since the model was loaded, the request going on, the layout.
    Map<String, Object?> doc({double tokens = 100, double stall = 300, double cpu = 1000, int used = 1000}) => {
      'moe_stream': true,
      'timing': true,
      'request': {'active': true, 'reply': {'tokens': 5}},
      'total': {
        'layers': 41,
        'slots': 191,
        'prompt': {'tokens': 900},
        'reply': {
          'tokens': tokens,
          'misses': 40.0,
          'stall_ms': stall,
          'expert_uses': used,
          'ram_hit_percent': 90.0,
          'vram_hit_percent': 6.0,
          'guesses': {'issued': 50, 'in_time': 30, 'late': 6, 'missed': 40, 'wasted': 4, 'cancelled': 2},
        },
        'vram': {'follow_swaps': 12},
        'per_layer': [
          {'layer': 3, 'hits': 90, 'misses': 10, 'vram_hits': 5, 'stall_ms': 8.0, 'ram_slots': 191, 'vram_experts': 62, 'reply': {'hits': 40, 'misses': 4, 'stall_ms': 3.0}},
          {'layer': 4, 'hits': 80, 'misses': 20, 'vram_hits': 6, 'stall_ms': 9.0, 'ram_slots': 191, 'vram_experts': 62, 'reply': {'hits': 30, 'misses': 14, 'stall_ms': 7.0}},
        ],
        'time_per_word': {
          'words': tokens,
          'ms_per_word': 13.3,
          'ssd_wait_ms': 2.7,
          'cpu_ms': 4.6,
          'gpu_ms': 4.6,
          'handoff_ms': 5.4,
          'rest_ms': 0.6,
          'total_ms': {'all': 1330.0, 'ssd_wait': stall, 'cpu': cpu, 'gpu': 460.0, 'handoff': 540.0, 'rest': 60.0},
        },
      },
      'layout': {
        'layers': 43,
        'streamed_layers': 41,
        'whole_gpu_layers': [40, 41],
        'ram_slots_per_layer': [191, 191],
        'ram_slots_total': 7831,
        'vram_experts_per_layer': [62, 62],
        'vram_experts_total': 2542,
        'kv_cache_mib': 1020.0,
      },
    };

    test('the counters are those since the model was loaded; the uses and shares give the counts', () {
      final s = EngineSnapshot.parse(doc())!;
      expect(s.counters['tokens'], 100);
      expect(s.counters['misses'], 40);
      expect(s.counters['hits'], 900, reason: '90 % of 1000 uses');
      expect(s.counters['vramHits'], 60);
      expect(s.counters['swaps'], 12);
      expect((s.counters['gInTime'], s.counters['gLate'], s.counters['gCancelled']), (30, 6, 2));
      expect(s.counters['cpuMs'], 1000);
      expect((s.ramExperts, s.ramCapacity, s.vramExperts), (7831, 7831, 2542));
      expect(s.layout['kv_cache_mib'], 1020);
    });

    test('per word and per share between two readings', () {
      final tracker = EngineStatsTracker()..add(EngineSnapshot.parse(doc())!);
      final v = tracker.add(EngineSnapshot.parse(doc(tokens: 110, stall: 350, used: 1100))!);
      expect(v['eng.stall'], 5);
      expect(v['eng.expRam'], 7831);
      expect(v['eng.expVram'], 2542);
    });

    test('each layer over the reply, from two readings', () {
      final layers = layersBetween(EngineSnapshot.parse(doc())!, EngineSnapshot.parse(doc(tokens: 130))!);
      expect(layers, hasLength(2));
      expect(layers.first['stall_ms'], 0, reason: 'the same readings: nothing in between');
      expect(layers.first['layer'], 3, reason: 'a place is not counted');
    });

    test('the request\'s own response gives each layer\'s reply, and the parts of a word', () {
      final response = (doc()['total']! as Map).cast<String, Object?>();
      final layers = layersOf(response);
      expect((layers[0]['stall_ms'], layers[0]['misses'], layers[1]['hits']), (3.0, 4.0, 30.0));
      expect(layers[1]['hit_rate_percent'], closeTo(100 * 30 / 44, 1e-9));
      expect(timeParts(response), {'SSD wait': 2.7, 'CPU': 4.6, 'CPU-GPU sync': 5.4, 'Other': 0.6, 'GPU': 4.6});
      expect(timeBesideParts, {'GPU'});
    });

    test('the memory layout is what the engine says of itself', () {
      final m = MemoryLayout.read(const ['llama_kv_cache: size = 5.00 MiB'], '-c 4096', layout: EngineSnapshot.parse(doc())!.layout);
      expect((m.ramSlots, m.streamedLayers, m.vramExpertsPerLayer, m.gpuLayers, m.kvMiB), (191, 41, 62, 2, 1020.0));
    });
  });

  group('the memory layout', () {
    test('from the engine\'s lines and the command', () {
      final m = MemoryLayout.read(
        const [
          'llama_moe_stream: 14.20 GiB of pools = 191 slots per layer x 41 layers',
          'vx_setup: VRAM experts: 62 per layer x 41 streamed layers = 5.3 GiB',
          'llama_kv_cache: size = 1020.00 MiB (65536 cells)',
          'llama_kv_cache: size =   20.00 MiB',
        ],
        '-c 65536 --moe-stream-gpu-layers 4',
        memoryCapGiB: 24,
        freeRamGiB: 22.5,
      );
      expect((m.ramSlots, m.streamedLayers, m.vramExpertsPerLayer, m.gpuLayers, m.kvMiB), (191, 41, 62, 4, 1040));
      expect((m.memoryCapGiB, m.freeRamGiB), (24, 22.5));
      expect(MemoryLayout.fromJson(m.toJson()).ramSlots, 191);
    });

    test('what the engine does not say stays empty; the slots flag stands in for the line', () {
      final none = MemoryLayout.read(const ['nothing useful'], '-c 4096');
      expect(none.isEmpty, isTrue);
      expect(MemoryLayout.read(const [], '-c 1 --moe-stream-slots 150').ramSlots, 150);
    });
  });

  group('comparing runs', () {
    test('flags by name, with their values', () {
      expect(flagMap('A=1 -c 4096 -ctk q8_0 --temp 0 --flag --moe-stream-lookahead=2 --n -1'), {
        'A': '1',
        '-c': '4096',
        '-ctk': 'q8_0',
        '--temp': '0',
        '--flag': '',
        '--moe-stream-lookahead': '2',
        '--n': '-1',
      });
    });

    test('what was added, removed and changed', () {
      final d = diffFlags('-c 8192 --a 1 --new 2', '-c 4096 --a 1 --old 3');
      expect(d.changed, {'-c': '8192'});
      expect(d.added, {'--new': '2'});
      expect(d.removed, {'--old': '3'});
      expect(d.names, {'-c', '--new', '--old'});
      expect(diffFlags('-c 1', '-c 1').isEmpty, isTrue);
    });

    test('each headline number against the other run, better or worse by what the number is', () {
      final deltas = {for (final d in compareRuns(_run(speed: 44, loadMillis: 2000), _run(speed: 40))) d.label: d};
      expect(deltas['Generation speed']!.change, closeTo(4, 1e-9));
      expect(deltas['Generation speed']!.percent, closeTo(10, 1e-9));
      expect(deltas['Generation speed']!.better, isTrue);
      expect(deltas['Load time']!.better, isFalse, reason: 'a longer load is worse');
      expect(deltas['Slowest token']!.better, isNull, reason: 'the same');
      expect(deltas['SSD wait per token']!.change, isNull, reason: 'neither says');
    });
  });

  group('the long prompts', () {
    final corpus = PromptCorpus([
      [for (var i = 0; i < 30; i++) 'Story paragraph $i. ${'alpha ' * 60}'].join('\n\n'),
      [for (var i = 0; i < 30; i++) 'Guide paragraph $i. ${'beta ' * 60}'].join('\n\n'),
      '# Heading\n\n```\ncode that is left out\n```\n\n| table | line |\n\nGuide two paragraph. ${'gamma ' * 60}',
    ]);

    test('passages come in turn from each source, and none comes twice', () {
      final text = corpus.build(3000);
      expect(text.indexOf('Story paragraph 0'), lessThan(text.indexOf('Guide paragraph 0')));
      expect(text.indexOf('Guide paragraph 0'), lessThan(text.indexOf('Story paragraph 1')));
      expect(RegExp('Story paragraph 0').allMatches(text), hasLength(1));
      expect(text, isNot(contains('code that is left out')));
      expect(text, isNot(contains('| table')));
      expect((text.length - 3000).abs(), lessThan(40));
    });

    test('it never makes more than the sources hold', () {
      final all = corpus.build(10000000);
      expect(all.length, lessThanOrEqualTo(corpus.capacity));
      expect(RegExp('Story paragraph 29').allMatches(all), hasLength(1));
    });

    test('a prompt is cut until the engine counts the tokens asked for', () async {
      // (A token for every five characters here.)
      Future<int> count(String text) async => text.length ~/ 5;
      final fitted = await fitPrompt(corpus, 400, count);
      expect((fitted.tokens - 400).abs(), lessThanOrEqualTo(8));
      expect(fitted.text, startsWith(longPromptIntro));
      expect(fitted.tokens, await count(fitted.text));
    });

    test('a corpus too short to reach the size gives the longest it can', () async {
      final fitted = await fitPrompt(corpus, 1000000, (t) async => t.length ~/ 5);
      expect(fitted.tokens, lessThan(1000000));
      expect(fitted.text.length, lessThanOrEqualTo(corpus.capacity + longPromptIntro.length + 4));
    });
  });

  group('the history in the database', () {
    late ChatDb db;
    setUp(() => db = ChatDb.inMemory());
    tearDown(() => db.close());

    test('runs come back with their ids, newest first, and one can be deleted', () {
      final a = db.addBenchmark('{"n":1}');
      final b = db.addBenchmark('{"n":2}');
      expect(db.benchmarks(), [(b, '{"n":2}'), (a, '{"n":1}')]);
      db.deleteBenchmark(a);
      expect(db.benchmarks().map((r) => r.$1), [b]);
    });

    test('only the newest runs are kept', () {
      for (var i = 0; i < 8; i++) {
        db.addBenchmark('{"n":$i}', keep: 5);
      }
      final kept = db.benchmarks();
      expect(kept, hasLength(5));
      expect(kept.first.$2, '{"n":7}');
      expect(kept.last.$2, '{"n":3}');
      expect(ChatDb.maxBenchmarks, 60);
    });

    test('a database from before the graphs opens, and its runs open too', () {
      final dir = Directory.systemTemp.createTempSync('runmyai-bench-db-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/chats.db';
      final first = ChatDb.open(path);
      first.addBenchmark('{"at":1}');
      first.close();
      // Back to the version before the reply stats, as an older app left it.
      final raw = sqlite3.open(path);
      raw.execute('ALTER TABLE messages DROP COLUMN stats');
      raw.execute('PRAGMA user_version = 12');
      raw.close();
      final reopened = ChatDb.open(path);
      addTearDown(reopened.close);
      expect(reopened.benchmarks().single.$2, '{"at":1}');
    });
  });
}
