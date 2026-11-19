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

  test('prompts get their own thread count when the autotuner measured more for them', () {
    expect(withTuning(table, {'threads': 9, 'threads_batch': 11, 'fast_cpus': '', 'fast_mask': ''}),
        ['-c', '8192', '-t', '9', '--moe-stream', 'model', '-tb', '11']);
    expect(withTuning(table, {'threads': 9, 'threads_batch': 9}), ['-c', '8192', '-t', '9', '--moe-stream', 'model']);
  });

  test('fast cores as a mask (one thread per core, any numbering); prompts keep every core', () {
    expect(withTuning(table, {'threads': 6, 'threads_batch': 13, 'fast_cpus': '', 'fast_mask': '0xfc03', 'logical_cores': 24}), [
      '-c', '8192', '-t', '6', '--moe-stream', 'model', '--cpu-mask', '0xfc03', '--cpu-range-batch', '0-23', '-tb', '13',
    ]);
  });

  test('several cards: the slowest holds the pool, the faster ones are named slowest first and the engine counts their layers', () {
    expect(cardFlags([(name: 'CUDA1', mib: 11911), (name: 'CUDA0', mib: 11909)]), [
      '--device', 'CUDA0,CUDA1', '--moe-stream-vram-device', 'CUDA0', '--moe-stream-gpu-layers-device', 'CUDA1=auto',
    ]);
    expect(cardFlags([(name: 'CUDA0', mib: 24576), (name: 'CUDA2', mib: 12288), (name: 'CUDA1', mib: 8192)]), [
      '--device', 'CUDA1,CUDA0,CUDA2', '--moe-stream-vram-device', 'CUDA1',
      '--moe-stream-gpu-layers-device', 'CUDA2=auto', '--moe-stream-gpu-layers-device', 'CUDA0=auto',
    ]);
  });

  test('cards are ranked by measured speed, then size', () {
    expect(cardsFrom({'gpus': [{'name': 'A', 'mib': 24576, 'gbps': 300}, {'name': 'B', 'mib': 12288, 'gbps': 700}]}),
        [(name: 'B', mib: 12288), (name: 'A', mib: 24576)]);
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

  test("the autotuner's result is its last JSON line; driver lines and broken output are ignored", () {
    const noisy = 'ggml_vulkan: Found 1 Vulkan devices:\n{"threads": 6, "io_threads": 4}\n';
    expect(parseAutotunerJson(noisy), {'threads': 6, 'io_threads': 4});
    expect(parseAutotunerJson('{"threads": 6}\n{"threads": 8}\n'), {'threads': 8});
    expect(parseAutotunerJson('not json at all\n'), isNull);
    expect(parseAutotunerJson('{"threads": 6\n'), isNull);   // cut off
    expect(parseAutotunerJson('{"gpus": []}\n'), isNull);    // no thread count
  });
}
