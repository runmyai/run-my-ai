import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/engine/commands.dart';

void main() {
  test('the cache type replaces both -ctk and -ctv, and is added when the command has none', () {
    expect(withKvType('-c 65536 -ctk q8_0 -ctv q8_0 -fa on', 'q4_0'), '-c 65536 -ctk q4_0 -ctv q4_0 -fa on');
    expect(withKvType('-c 65536 -ctk=q8_0 -ctv=q8_0', 'f16'), '-c 65536 -ctk=f16 -ctv=f16');
    expect(withKvType('-c 4096', 'q8_0'), '-c 4096 -ctk q8_0 -ctv q8_0');
  });

  test('the start keeps the user\'s Memory headroom and cache type on a fresh table row', () {
    const row = '-c 4096 --moe-stream model --moe-stream-ram-free 0.5GiB -ctk q8_0 -ctv q8_0 --moe-stream-elastic 1';
    expect(withUserChoices(row, '-c 4096 --moe-stream model -ctk q4_0 -ctv q4_0'),
        '-c 4096 --moe-stream model -ctk q4_0 -ctv q4_0 --moe-stream-elastic 1');
    expect(withUserChoices(row, '-c 4096 --moe-stream-ram-free 2GiB -ctk q8_0'),
        '-c 4096 --moe-stream model --moe-stream-ram-free 2GiB -ctk q8_0 -ctv q8_0 --moe-stream-elastic 1');
    expect(withoutRamFree('--moe-stream-ram-free=1GiB -c 4096'), '-c 4096');
  });

  test('a data file next to the model replaces the copy inside it; without the file the flag stays', () {
    const args = ['--moe-stream', 'model', '--moe-stream-correction', 'model', '--moe-stream-vram-experts-file', 'model', '-c', '4096'];
    expect(withModelData(args, '/m/a.gguf', exists: (p) => p == '/m/a.gguf.vram-experts.json'), [
      '--moe-stream', 'model', '--moe-stream-correction', 'model', '--moe-stream-vram-experts-file', '/m/a.gguf.vram-experts.json',
      '-c', '4096',
    ]);
    expect(withModelData(args, '/m/a.gguf', exists: (_) => true)[3], '/m/a.gguf.correction');
    expect(withModelData(args, '/m/a.gguf', exists: (_) => false), args);
  });

  test('a named vram-experts file falls back to model when missing, and a missing mmproj is left out', () {
    const args = [
      '--mmproj', '/m/mmproj.gguf', '--no-mmproj-offload',
      '--moe-stream-vram-experts-file', '/m/ink.vram-experts.json',
      '-c', '4096',
    ];
    expect(withModelData(args, '/m/ink.gguf', exists: (_) => true), args);
    expect(withModelData(args, '/m/ink.gguf', exists: (_) => false), [
      '--moe-stream-vram-experts-file', 'model', '-c', '4096',
    ]);
  });

  test('quant plugin resolution prefers the engine folder and falls back to the model folder', () {
    final file = quantPluginFile('wv_inkling_plugin');
    final sep = Platform.pathSeparator;
    expect(
      resolveQuantPlugin(
        'wv_inkling_plugin',
        engineFolder: '/eng',
        modelFolder: '/mod',
        exists: (p) => p == '/eng$sep$file' || p == '/mod$sep$file',
      ),
      '/eng$sep$file',
    );
    expect(
      resolveQuantPlugin(
        'wv_inkling_plugin',
        engineFolder: '/eng',
        modelFolder: '/mod',
        exists: (p) => p == '/mod$sep$file',
      ),
      '/mod$sep$file',
    );
    expect(resolveQuantPlugin('wv_inkling_plugin', engineFolder: '/eng', modelFolder: '/mod', exists: (_) => false), isNull);
    expect(resolveQuantPlugin(null, engineFolder: '/eng', modelFolder: '/mod'), isNull);
    expect(hasQuantPluginFlag(['-c', '4096']), isFalse);
    expect(hasQuantPluginFlag(['--quant-plugin', '/eng/p.so', '-c', '4096']), isTrue);
    expect(hasQuantPluginFlag(['--quant-plugin=/eng/p.so']), isTrue);
  });

  test('the offered types are the engine\'s names', () => expect(kvTypes, ['q4_0', 'q8_0', 'f16']));
}
