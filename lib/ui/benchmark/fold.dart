import 'package:flutter/material.dart';

import '../../theme.dart';
import '../clicky.dart';

/// A heading that opens its content when clicked: the way the Benchmark tab keeps detail out of the first look (and
/// Settings its Storage and Folders).
class Fold extends StatefulWidget {
  const Fold({
    super.key,
    required this.title,
    required this.child,
    this.open = false,
    this.hint,
    this.titleStyle,
    this.tooltip,
  });

  final String title;
  final Widget child;

  /// Whether it starts open.
  final bool open;

  /// A few words after the title while it is closed.
  final String? hint;

  /// The title's look, when it is not the small grey one.
  final TextStyle? titleStyle;

  /// Shown when the pointer rests on the title.
  final String? tooltip;

  @override
  State<Fold> createState() => _FoldState();
}

class _FoldState extends State<Fold> {
  late var _open = widget.open;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _withTooltip(
            Clicky(
              key: Key('fold-${widget.title}'),
              onTap: () => setState(() => _open = !_open),
              radius: 6,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedRotation(
                      turns: _open ? 0 : -0.25,
                      duration: const Duration(milliseconds: 150),
                      child: Icon(Icons.keyboard_arrow_down, size: 16, color: c.textMuted),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: widget.title,
                              style: widget.titleStyle ?? TextStyle(fontSize: 13, color: c.textSecondary),
                            ),
                            if (!_open && widget.hint != null)
                              TextSpan(
                                text: '    ${widget.hint}',
                                style: TextStyle(fontSize: 12, color: c.textMuted),
                              ),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_open) Padding(padding: const EdgeInsets.fromLTRB(20, 6, 0, 10), child: widget.child),
        ],
      ),
    );
  }

  Widget _withTooltip(Widget title) => widget.tooltip == null ? title : Tooltip(message: widget.tooltip, child: title);
}
