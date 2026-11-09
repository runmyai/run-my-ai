import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/prefs.dart';
import '../state/providers.dart';

/// The sound played when a reply finishes, while the bell is on (lib/state/prefs.dart): the user's own (a copy in
/// the data folder) or else the app's, played by the app's sound player (native/sound.c) the same way on every
/// system. One sound at a time: a new one replaces one still playing; turning the bell off stops it. A finished
/// reply's sound comes [delay] after the reply ends (Play in Settings plays at once).
class Chime {
  Chime(this._ref, [SoundPlayer? player, this.delay = const Duration(milliseconds: 350)])
    : _player = player ?? SoundPlayer.load() {
    _ref.listen(prefsProvider.select((p) => p.bell), (_, on) {
      if (!on) stop();
    });
    _ref.onDispose(stop);
  }

  final Ref _ref;
  final SoundPlayer? _player;

  /// How long after a reply ends its sound plays.
  final Duration delay;

  /// A finished reply's sound, waiting for [delay].
  Timer? _waiting;

  /// While a sound plays: checks when it has ended, to close the sound device.
  Timer? _watch;

  /// The file types a sound can be.
  static const types = ['wav', 'mp3', 'flac', 'ogg'];

  /// The app's own sound, where the build puts it next to the app.
  static String get _ownFile {
    final dir = File(Platform.resolvedExecutable).parent.path;
    const asset = 'flutter_assets/assets/sounds/reply-done.mp3';
    return Platform.isMacOS ? '$dir/../Frameworks/App.framework/Resources/$asset' : '$dir/data/$asset';
  }

  /// The user's own sound file, if they chose one.
  String? get _userFile {
    final file = _ref.read(prefsProvider).soundFile;
    return file == null ? null : '${_ref.read(storageProvider).dir.path}/$file';
  }

  /// A reply finished (one the user stopped does not count): its sound, [delay] later.
  void replyDone() {
    if (!_ref.read(prefsProvider).bell) return;
    _waiting?.cancel();
    _waiting = delay == Duration.zero ? null : Timer(delay, play);
    if (_waiting == null) play();
  }

  /// Plays the sound (the user's own; the app's when there is none, or it cannot be played).
  Future<void> play() async {
    final player = _player;
    if (player == null) return;
    final own = _userFile;
    if ((own == null || !player.play(own)) && !player.play(_ownFile)) return;
    _watch?.cancel();
    _watch = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!player.playing) stop();
    });
  }

  /// Stops the sound, if one plays (or one waits to), and closes the sound device.
  void stop() {
    _waiting?.cancel();
    _waiting = null;
    _watch?.cancel();
    _watch = null;
    _player?.stop();
  }

  /// Lets the user pick a sound file: it is copied into the data folder and becomes the sound. Gives the file's name
  /// when chosen, null when nothing was picked; throws [FormatException] when it cannot be played.
  Future<String?> choose() async {
    final picked = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: 'Sounds', extensions: [...types, for (final t in types) t.toUpperCase()]),
      ],
    );
    if (picked == null) return null;
    final player = _player;
    if (player == null || !player.check(picked.path)) throw const FormatException('That file cannot be played.');
    final dir = Directory('${_ref.read(storageProvider).dir.path}/sounds')..createSync(recursive: true);
    final ext = picked.name.contains('.') ? picked.name.split('.').last.toLowerCase() : 'sound';
    // Copied next to the old one first, so a failed copy leaves the old sound as it was.
    final copy = await File(picked.path).copy('${dir.path}/new.$ext');
    for (final f in dir.listSync()) {
      if (f is File && f.path != copy.path) f.deleteSync();
    }
    await copy.rename('${dir.path}/custom.$ext');
    _ref.read(prefsProvider.notifier).setSound(picked.name, 'sounds/custom.$ext');
    return picked.name;
  }

  /// Back to the app's own sound (the user's copy is deleted).
  void reset() {
    final own = _userFile;
    _ref.read(prefsProvider.notifier).setSound(null, null);
    if (own != null && File(own).existsSync()) File(own).deleteSync();
  }
}

/// The app's sound player (native/sound.c), loaded from next to the app.
class SoundPlayer {
  SoundPlayer(DynamicLibrary lib)
    : _check = Platform.isWindows
          ? _wide(lib.lookupFunction<Int32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('sound_check_w'))
          : _utf8(lib.lookupFunction<Int32 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>('sound_check')),
      _play = Platform.isWindows
          ? _wide(lib.lookupFunction<Int32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('sound_play_w'))
          : _utf8(lib.lookupFunction<Int32 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>('sound_play')),
      _playing = lib.lookupFunction<Int32 Function(), int Function()>('sound_playing'),
      _stop = lib.lookupFunction<Void Function(), void Function()>('sound_stop');

  /// The player, or null when it is not there (as in the tests).
  static SoundPlayer? load() {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final path = Platform.isWindows
        ? '$dir/runmyai_sound.dll'
        : Platform.isMacOS
        ? '$dir/../Frameworks/librunmyai_sound.dylib'
        : '$dir/lib/librunmyai_sound.so';
    try {
      return SoundPlayer(DynamicLibrary.open(path));
    } on Object catch (_) {
      return null;
    }
  }

  final int Function(String) _check;
  final int Function(String) _play;
  final int Function() _playing;
  final void Function() _stop;

  static int Function(String) _utf8(int Function(Pointer<Utf8>) f) => (path) {
    final p = path.toNativeUtf8();
    try {
      return f(p);
    } finally {
      malloc.free(p);
    }
  };

  static int Function(String) _wide(int Function(Pointer<Utf16>) f) => (path) {
    final p = path.toNativeUtf16();
    try {
      return f(p);
    } finally {
      malloc.free(p);
    }
  };

  /// Whether the file can be played.
  bool check(String path) => _check(path) == 1;

  /// Plays the file from its start, in place of any sound still playing; false when it cannot be played.
  bool play(String path) => _play(path) == 1;

  bool get playing => _playing() == 1;

  /// Stops the sound and closes the sound device.
  void stop() => _stop();
}

final chimeProvider = Provider<Chime>(Chime.new);
