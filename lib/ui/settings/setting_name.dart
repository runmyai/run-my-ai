import 'package:flutter/material.dart';

import '../../theme.dart';

/// How long the pointer must rest on a name before its description shows: long enough that moving across the page
/// does not flash descriptions up. Used by every description tooltip (setting names, drop-down headings, the share-data
/// line); the short tooltips on icon buttons keep Flutter's own wait.
const descriptionTooltipWait = Duration(milliseconds: 1200);

/// A setting's name in Settings. Its [description] is not written under it: it shows when the pointer rests on the
/// name, so the page stays short.
class SettingName extends StatelessWidget {
  const SettingName(this.name, {super.key, this.description, this.size = 16});

  final String name;
  final String? description;
  final double size;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      name,
      style: TextStyle(fontSize: size, fontWeight: FontWeight.w500, color: context.colors.text),
    );
    return description == null
        ? text
        : Tooltip(message: description, waitDuration: descriptionTooltipWait, child: text);
  }
}

/// The look of a heading in Settings that is a drop-down ([Fold]).
TextStyle settingsFoldTitle(AppColors c) => TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.text);
