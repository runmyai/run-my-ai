import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/engine_backend.dart';
import 'package:runmyai/benchmark/engine_stats.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/commands.dart';
import 'package:runmyai/engine/gguf.dart';
import 'package:runmyai/engine/tuning.dart';
import 'package:runmyai/system/folders.dart';

Uint8List _makeSyntheticGguf({
  required String arch,
  String? name,
  int contextLength = 32768,
  int blockCount = 24,
  int? expertCount,
  int? expertUsedCount,
  int? tensorGgmlType,
}) {
  final out = BytesBuilder();
  void u32(int v) => out.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u64(int v) => out.add((ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());
  void str(String s) {
    final b = utf8.encode(s);
    u64(b.length);
    out.add(b);
  }

  final kvs = <(String, Object)>[
    ('general.architecture', arch),
    if (name != null) ('general.name', name),
    ('$arch.context_length', contextLength),
    ('$arch.block_count', blockCount),
    if (expertCount != null) ('$arch.expert_count', expertCount),
    if (expertUsedCount != null) ('$arch.expert_used_count', expertUsedCount),
  ];

  out.add(utf8.encode('GGUF'));
  u32(3); // GGUF v3
  u64(tensorGgmlType == null ? 0 : 1); // n_tensors
  u64(kvs.length);
  for (final (k, v) in kvs) {
    str(k);
    if (v is String) {
      u32(8);
      str(v);
    } else if (v is int) {
      u32(4);
      u32(v);
    }
  }
  if (tensorGgmlType != null) {
    str('blk.0.ffn_gate_exps.weight');
    u32(3);
    u64(64);
    u64(128);
    u64(expertCount ?? 8);
    u32(tensorGgmlType);
    u64(0);
  }
  return out.toBytes();
}

void main() {
  group('GGUF BYOM inspection & folder discovery', () {
    test('reads MoE, dense, and EXT0 quant-plugin metadata from GGUF headers', () {
      final moeBytes = _makeSyntheticGguf(
        arch: 'qwen35moe',
        name: 'Qwen3.5 MoE Custom',
        contextLength: 65536,
        blockCount: 40,
        expertCount: 256,
        expertUsedCount: 8,
        tensorGgmlType: 41, // GGML_TYPE_EXT0
      );
      final info = readGgufInfoIn(moeBytes)!;
      expect(info.architecture, 'qwen35moe');
      expect(info.name, 'Qwen3.5 MoE Custom');
      expect(info.contextLength, 65536);
      expect(info.blockCount, 40);
      expect(info.expertCount, 256);
      expect(info.expertUsedCount, 8);
      expect(info.isMoE, isTrue);
      expect(info.needsQuantPlugin, isTrue);

      final denseBytes = _makeSyntheticGguf(arch: 'llama', contextLength: 16384);
      final dense = readGgufInfoIn(denseBytes)!;
      expect(dense.isMoE, isFalse);
      expect(dense.needsQuantPlugin, isFalse);
      expect(contextLengthIn(denseBytes), 16384);
    });

    test('discovers standalone and multi-shard BYOM models while skipping secondary/incomplete shards and Store files', () {
      final dir = Directory.systemTemp.createTempSync('runmyai-byom-');
      addTearDown(() => dir.deleteSync(recursive: true));

      final standalone = '${dir.path}/Granite-MoE-Q4_K_M.gguf';
      File(standalone).writeAsBytesSync(
        _makeSyntheticGguf(arch: 'granitemoe', name: 'Granite MoE', contextLength: 32768, expertCount: 32, expertUsedCount: 8),
      );
      File('$standalone.correction').writeAsStringSync('corr');

      // 2-shard complete split GGUF
      File('${dir.path}/DeepMoE-UD-Q4_K_XL-00001-of-00002.gguf').writeAsBytesSync(
        _makeSyntheticGguf(arch: 'deepseek2', name: 'DeepMoE Split', contextLength: 65536, expertCount: 64, expertUsedCount: 6),
      );
      File('${dir.path}/DeepMoE-UD-Q4_K_XL-00002-of-00002.gguf').writeAsBytesSync([1, 2, 3, 4]);

      // Incomplete split GGUF (missing shard 2) -> must be ignored
      File('${dir.path}/Broken-Q4_0-00001-of-00002.gguf').writeAsBytesSync(
        _makeSyntheticGguf(arch: 'qwen3moe', expertCount: 16, expertUsedCount: 4),
      );

      // Known Store filename -> must be ignored
      File('${dir.path}/flint-UD-Q4_K_XL.tokenwing.gguf').writeAsBytesSync(
        _makeSyntheticGguf(arch: 'flint', expertCount: 128, expertUsedCount: 6),
      );

      final models = discoverByomModels([dir.path], knownParts: {'flint-UD-Q4_K_XL.tokenwing.gguf'});
      expect(models.map((m) => m.model.id).toList(), ['byom/DeepMoE-UD-Q4_K_XL', 'byom/Granite-MoE-Q4_K_M']);

      final splitFile = models.first.model.files.single;
      expect(splitFile.quantization, 'UD-Q4_K_XL');
      expect(splitFile.parts, ['DeepMoE-UD-Q4_K_XL-00001-of-00002.gguf', 'DeepMoE-UD-Q4_K_XL-00002-of-00002.gguf']);

      final graniteFile = models.last.model.files.single;
      expect(graniteFile.quantization, 'Q4_K_M');
      expect(graniteFile.parts, ['Granite-MoE-Q4_K_M.gguf', 'Granite-MoE-Q4_K_M.gguf.correction']);
    });

    test('EngineBackend.loadCatalog surfaces BYOM models and generates valid profile commands', () async {
      final dir = Directory.systemTemp.createTempSync('runmyai-eb-byom-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final modelsDir = Directory('${dir.path}/models')..createSync(recursive: true);
      FolderSet(main: dir.path, models: modelsDir.path, chats: '${dir.path}/chats', cache: '${dir.path}/cache').save(dir);

      File('${modelsDir.path}/Mixtral-Custom-Q4_K_M.gguf').writeAsBytesSync(
        _makeSyntheticGguf(arch: 'llama', name: 'Mixtral Custom', contextLength: 32768, expertCount: 8, expertUsedCount: 2),
      );

      final backend = EngineBackend(Storage(dir));
      final catalog = await backend.loadCatalog();
      final byom = catalog.where((c) => c.id == 'byom/Mixtral-Custom-Q4_K_M').single;
      final file = byom.files.single;
      expect(backend.maxContext(file), 32768);
      final cmds = backend.autoCommands(file);
      expect(cmds.keys, [4096, 8192, 16384, 32768]);
      for (final entry in cmds.entries) {
        expect(commandProblem(entry.value, maxContext: 32768), isNull);
        expect(entry.value, contains('--moe-stream-guess-gate 1'));
      }
    });
  });

  group('Unified autotuner synthesis & 2x2 Guesser Census', () {
    test('commandsFromAutotuner consumes recommended_flags and recommended_env cleanly and withTuning stays idempotent', () {
      final tune = {
        'threads': 12,
        'threads_batch': 24,
        'io_threads': 8,
        'fast_mask': '0x0fff',
        'logical_cores': 24,
        'recommended_env': {'GGML_CUDA_COPY_KERNEL': '65536', 'LD_PRELOAD': '/bad.so'},
        'recommended_flags': '-m /tmp/ignored.gguf --port 8080 -c 8192 -t 12 --moe-stream model --moe-stream-io-threads 6 --moe-stream-guess-gate 1',
      };
      final cmds = commandsFromAutotuner(tune, maxContext: 65536, isMoE: true, largestGpuGiB: 24);
      expect(cmds.keys, [4096, 8192, 16384, 32768, 65536]);
      for (final entry in cmds.entries) {
        expect(commandProblem(entry.value, maxContext: 65536), isNull);
        expect(entry.value, isNot(contains('LD_PRELOAD')));
        expect(entry.value, contains('GGML_CUDA_COPY_KERNEL=65536'));
      }
      final args = withTuning(['-c', '16384', '-t', '12', '--moe-stream-io-threads', '6'], tune);
      expect(args.where((a) => a == '--moe-stream-io-threads').length, 1);
      expect(args[args.indexOf('--moe-stream-io-threads') + 1], '8');
    });

    test('parses 2x2 Guesser Census and tracks per-token SSD precision without disturbing existing guess shares', () {
      Map<String, Object?> doc({required int tok, required int mr, required int mw, required int sr, required int sw, required int sv}) => {
        'total': {
          'reply': {
            'tokens': tok,
            'hits': tok * 460,
            'misses': tok * 8,
            'stall_ms': tok * 3.0,
            'guesses': {
              'in_time': tok * 16,
              'late': tok * 2,
              'missed': tok * 8,
              'wasted': sw,
              'cancelled': tok * 1,
              'mem_right': mr,
              'mem_wrong': mw,
              'ssd_right': sr,
              'ssd_wrong': sw,
              'skip_floor': tok * 4,
              'skip_vic': sv,
              'defer_q': tok * 2,
            },
          },
        },
      };

      final s0 = EngineSnapshot.parse(doc(tok: 10, mr: 1500, mw: 350, sr: 160, sw: 40, sv: 90))!;
      final s1 = EngineSnapshot.parse(doc(tok: 110, mr: 16500, mw: 3850, sr: 1760, sw: 240, sv: 990))!;
      final c1 = GuesserCensus.parse(doc(tok: 110, mr: 16500, mw: 3850, sr: 1760, sw: 240, sv: 990))!;
      expect(c1.inMemTotal, 20350);
      expect(c1.onSsdTotal, 2000);
      expect(c1.onSsdPrecisionPercent, closeTo(88.0, 1e-6));

      final tracker = EngineStatsTracker()..add(s0);
      final delta = tracker.add(s1);
      expect(delta['eng.gMemRight'], closeTo(150.0, 1e-6));
      expect(delta['eng.gMemWrong'], closeTo(35.0, 1e-6));
      expect(delta['eng.gSsdRight'], closeTo(16.0, 1e-6));
      expect(delta['eng.gSsdWrong'], closeTo(2.0, 1e-6));
      expect(delta['eng.gSkipVic'], closeTo(9.0, 1e-6));
      expect(delta['eng.gSsdPrecision'], closeTo(100 * 1600 / 1800, 1e-5));
    });
  });
}
