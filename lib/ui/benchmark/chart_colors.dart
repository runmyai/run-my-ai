import 'package:flutter/material.dart';

import '../../theme.dart';

/// The colours of the graphs: the only colour on the page besides errors. Each is kept readable on the page of its
/// theme (lighter on the dark ones, deeper on the light ones).
class ChartColors {
  const ChartColors._();

  static const _dark = [
    Color(0xFF8FA6F5),
    Color(0xFF7FD1A8),
    Color(0xFFE9B872),
    Color(0xFFD6A8F0),
    Color(0xFF6CC6E0),
    Color(0xFFEF8B8B),
    Color(0xFFB5C76B),
    Color(0xFFD99AAE),
  ];

  static const _light = [
    Color(0xFF3F5BD0),
    Color(0xFF1E8C63),
    Color(0xFFB57313),
    Color(0xFF8F4FB8),
    Color(0xFF1B8EAD),
    Color(0xFFC24444),
    Color(0xFF7D8F1C),
    Color(0xFFB04B72),
  ];

  /// Colour number [index] (they repeat after eight).
  static Color of(BuildContext context, int index) {
    final list = context.colors.isLight ? _light : _dark;
    return list[index % list.length];
  }

  /// The colours of the time-per-token parts, by name.
  static Color part(BuildContext context, String name) => switch (name) {
    'SSD wait' => of(context, 2),
    'CPU' => of(context, 1),
    'GPU' => of(context, 0),
    'CPU-GPU sync' => of(context, 3),
    _ => context.colors.textMuted,
  };

  /// The colour of the guess outcomes, by series id.
  static Color guess(BuildContext context, String id) => switch (id) {
    'gInTime' => of(context, 1),
    'gLate' => of(context, 2),
    'gMissed' => of(context, 5),
    'gWasted' => of(context, 3),
    _ => context.colors.textMuted,
  };
}
