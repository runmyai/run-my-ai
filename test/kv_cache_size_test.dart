// The KV cache sizes the quantization picker shows (lib/ui/context_settings.dart): each model's formula by its catalogue
// id, F16 (its id is 'f16') sized as F16, and no size for a model without a formula.
// Run: flutter test test/kv_cache_size_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/ui/context_settings.dart';

void main() {
  test('Ling, Flint and Qwen sizes follow their formulas, by catalogue id', () {
    int bytes(String id, int tokens, String quant) => kvCacheBytes(modelId: id, tokens: tokens, quant: quant)!;
    // Ling: 7 x 576 values a token at 1.0625 / 0.5625 / 2 bytes, plus the fixed state.
    expect(bytes('ling-3.0-flash', 65536, 'q8_0'), 359317504);
    expect(bytes('ling-3.0-flash', 65536, 'f16'), 607043584);
    expect(bytes('ling-3.0-flash', 65536, 'q4_0'), 227196928);
    // Flint: the full layers, and the window's cells (2,816 below 262,144 tokens, 1,792 at it).
    expect(bytes('flint-40b', 65536, 'q8_0'), 1105477632);
    expect(bytes('flint-40b', 262144, 'q8_0'), 4061216768);
    // Qwen: 12 attention layers a token, plus the fixed state.
    expect(bytes('qwen3.8-flash-next', 65536, 'q8_0'), 1187217408);
  });

  test('a model without a formula has no size', () {
    expect(kvCacheBytes(modelId: 'dummy', tokens: 65536, quant: 'q8_0'), isNull);
  });

  test('sizes are formatted in GB from a gigabyte on, else MB', () {
    expect(formatKvCacheBytes(1187217408), '1.11 GB');
    expect(formatKvCacheBytes(359317504), '342.7 MB');
  });
}
