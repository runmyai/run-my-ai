// Inkling 2 Mini catalog entry, tier presets, GGUF context length, and quant-plugin / mmproj wiring.
// Run: flutter test test/inkling_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/backend/engine_backend.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/auto_commands.dart';
import 'package:runmyai/engine/commands.dart';
import 'package:runmyai/engine/gguf.dart';
import 'package:runmyai/system/folders.dart';

Uint8List _inklingGgufHeader(int contextLength) {
  final out = BytesBuilder();
  void u32(int v) => out.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u64(int v) => out.add((ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());
  void str(String s) {
    final bytes = utf8.encode(s);
    u64(bytes.length);
    out.add(bytes);
  }

  out.add('GGUF'.codeUnits);
  u32(3); // version
  u64(0); // tensor count
  u64(2); // kv count
  str('general.architecture');
  u32(8); // string
  str('inkling2');
  str('inkling2.context_length');
  u32(4); // uint32
  u32(contextLength);
  return out.toBytes();
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('runmyai-inkling-'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<EngineBackend> backendWithCards(List<Map<String, Object?>> gpus) async {
    File('${dir.path}${Platform.pathSeparator}autotuner.json').writeAsStringSync(
      jsonEncode({
        'version': 2,
        'gpus': gpus,
        'igpus': const <Object?>[],
        'models': const <String, Object?>{},
      }),
    );
    return EngineBackend(Storage(dir));
  }

  test('the catalog includes Inkling 2 Mini with its weights, vision projector, and streaming manifests', () async {
    final catalog = await EngineBackend(Storage(dir)).loadCatalog();
    expect(catalog.first.id, 'ling-3.0-flash');
    final inkling = catalog.singleWhere((m) => m.id == 'inkling-2-mini');
    expect(inkling.name, 'Inkling 2 Mini');
    expect(inkling.lab, 'Thinking Machines');
    expect(inkling.parameters, '27B');
    expect(inkling.activeParameters, '4.8B');
    expect(inkling.thinking, ModelThinking.optional);
    final file = inkling.files.single;
    expect(file.id, 'inkling-2-mini/WV-v6.3');
    expect(file.repo, 'Grawnch/Inkling-2-Mini-WV-v6.3-TokenWing');
    expect(file.parts, [
      'Inkling-2-Mini-WV-v6.3.tokenwing.gguf',
      'Inkling-2-Mini-mmproj-bf16.gguf',
      'Inkling-2-Mini-WV-v6.3.vram-experts.json',
      'Inkling-2-Mini-WV-v6.3.tokenwing.gguf.layer-order.json',
      'Inkling-2-Mini-WV-v6.3.tokenwing.gguf.usage-seed.json',
    ]);
  });

  test('autoCommands selects inklingAuto, inklingAutoSmall, and inklingAutoCpu by GPU VRAM', () async {
    final large = await backendWithCards([
      {'name': 'CUDA0', 'mib': 16 * 1024, 'gbps': 25},
    ]);
    final file = (await large.loadCatalog()).singleWhere((m) => m.id == 'inkling-2-mini').files.single;
    expect(large.autoCommands(file)[4096], contains('--spec-type draft-mtp --spec-draft-n-max 7'));
    expect(large.autoCommands(file)[4096], contains('--mmproj {models}/Inkling-2-Mini-mmproj-bf16.gguf'));
    expect(large.autoCommands(file)[4096], isNot(contains('--no-mmproj-offload')));

    final small = await backendWithCards([
      {'name': 'CUDA0', 'mib': 8 * 1024, 'gbps': 20},
    ]);
    expect(small.autoCommands(file)[4096], contains('--no-mmproj-offload'));
    expect(small.autoCommands(file)[4096], contains('--moe-stream-copy-ahead 2'));

    final cpu = await backendWithCards(const []);
    expect(cpu.autoCommands(file)[4096], inklingAutoCpu[4096]);
  });

  test('GGUF reader extracts inkling2.context_length', () async {
    final header = _inklingGgufHeader(262144);
    expect(contextLengthIn(header), 262144);

    final sep = Platform.pathSeparator;
    final modelsDir = Directory('${dir.path}${sep}models')..createSync(recursive: true);
    FolderSet(
      main: dir.path,
      models: modelsDir.path,
      chats: '${dir.path}${sep}chats',
      cache: '${dir.path}${sep}cache',
    ).save(dir);

    final backend = EngineBackend(Storage(dir));
    final file = (await backend.loadCatalog()).singleWhere((m) => m.id == 'inkling-2-mini').files.single;
    for (final part in file.parts) {
      final target = File('${modelsDir.path}$sep$part');
      if (part.endsWith('.tokenwing.gguf')) {
        target.writeAsBytesSync(header);
      } else {
        target.writeAsStringSync('{}');
      }
    }
    expect(backend.maxContext(file), 262144);
  });

  test('starting Inkling requires wv_inkling_plugin and passes --quant-plugin and --mmproj when present', () async {
    final sep = Platform.pathSeparator;
    final engineDir = Directory('${dir.path}${sep}engine')..createSync(recursive: true);
    final modelsDir = Directory('${dir.path}${sep}models')..createSync(recursive: true);
    FolderSet(
      main: dir.path,
      models: modelsDir.path,
      chats: '${dir.path}${sep}chats',
      cache: '${dir.path}${sep}cache',
    ).save(dir);

    if (Platform.isWindows) {
      File('${Platform.environment['SystemRoot']}\\System32\\cmd.exe')
          .copySync('${engineDir.path}${sep}llama-server.exe');
    } else {
      final server = File('${engineDir.path}${sep}llama-server')
        ..writeAsStringSync('#!/bin/sh\nprintf \'%s\\n\' "\$@"\nexit 1\n');
      await Process.run('chmod', ['+x', server.path]);
    }

    Storage(dir).writePrefs(PrefsData(engineFolder: engineDir.path));
    final backend = await backendWithCards(const []);
    final file = (await backend.loadCatalog()).singleWhere((m) => m.id == 'inkling-2-mini').files.single;
    for (final part in file.parts) {
      File('${modelsDir.path}$sep$part').writeAsBytesSync(_inklingGgufHeader(262144));
    }

    const run = EngineRun(flags: '-c 4096', contextLength: 4096);
    await expectLater(
      backend.startEngine(file, run),
      throwsA(
        isA<EngineFailure>().having(
          (e) => e.message,
          'message',
          contains(quantPluginFile('wv_inkling_plugin')),
        ),
      ),
    );

    final pluginPath = '${engineDir.path}$sep${quantPluginFile('wv_inkling_plugin')}';
    File(pluginPath).writeAsStringSync('stub');

    if (!Platform.isWindows) {
      await expectLater(
        backend.startEngine(file, run),
        throwsA(
          isA<EngineFailure>().having(
            (e) => e.log,
            'log',
            containsAll([
              '--quant-plugin',
              pluginPath,
              '--mmproj',
              '${modelsDir.path}${sep}Inkling-2-Mini-mmproj-bf16.gguf',
            ]),
          ),
        ),
      );
    }
  });
}
