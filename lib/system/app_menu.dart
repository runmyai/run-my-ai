import 'dart:io';

/// The name Linux desktops match a running window to: the app's GTK application id (linux/CMakeLists.txt).
const appMenuId = 'com.runmyai.runmyai';

/// Puts the app in the Linux desktop's app menu, for this user only: a menu entry and the app's icon in the user's own
/// data folder (XDG_DATA_HOME, else ~/.local/share). The menu, the dock and the app switcher then show the app with
/// its name and icon (GNOME finds a window's icon only through such an entry). The entry starts the AppImage the app
/// came from, else this program; it is written again when that path or its text changes (an AppImage that was moved),
/// and left alone otherwise. Returns whether anything was written. Never throws.
Future<bool> addToAppMenu({Map<String, String>? environment, String? executable}) async {
  try {
    final env = environment ?? Platform.environment;
    final exe = executable ?? Platform.resolvedExecutable;
    final home = env['HOME'];
    final dataHome = (env['XDG_DATA_HOME'] ?? '').isNotEmpty ? env['XDG_DATA_HOME']! : '$home/.local/share';
    if (!dataHome.startsWith('/')) return false;
    final iconSource = File('${File(exe).parent.path}/data/flutter_assets/assets/app-icon/app-icon-256.png');
    var wrote = false;
    final icon = File('$dataHome/icons/hicolor/256x256/apps/$appMenuId.png');
    if (iconSource.existsSync() && (!icon.existsSync() || icon.lengthSync() != iconSource.lengthSync())) {
      icon.parent.createSync(recursive: true);
      iconSource.copySync(icon.path);
      wrote = true;
    }
    final entry = File('$dataHome/applications/$appMenuId.desktop');
    final text = appMenuEntry((env['APPIMAGE'] ?? '').isNotEmpty ? env['APPIMAGE']! : exe);
    if (!entry.existsSync() || entry.readAsStringSync() != text) {
      entry.parent.createSync(recursive: true);
      entry.writeAsStringSync(text);
      wrote = true;
    }
    return wrote;
  } on Object catch (e) {
    stderr.writeln('Run My AI: the app menu entry could not be written: $e');
    return false;
  }
}

/// The menu entry's text for the program at [path], quoted as the desktop entry format asks so any path works: inside
/// the quotes " ` $ and \ take a backslash, which the file's own escaping doubles, and % is written %%.
String appMenuEntry(String path) {
  final quoted = path
      .replaceAll('%', '%%')
      .replaceAllMapped(RegExp(r'["`$\\]'), (m) => m[0] == r'\' ? r'\\\\' : '\\\\${m[0]}');
  return '[Desktop Entry]\n'
      'Type=Application\n'
      'Name=Run My AI\n'
      'Comment=Run AI models on your own PC\n'
      'Exec="$quoted"\n'
      'Icon=$appMenuId\n'
      'Terminal=false\n'
      'Categories=Utility;\n'
      'StartupWMClass=$appMenuId\n';
}
