import '../engine/engine_flags.dart';

/// Where the engine kept things during a run, as far as it said: read from its output lines and the command. A part
/// that is not known stays null and is left out of the result.
class MemoryLayout {
  const MemoryLayout({
    this.ramSlots,
    this.streamedLayers,
    this.vramExpertsPerLayer,
    this.gpuLayers,
    this.kvMiB,
    this.memoryCapGiB,
    this.freeRamGiB,
  });

  /// Expert slots per streamed layer in RAM, and how many layers are streamed.
  final int? ramSlots;
  final int? streamedLayers;

  /// Experts per layer the video memory holds, and whole layers kept on the graphics card.
  final int? vramExpertsPerLayer;
  final int? gpuLayers;

  /// The attention cache's size.
  final double? kvMiB;

  /// The memory cap (null: all RAM but 1 GB) and the free RAM when the run began.
  final double? memoryCapGiB;
  final double? freeRamGiB;

  bool get isEmpty =>
      ramSlots == null && vramExpertsPerLayer == null && gpuLayers == null && kvMiB == null && freeRamGiB == null;

  /// What the engine's output [lines] and the [flags] it was started with say.
  factory MemoryLayout.read(
    List<String> lines,
    String flags, {
    double? memoryCapGiB,
    double? freeRamGiB,
    Map<String, Object?> layout = const {},
  }) {
    int? slots, layers, vram;
    double? kv;
    for (final line in lines) {
      final pool = RegExp(r'(\d+) slots per layer x (\d+)').firstMatch(line);
      if (pool != null) {
        slots = int.parse(pool[1]!);
        layers = int.parse(pool[2]!);
      }
      final experts = RegExp(r'VRAM experts: (\d+) per layer').firstMatch(line);
      if (experts != null) vram = int.parse(experts[1]!);
      if (line.toLowerCase().contains('kv')) {
        final size = RegExp(r'size\s*=\s*([\d.]+)\s*MiB').firstMatch(line);
        if (size != null) kv = (kv ?? 0) + double.parse(size[1]!);
      }
    }
    final args = EngineFlags.parse(flags).arguments;
    int? flag(String name) {
      for (var i = 0; i < args.length - 1; i++) {
        if (args[i] == name) return int.tryParse(args[i + 1]);
      }
      return null;
    }

    // What the engine says of its own layout (its stats) is more exact than its log and the command.
    num? first(String key) {
      final v = layout[key];
      if (v is List) return v.whereType<num>().fold<num?>(null, (a, b) => a == null || b > a ? b : a);
      return v is num ? v : null;
    }

    final gpuList = layout['whole_gpu_layers'];
    return MemoryLayout(
      ramSlots: first('ram_slots_per_layer')?.toInt() ?? slots ?? flag('--moe-stream-slots'),
      streamedLayers: (layout['streamed_layers'] as num?)?.toInt() ?? layers,
      vramExpertsPerLayer: first('vram_experts_per_layer')?.toInt() ?? vram,
      gpuLayers: gpuList is List ? gpuList.length : flag('--moe-stream-gpu-layers'),
      kvMiB: (layout['kv_cache_mib'] as num?)?.toDouble() ?? kv,
      memoryCapGiB: memoryCapGiB,
      freeRamGiB: freeRamGiB,
    );
  }

  Map<String, Object?> toJson() => {
    'ramSlots': ramSlots,
    'streamedLayers': streamedLayers,
    'vramExpertsPerLayer': vramExpertsPerLayer,
    'gpuLayers': gpuLayers,
    'kvMiB': kvMiB,
    'memoryCapGiB': memoryCapGiB,
    'freeRamGiB': freeRamGiB,
  };

  factory MemoryLayout.fromJson(Map<String, Object?> json) => MemoryLayout(
    ramSlots: json['ramSlots'] as int?,
    streamedLayers: json['streamedLayers'] as int?,
    vramExpertsPerLayer: json['vramExpertsPerLayer'] as int?,
    gpuLayers: json['gpuLayers'] as int?,
    kvMiB: (json['kvMiB'] as num?)?.toDouble(),
    memoryCapGiB: (json['memoryCapGiB'] as num?)?.toDouble(),
    freeRamGiB: (json['freeRamGiB'] as num?)?.toDouble(),
  );
}
