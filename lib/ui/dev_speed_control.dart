import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/dummy_backend.dart';
import '../state/providers.dart';
import '../theme.dart';

/// A test control for the stand-in backend only, in the top row next to the model picker: how fast replies are
/// written, from 0.1 to 5000 tokens a second (the slider is even in steps of ten, so the slow end is as easy to set
/// as the fast one). It is not there when a real engine answers.
class DevSpeedControl extends ConsumerWidget {
  const DevSpeedControl({super.key});

  static const _lowest = 0.1;
  static const _highest = 5000.0;

  static double _speedAt(double v) => _lowest * pow(_highest / _lowest, v);
  static double _sliderAt(double speed) => log(speed / _lowest) / log(_highest / _lowest);

  static String label(double speed) => speed < 10 ? speed.toStringAsFixed(1) : speed.toStringAsFixed(0);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backend = ref.watch(backendProvider);
    if (backend is! DummyBackend) return const SizedBox.shrink();
    final c = context.colors;
    return LayoutBuilder(
      builder: (context, room) {
        // Short of room: the label goes first, then the slider gets shorter (never below 60).
        final withLabel = room.maxWidth >= 320;
        final slider = (room.maxWidth - 64 - (withLabel ? 80 : 0)).clamp(60.0, 170.0);
        return ValueListenableBuilder<double>(
          valueListenable: backend.speed,
          builder: (context, speed, _) => Row(mainAxisSize: MainAxisSize.min, children: [
            if (withLabel) Text('Test speed', style: TextStyle(fontSize: 12, color: c.textMuted)),
            SizedBox(
              width: slider,
              height: 30,
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3,
                  activeTrackColor: c.text,
                  inactiveTrackColor: c.switchTrack,
                  thumbColor: c.text,
                  overlayColor: c.text.withValues(alpha: 0.08),
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  key: const Key('dev-speed'),
                  value: _sliderAt(speed).clamp(0, 1),
                  onChanged: (v) => backend.speed.value = _speedAt(v),
                ),
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                '${label(speed)} tok/s',
                key: const Key('dev-speed-value'),
                maxLines: 1,
                style:
                    TextStyle(fontSize: 12, color: c.textSecondary, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
          ]),
        );
      },
    );
  }
}
