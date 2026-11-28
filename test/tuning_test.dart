import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/engine/tuning.dart';

void main() {
  const auto = ['-c', '8192', '-ctk', 'q8_0', '-ctv', 'q8_0', '--moe-stream', 'model'];

  test('no measurement keeps the command: the engine picks for itself', () {
    expect(withTuning(auto, null), auto);
    expect(withTuning(auto, {'threads': 7}), auto, reason: 'a result without the flag list');
  });

  test("the autotuner's flags go in as it gives them", () {
    expect(
      withTuning(auto, {
        'threads': 7,
        'recommended_args': ['--moe-stream', 'model', '-t', '7', '-tb', '11', '--moe-stream-io-threads', '4'],
      }),
      [...auto, '-t', '7', '-tb', '11', '--moe-stream-io-threads', '4'],
    );
  });

  test("fast cores, the card of the expert pool and the shared-memory mode are the autotuner's too", () {
    expect(
      withTuning(auto, {
        'recommended_args': ['--moe-stream', 'model', '-t', '6', '--cpu-mask', 'fc03', '--cpu-strict', '1', '--moe-stream-vram-device', 'CUDA1'],
      }),
      [...auto, '-t', '6', '--cpu-mask', 'fc03', '--cpu-strict', '1', '--moe-stream-vram-device', 'CUDA1'],
    );
    expect(withTuning(auto, {'recommended_args': ['--moe-stream', 'model', '-t', '10', '--moe-stream-uma', '1']}),
        [...auto, '-t', '10', '--moe-stream-uma', '1']);
  });

  test("a flag the command names keeps its value (a profile of the user's own)", () {
    expect(withTuning(['-c', '8192', '-t', '4'], {'recommended_args': ['--moe-stream', 'model', '-t', '7', '-tb', '11']}),
        ['-c', '8192', '-t', '4', '--moe-stream', 'model', '-tb', '11']);
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
