import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../data/models.dart';

/// Basic facts read from the start of a GGUF file.
class GgufInfo {
  const GgufInfo({
    this.architecture,
    this.name,
    this.contextLength,
    this.blockCount,
    this.expertCount,
    this.expertUsedCount,
    this.needsQuantPlugin = false,
  });

  final String? architecture;
  final String? name;
  final int? contextLength;
  final int? blockCount;
  final int? expertCount;
  final int? expertUsedCount;

  /// True when the GGUF header declares routed MoE experts (`expert_count > 1`).
  bool get isMoE => (expertCount ?? 0) > 1;

  /// True when a tensor uses an external GGML type (`EXT0..EXT5`) requiring `--quant-plugin`.
  final bool needsQuantPlugin;
}

/// The longest context the model file says it was made for; null when that cannot be read.
///
/// Only the start of the file is read: the model's basic facts come before its long word lists.
int? modelContextLength(String path) => readGgufInfo(path)?.contextLength;

/// Reads basic model metadata from the start of [path]; null when [path] cannot be read or is not a GGUF file.
GgufInfo? readGgufInfo(String path) {
  final RandomAccessFile file;
  try {
    file = File(path).openSync();
  } on FileSystemException {
    return null;
  }
  try {
    return readGgufInfoIn(file.readSync(_headerBytes));
  } on FileSystemException {
    return null;
  } finally {
    file.closeSync();
  }
}

const _headerBytes = 1 << 20;

/// The context length in the start of a GGUF file; null when it is not there.
int? contextLengthIn(Uint8List bytes) => readGgufInfoIn(bytes)?.contextLength;

/// Reads [GgufInfo] from the opening [bytes] of a GGUF v2/v3 file; null when the magic header is missing.
GgufInfo? readGgufInfoIn(Uint8List bytes) {
  try {
    final reader = _Reader(bytes);
    if (reader.bytes(4).toList().join(',') != 'GGUF'.codeUnits.join(',')) return null;
    final version = reader.u32();
    if (version < 2 || version > 3) return null;
    final nTensors = reader.u64();
    final entries = reader.u64();
    String? architecture;
    String? name;
    final numbers = <String, int>{};
    try {
      for (var i = 0; i < entries; i++) {
        final key = reader.string();
        final type = reader.u32();
        if (type == _typeString) {
          final value = reader.string();
          if (key == 'general.architecture') architecture = value;
          if (key == 'general.name') name = value;
        } else if (_integerSizes.containsKey(type)) {
          numbers[key] = reader.integer(_integerSizes[type]!);
        } else {
          reader.skip(type);
        }
      }
      var extQuant = false;
      for (var t = 0; t < nTensors; t++) {
        reader.string(); // tensor name
        final nDims = reader.u32();
        for (var d = 0; d < nDims; d++) {
          reader.u64();
        }
        final ggmlType = reader.u32();
        reader.u64(); // offset
        if (ggmlType >= 41 && ggmlType <= 46) {
          extQuant = true;
          break;
        }
      }
      final arch = architecture;
      return GgufInfo(
        architecture: arch,
        name: name,
        contextLength: arch == null ? null : numbers['$arch.context_length'],
        blockCount: arch == null ? null : numbers['$arch.block_count'],
        expertCount: arch == null ? null : numbers['$arch.expert_count'],
        expertUsedCount: arch == null ? null : numbers['$arch.expert_used_count'],
        needsQuantPlugin: extQuant,
      );
    } on RangeError {
      // Truncated inside long KV arrays (e.g. tokenizer vocab): return what we already gathered before the arrays.
      final arch = architecture;
      if (arch == null && name == null && numbers.isEmpty) return const GgufInfo();
      return GgufInfo(
        architecture: arch,
        name: name,
        contextLength: arch == null ? null : numbers['$arch.context_length'],
        blockCount: arch == null ? null : numbers['$arch.block_count'],
        expertCount: arch == null ? null : numbers['$arch.expert_count'],
        expertUsedCount: arch == null ? null : numbers['$arch.expert_used_count'],
      );
    }
  } on RangeError {
    return null;
  }
}

final _splitShardPattern = RegExp(r'^(.+)-(\d{5})-of-(\d{5})\.gguf$', caseSensitive: false);
final _quantTagPattern = RegExp(
  r'[-_.](UD-Q\d+_K_\w+|IQ\d+_\w+|Q\d+_K_\w+|Q\d+_\w+|MXFP4(?:_MOE)?|BF16|F16|F32|WV-[A-Za-z0-9.-]+)(?=[-._]|$)',
  caseSensitive: false,
);

