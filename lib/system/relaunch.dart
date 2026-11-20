import 'dart:io';

/// Starts a new copy of the app (with the same environment) and ends this one: for a change that the running app
/// cannot take over, such as the chats folder moving while its files are open, or a new version of the app. Started
/// from an AppImage, the AppImage file itself is started again (it may hold a new version by now), without the paths
/// into this copy's mounted folder, which goes away when this copy ends. Started by the Windows launcher, the launcher is
/// started again (it unpacks a new version first, if it holds one).
Future<Never> relaunchApp() async {
  final env = Platform.environment;
  final appImage = env['APPIMAGE'], launcher = env[launcherVariable];
  if (launcher != null && Platform.isWindows) {
    await Process.start(launcher, const [], mode: ProcessStartMode.detached);
  } else if (appImage != null) {
    await Process.start(
      appImage,
      const [],
      environment: appImageEnvironment(env),
      includeParentEnvironment: false,
      mode: ProcessStartMode.detached,
    );
  } else {
    await Process.start(Platform.resolvedExecutable, Platform.executableArguments, mode: ProcessStartMode.detached);
  }
  exit(0);
}

/// Set by the Windows launcher to its own path for the app it starts, so the app can replace the launcher with a new
/// version and start it again.
const launcherVariable = 'RUNMYAI_LAUNCHER';

/// [env] without the entries of path lists (PATH, LD_LIBRARY_PATH, ...) that point into the running AppImage's
/// folder (APPDIR), and without a variable left empty by that.
Map<String, String> appImageEnvironment(Map<String, String> env) {
  final appDir = env['APPDIR'];
  if (appDir == null || appDir.isEmpty) return {...env};
  final kept = <String, String>{};
  for (final MapEntry(:key, :value) in env.entries) {
    final rest = value.split(':').where((p) => !p.startsWith(appDir)).join(':');
    if (key != 'APPDIR' && rest.isNotEmpty) kept[key] = rest;
  }
  return kept;
}
