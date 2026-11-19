// The note for a models folder on a hard disk or a USB drive.
// Run: flutter test test/slow_drive_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/system/folders.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/settings/slow_drive.dart';

void main() {
  test('the note names a hard disk or a USB drive, and nothing is said for an SSD or an unknown drive', () {
    expect(slowDriveWarning(DriveKind.hardDisk), contains('on a hard disk'));
    expect(slowDriveWarning(DriveKind.usb), contains('on a USB drive'));
    expect(slowDriveWarning(DriveKind.hardDisk), contains('very slow'));
    expect(slowDriveWarning(DriveKind.hardDisk), contains('An SSD is strongly recommended.'));
    expect(slowDriveWarning(DriveKind.ssd), isNull);
    expect(slowDriveWarning(DriveKind.unknown), isNull);
  });

  group('picking a models folder', () {
    late BuildContext context;
    late List<String?> picks;
    final asked = <String?>[];
    final kinds = {'/ssd': DriveKind.ssd, '/hdd': DriveKind.hardDisk, '/usb': DriveKind.usb, '/odd': DriveKind.unknown};

    Future<void> open(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [AppColors.light]),
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );

    Future<String?> Function() start(WidgetTester tester, List<String> folders) {
      asked.clear();
      picks = [...folders];
      return () => pickModelsFolder(
        context,
        confirmButtonText: 'Go',
        pick: (initial) async {
          asked.add(initial);
          return picks.removeAt(0);
        },
        kindOf: (folder) async => kinds[folder]!,
      );
    }

    testWidgets('an SSD or an unknown drive: no note', (tester) async {
      await open(tester);
      for (final folder in ['/ssd', '/odd']) {
        final picked = start(tester, [folder])();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('slow-drive-keep')), findsNothing);
        expect(await picked, folder);
      }
    });

    testWidgets('a hard disk or a USB drive: the note, and Keep this folder keeps it', (tester) async {
      await open(tester);
      for (final (folder, text) in [('/hdd', 'on a hard disk'), ('/usb', 'on a USB drive')]) {
        final picked = start(tester, [folder])();
        await tester.pumpAndSettle();
        expect(find.textContaining(text), findsOneWidget);
        await tester.tap(find.byKey(const Key('slow-drive-keep')));
        await tester.pumpAndSettle();
        expect(await picked, folder);
      }
    });

    testWidgets('Choose another folder asks again, from the folder just picked', (tester) async {
      await open(tester);
      final picked = start(tester, ['/hdd', '/ssd'])();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('slow-drive-other')));
      await tester.pumpAndSettle();
      expect(await picked, '/ssd');
      expect(asked, [null, '/hdd']);
    });

    testWidgets('no folder picked: nothing', (tester) async {
      await open(tester);
      final picked = pickModelsFolder(context, confirmButtonText: 'Go', pick: (_) async => null);
      await tester.pumpAndSettle();
      expect(await picked, isNull);
    });
  });
}
