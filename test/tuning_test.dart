import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/engine/tuning.dart';

void main() {
  const table = ['-c', '8192', '-t', '8', '-b', '2048', '-ub', '2048', '--moe-stream', 'model'];

  test('no measurement keeps the table', () => expect(withTuning(table, null), table));

  test('the measured threads and SSD readers go in', () {
    expect(withTuning(['-c', '8192', '-t', '8', '--moe-stream', 'model'], {'threads': 7, 'fast_cpus': '', 'io_threads': 4}),
        ['-c', '8192', '-t', '7', '--moe-stream', 'model', '--moe-stream-io-threads', '4']);
  });

  test('fast cores: the measured threads stay on them', () {
    expect(withTuning(['-c', '8192', '-t', '8', '--moe-stream', 'model'], {'threads': 6, 'fast_cpus': '0-15'}),
        ['-c', '8192', '-t', '6', '--moe-stream', 'model', '--cpu-range', '0-15']);
  });

  test('decode -t and batch -tb split cleanly so prompt prefill uses all compute cores', () {
    expect(
      withTuning(table, {'threads': 4, 'threads_batch': 11, 'io_threads': 4}),
      ['-c', '8192', '-t', '4', '-b', '2048', '-ub', '2048', '--moe-stream', 'model', '-tb', '11', '--moe-stream-io-threads', '4'],
    );
  });

  test('fast_mask uses 1-per-physical-P-core --cpu-mask (HT & Arrow Lake) and frees --cpu-range-batch', () {
    expect(
      withTuning(table, {
        'threads': 6,
        'threads_batch': 13,
        'logical_cores': 20,
        'fast_cpus': '0-11',
        'fast_mask': '0x555',
        'io_threads': 4,
      }),
      [
        '-c', '8192', '-t', '6', '-b', '2048', '-ub', '2048', '--moe-stream', 'model',
        '-tb', '13', '--cpu-mask', '0x555', '--cpu-range-batch', '0-19', '--moe-stream-io-threads', '4',
      ],
    );
  });

  test('tight RAM lowers -ub when recommended, without raising an already smaller -ub', () {
    expect(
      withTuning(table, {'threads': 4, 'ubatch': 512}),
      ['-c', '8192', '-t', '4', '-b', '2048', '-ub', '512', '--moe-stream', 'model'],
    );
    const ctx256k = ['-c', '262144', '-t', '8', '-b', '1024', '-ub', '1024', '--moe-stream', 'model'];
    expect(
      withTuning(ctx256k, {'threads': 6, 'ubatch': 2048}),
      ['-c', '262144', '-t', '6', '-b', '1024', '-ub', '1024', '--moe-stream', 'model'],
    );
  });

  test('parseAutotunerJson ignores leading backend/driver banners and extracts the JSON line', () {
    const noisy = 'ggml_vulkan: Found 1 Vulkan devices:\n{"version": 2, "threads": 6, "io_threads": 4}\n';
    expect(parseAutotunerJson(noisy), {'version': 2, 'threads': 6, 'io_threads': 4});
    expect(parseAutotunerJson('not json at all\n'), isNull);
  });
}
