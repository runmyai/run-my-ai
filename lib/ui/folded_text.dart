import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme.dart';
import 'clicky.dart';

/// A sent message's text: longer than [lines] lines, it shows only its first [lines] (the last one fading out),
/// with an arrow under it that opens it to its full length (growing downwards) and folds it again.
class FoldedText extends StatelessWidget {
  const FoldedText({
    super.key,
    required this.text,
    required this.plain,
    required this.style,
    required this.open,
    required this.onToggle,
    this.arrowKey,
  });

  /// As many lines as the message box shows while typing.
  static const lines = 8;

  /// The text as shown (selectable, maybe with search marks), and as plain text, to tell whether it is long.
  final Widget text;
  final String plain;
  final TextStyle style;

  final bool open;
  final VoidCallback onToggle;
  final Key? arrowKey;

  /// Selectable text keeps this much room at the right for its cursor.
  static const _cursorRoom = 3.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final painter = TextPainter(
        text: TextSpan(text: plain, style: DefaultTextStyle.of(context).style.merge(style)),
        maxLines: lines,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: box.maxWidth - _cursorRoom);
      final long = painter.didExceedMaxLines;
      final folded = painter.height;
      final line = painter.preferredLineHeight;
      painter.dispose();
      if (!long) return text;
      final c = context.colors;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: ClipRect(
              child: ShaderMask(
                // Folded, the last line fades out.
                shaderCallback: (rect) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white, Colors.white, open ? Colors.white : Colors.white.withValues(alpha: 0)],
                  stops: [0, open ? 1 : ((rect.height - line) / rect.height).clamp(0.0, 1.0), 1],
                ).createShader(rect),
                blendMode: BlendMode.dstIn,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: open ? double.infinity : folded),
                  child: OverflowBox(
                    fit: OverflowBoxFit.deferToChild,
                    alignment: Alignment.topCenter,
                    maxHeight: double.infinity,
                    child: text,
                  ),
                ),
              ),
            ),
          ),
          Tooltip(
            message: open ? 'Show less' : 'Show more',
            waitDuration: const Duration(milliseconds: 400),
            excludeFromSemantics: true,
            child: Clicky(
              key: arrowKey,
              radius: 13,
              label: open ? 'Show less' : 'Show more',
              onTap: onToggle,
              child: SizedBox(
                width: 26,
                height: 26,
                child: AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  child: Icon(Icons.keyboard_arrow_down, size: 20, color: c.textSecondary),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}
