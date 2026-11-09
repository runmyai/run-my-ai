import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How a reply moves while it is written. The defaults are the "Smooth" look, chosen after
/// comparing presets; Settings can switch to [raw] (no smoothing at all) to show the difference, until the app is
/// restarted.
class Motion {
  const Motion({
    this.evenPace = true,
    this.momentum = true,
    this.reaction = 0.12,
    this.softness = 0.5,
    this.penTip = false,
    this.freshInk = true,
    this.inkSettle = 0.4,
    this.inkCap = 1,
    this.inkShade = 0.85,
    this.startSlide = true,
    this.finishSettle = true,
  });

  /// The pieces of the reply come out evenly over the moments between them (off: each shows as it arrives).
  final bool evenPace;

  /// The edge speeds up and eases off smoothly, reaching the text's pace within [reaction] seconds.
  final bool momentum;
  final double reaction;

  /// How far ahead of the edge the next letters show, fading out (in letters; 0 = a sharp edge).
  final double softness;

  /// A small dot rides the edge, and pulses gently while the reply pauses.
  final bool penTip;

  /// The text just written is a little lighter ([inkShade] of the normal colour, 1 = normal) and settles to normal
  /// over [inkSettle] seconds; never more than [inkCap] letters at once, however fast the reply comes.
  final bool freshInk;
  final double inkSettle;
  final double inkCap;
  final double inkShade;

  /// The reply's first line slides in; at the end, the edge and its touches fade out instead of stopping at once.
  final bool startSlide;
  final bool finishSettle;
}

/// The two looks Settings offers: what replies normally do, and no smoothing at all (each piece shows as it
/// arrives, with a sharp edge).
const smoothMotion = Motion();
const rawMotion = Motion(
  evenPace: false,
  momentum: false,
  softness: 0,
  freshInk: false,
  startSlide: false,
  finishSettle: false,
);

/// The look replies use now (Settings → Reply motion); not saved, so the app always starts with Smooth.
class MotionNotifier extends Notifier<Motion> {
  @override
  Motion build() => smoothMotion;

  void set(Motion motion) => state = motion;
}

final motionProvider = NotifierProvider<MotionNotifier, Motion>(MotionNotifier.new);
