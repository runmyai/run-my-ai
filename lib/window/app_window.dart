import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../data/storage.dart';

/// Which system's window style the app draws: Apple's buttons top left (mac), or our own buttons top right.
enum WindowLook { mac, windows, linux }

final WindowLook _systemLook = Platform.isMacOS
    ? WindowLook.mac
    : Platform.isWindows
        ? WindowLook.windows
        : WindowLook.linux;

/// RUNMYAI_LOOK=mac|windows|linux previews another system's look (developers only, never set in normal use).
final WindowLook windowLook = WindowLook.values.where((l) => l.name == Platform.environment['RUNMYAI_LOOK']).firstOrNull ?? _systemLook;

/// True when the app shows another system's look; then it draws Apple's three buttons itself.
final bool lookIsPreview = windowLook != _systemLook;

const minWindowSize = Size(760, 520);

/// Hides the system's title bar, sets the smallest window size, puts the window back where the user left
/// it, and from then on remembers where it is.
Future<void> setUpWindow(Storage storage) async {
  await windowManager.ensureInitialized();
  // On Linux the bar is removed in linux/runner/my_application.cc, which keeps the shadow and resize edges.
  if (Platform.isMacOS || Platform.isWindows) {
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: true);
  }
  await windowManager.setMinimumSize(minWindowSize);
  // The window's close button does not close it by itself: it asks first while a reply or a benchmark is running
  // (lib/ui/close_guard.dart).
  await windowManager.setPreventClose(true);
  // Windows and macOS take the app icon from the build; Linux gets it here (desktops that read a window's own icon).
  if (Platform.isLinux) {
    final icon = '${File(Platform.resolvedExecutable).parent.path}/data/flutter_assets/assets/app-icon/app-icon-256.png';
    if (File(icon).existsSync()) await windowManager.setIcon(icon);
  }
  final saved = storage.readWindow();
  if (saved != null) await _restore(saved);
  // The Mac window starts hidden (macos/Runner/MainFlutterWindow.swift), so the system bar never flashes.
  if (Platform.isMacOS) await windowManager.show();
  windowManager.addListener(_WindowSaver(storage, saved));
}

/// Linux on Wayland does not let programs choose where their window goes.
final bool _canPlace = !(Platform.isLinux && Platform.environment['WAYLAND_DISPLAY'] != null);

Future<void> _restore(WindowData saved) async {
  final size = Size(max(saved.width, minWindowSize.width), max(saved.height, minWindowSize.height));
  final x = saved.x;
  final y = saved.y;
  if (_canPlace && x != null && y != null && await _topIsOnScreen(Rect.fromLTWH(x, y, size.width, size.height))) {
    await windowManager.setBounds(Rect.fromLTWH(x, y, size.width, size.height));
  } else {
    await windowManager.setSize(size);
    if (_canPlace) await windowManager.center();
  }
  if (saved.maximized) await windowManager.maximize();
}

/// Whether the window's top row would be on a screen (a screen may have been unplugged since).
Future<bool> _topIsOnScreen(Rect window) async {
  final top = Rect.fromLTWH(window.left, window.top, window.width, 48);
  for (final d in await screenRetriever.getAllDisplays()) {
    final screen = (d.visiblePosition ?? Offset.zero) & (d.visibleSize ?? d.size);
    final overlap = screen.intersect(top);
    if (overlap.width >= 100 && overlap.height >= 24) return true;
  }
  return false;
}

/// Saves the window's size, place and maximized state to window.json half a second after it stops changing.
class _WindowSaver with WindowListener {
  _WindowSaver(this.storage, this._normal);

  final Storage storage;

  /// The last size and place while not maximized.
  WindowData? _normal;
  Timer? _timer;

  void _later() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
    if (await windowManager.isMinimized() || await windowManager.isFullScreen()) return;
    if (await windowManager.isMaximized()) {
      final normal = _normal;
      if (normal != null) storage.writeWindow(normal.withMaximized(true));
      return;
    }
    final b = await windowManager.getBounds();
    final normal = WindowData(
      width: b.width,
      height: b.height,
      x: _canPlace ? b.left : null,
      y: _canPlace ? b.top : null,
    );
    _normal = normal;
    storage.writeWindow(normal);
  }

  // Linux reports resize / move while it happens; Windows and macOS also when it ends.
  @override
  void onWindowResize() => _later();
  @override
  void onWindowResized() => _later();
  @override
  void onWindowMove() => _later();
  @override
  void onWindowMoved() => _later();
  @override
  void onWindowMaximize() => _later();
  @override
  void onWindowUnmaximize() => _later();
}

Future<void> toggleMaximize() async {
  if (await windowManager.isMaximized()) {
    await windowManager.unmaximize();
  } else {
    await windowManager.maximize();
  }
}

/// Whether the window is maximized (the middle button shows "restore" then).
class WindowMaximizedNotifier extends Notifier<bool> with WindowListener {
  @override
  bool build() {
    windowManager.addListener(this);
    ref.onDispose(() => windowManager.removeListener(this));
    windowManager.isMaximized().then((m) {
      if (ref.mounted) state = m;
    });
    return false;
  }

  @override
  void onWindowMaximize() => state = true;
  @override
  void onWindowUnmaximize() => state = false;
}

final windowMaximizedProvider = NotifierProvider<WindowMaximizedNotifier, bool>(WindowMaximizedNotifier.new);

/// Whether the window is in front (its edge and top row soften while another app is).
class WindowFocusedNotifier extends Notifier<bool> with WindowListener {
  @override
  bool build() {
    windowManager.addListener(this);
    ref.onDispose(() => windowManager.removeListener(this));
    windowManager.isFocused().then((f) {
      if (ref.mounted) state = f;
    });
    return true;
  }

  @override
  void onWindowFocus() => state = true;
  @override
  void onWindowBlur() => state = false;
}

final windowFocusedProvider = NotifierProvider<WindowFocusedNotifier, bool>(WindowFocusedNotifier.new);

/// Whether the window is full screen (it has no edge then, like maximized).
class WindowFullScreenNotifier extends Notifier<bool> with WindowListener {
  @override
  bool build() {
    windowManager.addListener(this);
    ref.onDispose(() => windowManager.removeListener(this));
    windowManager.isFullScreen().then((f) {
      if (ref.mounted) state = f;
    });
    return false;
  }

  @override
  void onWindowEnterFullScreen() => state = true;
  @override
  void onWindowLeaveFullScreen() => state = false;
}

final windowFullScreenProvider = NotifierProvider<WindowFullScreenNotifier, bool>(WindowFullScreenNotifier.new);
