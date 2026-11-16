import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/engine/tuning.dart';

void main() {
  const table = ['-c', '8192', '-t', '8', '--moe-stream', 'model'];

  test('no measurement keeps the table', () => expect(withTuning(table, null), table));

  test('the measured threads and SSD readers go in', () {
    expect(withTuning(table, {'threads': 7, 'fast_cpus': '', 'io_threads': 4}),
        ['-c', '8192', '-t', '7', '--moe-stream', 'model', '--moe-stream-io-threads', '4']);
  });

  test('fast cores: the threads stay on them, at most one per fast core', () {
    expect(withTuning(table, {'threads': 12, 'fast_cpus': '0-15'}),
        ['-c', '8192', '-t', '8', '--moe-stream', 'model', '--cpu-range', '0-15', '--cpu-strict', '1']);
  });
}
