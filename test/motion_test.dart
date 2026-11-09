// How a reply moves (lib/state/motion.dart): fixed to the look the user chose.
// Run: flutter test test/motion_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/state/motion.dart';

void main() {
  test('the look is the one chosen (Smooth, first called Crisp)', () {
    const m = Motion();
    expect((m.evenPace, m.momentum, m.reaction, m.softness), (true, true, 0.12, 0.5));
    expect((m.penTip, m.freshInk, m.inkSettle, m.startSlide, m.finishSettle), (false, true, 0.4, true, true));
    expect((m.inkCap, m.inkShade), (1.0, 0.85));
  });

  test('Raw (for demos) has no smoothing at all', () {
    expect((rawMotion.evenPace, rawMotion.momentum, rawMotion.softness, rawMotion.freshInk), (false, false, 0.0, false));
    expect((rawMotion.startSlide, rawMotion.finishSettle), (false, false));
    expect(smoothMotion == const Motion(), isTrue);
  });
}
