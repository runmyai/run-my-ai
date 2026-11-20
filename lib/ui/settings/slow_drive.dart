import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../system/folders.dart';
import '../../theme.dart';
import '../buttons.dart';

/// What to tell the user about a models folder on [kind] of drive; null when nothing needs saying (an SSD, or a
/// drive the system could not tell).
String? slowDriveWarning(DriveKind kind) {
  final on = switch (kind) {
    DriveKind.hardDisk => 'a hard disk',
    DriveKind.usb => 'a USB drive',
    _ => null,
  };
  return on == null
      ? null
      : 'This folder is on $on. Models run from the drive while they answer, so they will be very slow here. '
            'An SSD is strongly recommended.';
}

/// Lets the user pick a folder that will hold models. When it is on a hard disk or a USB drive, a note says so and
/// the user can pick another folder or keep this one. Null when the user picked none. [pick] and [kindOf] are for tests.
Future<String?> pickModelsFolder(
  BuildContext context, {
  required String confirmButtonText,
  String? initialDirectory,
  Future<String?> Function(String? initialDirectory)? pick,
  Future<DriveKind> Function(String folder)? kindOf,
}) async {
  var start = initialDirectory;
  while (true) {
    final dir =
        await (pick?.call(start) ?? getDirectoryPath(initialDirectory: start, confirmButtonText: confirmButtonText));
    if (dir == null || !context.mounted) return null;
    final warning = slowDriveWarning(await (kindOf ?? driveKindOf)(dir));
    if (warning == null || !context.mounted) return dir;
    final keep = await showDialog<bool>(
      context: context,
      builder: (_) => _SlowDriveBox(warning: warning),
    );
    if (keep == null) return null;
    if (keep) return dir;
    start = dir;
  }
}

/// The note, with Choose another folder (chosen when it opens) and Keep this folder.
class _SlowDriveBox extends StatelessWidget {
  const _SlowDriveBox({required this.warning});

  final String warning;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AlertDialog(
      constraints: const BoxConstraints(maxWidth: 400),
      content: Text(warning, style: TextStyle(fontSize: 15, height: 1.5, color: c.text)),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      actions: [
        AppButton(
          key: const Key('slow-drive-other'),
          label: 'Choose another folder',
          autofocus: true,
          ringAlways: true,
          onTap: () => Navigator.pop(context, false),
        ),
        AppButton(
          key: const Key('slow-drive-keep'),
          label: 'Keep this folder',
          onTap: () => Navigator.pop(context, true),
        ),
      ],
    );
  }
}