/// Discovers user-supplied ("Bring Your Own Model") `.gguf` files in [folders], excluding [knownParts] and grouping
/// multi-shard `-00001-of-NNNNN.gguf` sets into a single entry.
List<({CatalogModel model, GgufInfo info})> discoverByomModels(
  Iterable<String> folders, {
  Set<String> knownParts = const {},
}) {
  final seenIds = <String>{};
  final found = <({CatalogModel model, GgufInfo info})>[];

  for (final folder in folders) {
    final dir = Directory(folder);
    if (!dir.existsSync()) continue;
    final entries = <File>[];
    try {
      for (final e in dir.listSync()) {
        if (e is File && e.path.toLowerCase().endsWith('.gguf')) entries.add(e);
      }
    } on FileSystemException {
      continue;
    }
    entries.sort((a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last));
    final namesInDir = {for (final f in entries) f.uri.pathSegments.last: f};

    for (final file in entries) {
      final fname = file.uri.pathSegments.last;
      if (knownParts.contains(fname)) continue;

      var stem = fname.substring(0, fname.length - 5);
      final parts = <String>[fname];
      var totalBytes = 0;

      final split = _splitShardPattern.firstMatch(fname);
      if (split != null) {
        final idx = int.parse(split.group(2)!);
        final count = int.parse(split.group(3)!);
        if (idx != 1 || count < 1) continue; // Secondary shards belong to shard 00001.
        stem = split.group(1)!;
        parts.clear();
        var allPresent = true;
        for (var s = 1; s <= count; s++) {
          final shardName = '$stem-${s.toString().padLeft(5, '0')}-of-${count.toString().padLeft(5, '0')}.gguf';
          final shardFile = namesInDir[shardName];
          if (shardFile == null) {
            allPresent = false;
            break;
          }
          parts.add(shardName);
          totalBytes += shardFile.lengthSync();
        }
        if (!allPresent) continue;
      } else {
        totalBytes = file.lengthSync();
      }

      final info = readGgufInfo(file.path);
      if (info == null) continue; // Not a valid GGUF file (e.g. truncated/placeholder).

      for (final sidecar in [
        '$fname.correction',
        '$stem.correction',
        '$fname.vram-experts.json',
        '$stem.vram-experts.json',
        '$fname.usage-seed.json',
      ]) {
        if (File('$folder${Platform.pathSeparator}$sidecar').existsSync() && !parts.contains(sidecar)) {
          parts.add(sidecar);
        }
      }

      final id = 'byom/$stem';
      if (!seenIds.add(id)) continue;

      final qMatch = _quantTagPattern.firstMatch(stem);
      final quant = qMatch != null ? qMatch.group(1)! : 'GGUF';
      final displayName = (info.name != null && info.name!.trim().isNotEmpty)
          ? info.name!.trim()
          : stem.replaceAll(RegExp(r'[-_]+'), ' ').trim();
      final gib = (totalBytes / (1024 * 1024 * 1024)).toStringAsFixed(1);
      final desc = info.isMoE
          ? '${info.architecture ?? 'MoE'} (${info.expertUsedCount ?? '?'} of ${info.expertCount} experts, $gib GiB)'
          : '${info.architecture ?? 'Dense'} ($gib GiB)';

      final modelFile = ModelFile(
        id: '$id/$quant',
        quantization: quant,
        sizeBytes: totalBytes,
        parts: parts,
      );
      found.add((
        model: CatalogModel(
          id: id,
          name: displayName,
          lab: 'Local GGUF',
          description: desc,
          parameters: '$gib GiB',
          activeParameters: info.isMoE ? '${info.expertUsedCount ?? '?'}/${info.expertCount} exp' : 'Dense',
          thinking: ModelThinking.optional,
          files: [modelFile],
        ),
        info: info,
      ));
    }
  }
  return found;
}

const _typeString = 8;
const _typeArray = 9;
const _integerSizes = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 10: 8, 11: 8};
const _otherSizes = {6: 4, 7: 1, 12: 8};

class _Reader {
  _Reader(this._data) : _view = ByteData.sublistView(_data);

  final Uint8List _data;
  final ByteData _view;
  var _at = 0;

  Uint8List bytes(int n) {
    final part = Uint8List.sublistView(_data, _at, _at + n);
    _at += n;
    return part;
  }

  int u32() {
    final v = _view.getUint32(_at, Endian.little);
    _at += 4;
    return v;
  }

  int u64() {
    final v = _view.getUint64(_at, Endian.little);
    _at += 8;
    return v;
  }

  int integer(int size) => switch (size) {
    1 => bytes(1)[0],
    2 => () {
      final v = _view.getUint16(_at, Endian.little);
      _at += 2;
      return v;
    }(),
    4 => u32(),
    _ => u64(),
  };

  String string() => utf8.decode(bytes(u64()), allowMalformed: true);

  void skip(int type) {
    if (type == _typeArray) {
      final inner = u32();
      final count = u64();
      for (var i = 0; i < count; i++) {
        inner == _typeArray ? throw RangeError('nested') : skip(inner);
      }
    } else if (type == _typeString) {
      string();
    } else {
      _at += _integerSizes[type] ?? _otherSizes[type] ?? (throw RangeError('type'));
    }
  }
}
