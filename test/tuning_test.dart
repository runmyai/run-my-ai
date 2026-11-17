import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/engine/tuning.dart';

void main() {
  const table = ['-c', '8192', '-t', '8', '--moe-stream', 'model'];

  test('no measurement keeps the table', () => expect(withTuning(table, null), table));

  test('the measured threads and SSD readers go in', () {
    expect(withTuning(table, {'threads': 7, 'fast_cpus': '', 'io_threads': 4}),
        ['-c', '8192', '-t', '7', '--moe-stream', 'model', '--moe-stream-io-threads', '4']);
  });

  test('fast cores: the measured threads stay on them', () {
    expect(withTuning(table, {'threads': 6, 'fast_cpus': '0-15'}),
        ['-c', '8192', '-t', '6', '--moe-stream', 'model', '--cpu-range', '0-15']);
  });

  test('two cards: the first runs the first layers with the pool, the second the last layers whole', () {
    expect(twoCardFlags([(name: 'CUDA1', mib: 11911), (name: 'CUDA0', mib: 11909)], 49, 2, 0.49), [
      '--device', 'CUDA1,CUDA0', '-ts', '31,18',
      '--moe-stream-vram-device', 'CUDA1', '--moe-stream-gpu-layers-device', 'CUDA0=31-48',
    ]);
  });

  test('a built-in GPU counts only without a separate card and with 24 GiB or more', () {
    expect(cardsFrom({'gpus': [], 'igpus': [{'name': 'CUDA0', 'mib': 124608}]}), [(name: 'CUDA0', mib: 124608)]);
    expect(cardsFrom({'gpus': [], 'igpus': [{'name': 'ROCm0', 'mib': 15872}]}), isEmpty);
    expect(cardsFrom({'gpus': [{'name': 'CUDA0', 'mib': 8192}], 'igpus': [{'name': 'Vulkan1', 'mib': 65536}]}),
        [(name: 'CUDA0', mib: 8192)]);
  });

  test('the CUDA 12 engine: old cards or an old driver', () {
    expect(needsCuda12(null), false);
    expect(needsCuda12('8.6, 615.71.09\n'), false);
    expect(needsCuda12('6.1, 580.178.04\n'), true);    // GTX 1080
    expect(needsCuda12('8.6, 550.144.03\n'), true);    // a driver older than 580
    expect(needsCuda12('8.6, 615.71.09\n6.1, 615.71.09\n'), true);
    expect(needsCuda12('unreadable'), true);
  });
}
