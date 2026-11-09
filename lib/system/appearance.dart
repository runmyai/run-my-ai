import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the computer is explicitly set to light. Until the user picks a theme, the app is light only then, and
/// Run My AI Dark otherwise (dark, no preference, or no answer). Windows and macOS always say light or dark; Linux
/// can say "no preference" (GNOME's default), which Flutter reports as light, so there the desktop's own setting is
/// read (the freedesktop portal's color-scheme: 0 none, 1 dark, 2 light), and Flutter's only when that is not there.
/// Checked at start and whenever the computer's setting changes.
class SystemLightNotifier extends Notifier<bool> with WidgetsBindingObserver {
  @override
  bool build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(this));
    _check();
    return !Platform.isLinux && _flutterSaysLight;
  }

  static bool get _flutterSaysLight =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.light;

  @override
  void didChangePlatformBrightness() => _check();

  Future<void> _check() async {
    if (!Platform.isLinux) {
      state = _flutterSaysLight;
      return;
    }
    final scheme = await _portalScheme();
    if (!ref.mounted) return;
    state = scheme == null ? _flutterSaysLight : scheme == 2;
  }

  /// The portal's color-scheme, or null when it cannot be read.
  static Future<int?> _portalScheme() async {
    try {
      final r = await Process.run('gdbus', [
        'call', '--session', '--dest', 'org.freedesktop.portal.Desktop', //
        '--object-path', '/org/freedesktop/portal/desktop',
        '--method', 'org.freedesktop.portal.Settings.ReadOne', 'org.freedesktop.appearance', 'color-scheme',
      ]);
      if (r.exitCode != 0) return null;
      final m = RegExp(r'uint32 (\d+)').firstMatch(r.stdout as String);
      return m == null ? null : int.parse(m.group(1)!);
    } on Object catch (_) {
      return null;
    }
  }
}

final systemLightProvider = NotifierProvider<SystemLightNotifier, bool>(SystemLightNotifier.new);
