import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/system/app_menu.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('app-menu'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// A program folder like the app's bundle, with its icon.
  String program() {
    final icon = File('${dir.path}/app/data/flutter_assets/assets/app-icon/app-icon-256.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    expect(icon.existsSync(), isTrue);
    return '${dir.path}/app/runmyai';
  }

  test('writes the entry and the icon once, starting the AppImage when there is one', () async {
    final env = {'HOME': '${dir.path}/home', 'APPIMAGE': '/opt/My Apps/RunMyAI.AppImage'};
    expect(await addToAppMenu(environment: env, executable: program()), isTrue);
    final entry = File('${dir.path}/home/.local/share/applications/$appMenuId.desktop').readAsStringSync();
    expect(entry, contains('Exec="/opt/My Apps/RunMyAI.AppImage"\n'));
    expect(entry, contains('StartupWMClass=$appMenuId\n'));
    expect(File('${dir.path}/home/.local/share/icons/hicolor/256x256/apps/$appMenuId.png').readAsBytesSync(), [
      1,
      2,
      3,
    ]);
    expect(
      await addToAppMenu(environment: env, executable: program()),
      isFalse,
      reason: 'nothing changed',
    );
    env['APPIMAGE'] = '/home/u/Downloads/RunMyAI.AppImage';
    expect(
      await addToAppMenu(environment: env, executable: program()),
      isTrue,
      reason: 'the AppImage moved',
    );
  });

  test('without an AppImage the program itself, in XDG_DATA_HOME when set', () async {
    final exe = program();
    expect(
      await addToAppMenu(environment: {'HOME': '/nowhere', 'XDG_DATA_HOME': '${dir.path}/data'}, executable: exe),
      isTrue,
    );
    expect(File('${dir.path}/data/applications/$appMenuId.desktop').readAsStringSync(), contains('Exec="$exe"'));
  });

  test('a path with quotes, a dollar, a backslash or a percent sign is escaped', () {
    expect(appMenuEntry(r'/a "b" $c \d 5%'), contains(r'Exec="/a \\"b\\" \\$c \\\\d 5%%"'));
  });
}
