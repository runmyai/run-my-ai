import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The longest context the model file says it was made for; null when that cannot be read.
///
/// Only the start of the file is read: the model's basic facts come before its long word lists.
int? modelContextLength(String path) {
  final RandomAccessFile file;
  try {
    file = File(path).openSync();
  } on FileSystemException {
    return null;
  }
  try {
    return contextLengthIn(file.readSync(_headerBytes));
  } on FileSystemException {
    return null;
  } finally {
    file.closeSync();
  }
}

const _headerBytes = 1 << 20;

/// The context length in the start of a GGUF file; null when it is not there.
int? contextLengthIn(Uint8List bytes) {
  try {
    final reader = _Reader(bytes);
    if (reader.bytes(4).toList().join(',') != 'GGUF'.codeUnits.join(',')) return null;
    reader.u32(); // version
    reader.u64(); // tensors
    final entries = reader.u64();
    String? architecture;
    final numbers = <String, int>{};
    for (var i = 0; i < entries; i++) {
      final key = reader.string();
      final type = reader.u32();
      if (type == _typeString) {
        final value = reader.string();
        if (key == 'general.architecture') architecture = value;
      } else if (_integerSizes.containsKey(type)) {
        numbers[key] = reader.integer(_integerSizes[type]!);
      } else {
        reader.skip(type);
      }
      if (architecture != null && numbers.containsKey('$architecture.context_length')) {
        return numbers['$architecture.context_length'];
      }
    }
  } on RangeError {
    // The facts are not in the part that was read.
  }
  return null;
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
