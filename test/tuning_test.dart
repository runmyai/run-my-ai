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
}
