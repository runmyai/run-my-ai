import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../benchmark/benchmark.dart';
import '../../theme.dart';
import '../clicky.dart';
import 'chart_colors.dart';

/// Top-level Token Timeline Scrubber for the measured run.
/// Features:
/// - [Overall] button (selected by default on completion)
/// - Visual token bar chart spanning Token 1 to Token N with 1:1 unbiased clicking
/// - Fast tokens (< 0.85x median) in Blue, slow tokens (> 1.5x median) in Yellow, normal in Grey
/// - Stepper buttons [◀] and [▶]
/// - Direct editable number input [ 312 ] of N
/// - Live readout of the active token's ms and tokens/s
class TokenScrubber extends StatefulWidget {
  const TokenScrubber({
    super.key,
    required this.tokens,
    required this.overall,
    required this.picked,
    required this.onSelectOverall,
    required this.onPickToken,
  });

  final List<double> tokens;
  final bool overall;
  final int? picked;
  final VoidCallback onSelectOverall;
  final void Function(int index) onPickToken;

  @override
  State<TokenScrubber> createState() => _TokenScrubberState();
}

class _TokenScrubberState extends State<TokenScrubber> {
  int? _hover;
  late final TextEditingController _inputController;
  late final FocusNode _inputFocus;

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController(text: widget.picked == null ? '' : '${widget.picked! + 1}');
    _inputFocus = FocusNode();
  }

  @override
  void didUpdateWidget(TokenScrubber old) {
    super.didUpdateWidget(old);
    if (widget.overall) {
      if (_inputController.text.isNotEmpty && !_inputFocus.hasFocus) {
        _inputController.text = '';
      }
    } else if (widget.picked != old.picked) {
      final text = widget.picked == null ? '' : '${widget.picked! + 1}';
      if (_inputController.text != text && !_inputFocus.hasFocus) {
        _inputController.text = text;
      }
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _submitInput(String text) {
    final parsed = int.tryParse(text.trim());
    if (parsed == null || widget.tokens.isEmpty) return;
    final clamped = parsed.clamp(1, widget.tokens.length) - 1;
    widget.onPickToken(clamped);
    _inputController.text = '${clamped + 1}';
    _inputFocus.unfocus();
  }

  void _step(int delta) {
    if (widget.tokens.isEmpty) return;
    if (widget.overall || widget.picked == null) {
      widget.onPickToken(0);
      return;
    }
    final current = widget.picked!;
    final next = (current + delta).clamp(0, widget.tokens.length - 1);
    widget.onPickToken(next);
  }

  int _tokenAt(double dx, double width) {
    final tokens = widget.tokens;
    if (tokens.isEmpty || width <= 0) return 0;
    return (dx / width * tokens.length).floor().clamp(0, tokens.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tokens = widget.tokens;
    if (tokens.isEmpty) return const SizedBox.shrink();

    final overall = widget.overall;
    final picked = widget.picked;
    final typical = percentile(tokens, 0.5);
    final activeMillis = picked != null && picked >= 0 && picked < tokens.length ? tokens[picked] : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Control Bar: [ Overall ]  ·  [◀] Token [ 312 ] of N [▶]  (XX.X ms · YY.Y tok/s)
        Row(
          children: [
            Clicky(
              key: const Key('scrubber-overall'),
              onTap: widget.onSelectOverall,
              selected: overall,
              radius: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
                decoration: BoxDecoration(
                  color: overall ? c.selected : c.inputFill,
                  border: Border.all(color: overall ? c.textSecondary : c.inputBorder),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Overall',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: overall ? c.text : c.textMuted,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            // Stepper Prev [◀]
            _StepButton(
              key: const Key('scrubber-prev'),
              icon: Icons.chevron_left,
              enabled: !overall && picked != null && picked > 0,
              onTap: () => _step(-1),
            ),
            const SizedBox(width: 6),
            Text('Token ', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
            // Editable Number Input Box
            SizedBox(
              width: 54,
              height: 26,
              child: TextField(
                key: const Key('scrubber-input'),
                controller: _inputController,
                focusNode: _inputFocus,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: c.text,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                decoration: InputDecoration(
                  hintText: overall ? '–' : null,
                  contentPadding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                  filled: true,
                  fillColor: c.inputFill,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(5),
                    borderSide: BorderSide(color: c.inputBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(5),
                    borderSide: BorderSide(color: c.textSecondary),
                  ),
                ),
                onSubmitted: _submitInput,
                onTapOutside: (_) => _submitInput(_inputController.text),
              ),
            ),
            Text(' of ${tokens.length}', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
            const SizedBox(width: 6),
            // Stepper Next [▶]
            _StepButton(
              key: const Key('scrubber-next'),
              icon: Icons.chevron_right,
              enabled: tokens.isNotEmpty && (overall || (picked != null && picked < tokens.length - 1)),
              onTap: () => _step(1),
            ),
            if (!overall && activeMillis != null && activeMillis > 0) ...[
              const SizedBox(width: 12),
              Text(
                '(${activeMillis.toStringAsFixed(1)} ms · ${(1000.0 / activeMillis).toStringAsFixed(1)} tokens/s)',
                style: TextStyle(
                  fontSize: 12.5,
                  color: c.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),

        // Visual Token Bar Chart
        LayoutBuilder(
          builder: (context, box) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MouseRegion(
                cursor: SystemMouseCursors.click,
                onHover: (e) => setState(() => _hover = _tokenAt(e.localPosition.dx, box.maxWidth)),
                onExit: (_) => setState(() => _hover = null),
                child: GestureDetector(
                  key: const Key('tokens-chart'),
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => widget.onPickToken(_tokenAt(d.localPosition.dx, box.maxWidth)),
                  onHorizontalDragUpdate: (d) => widget.onPickToken(_tokenAt(d.localPosition.dx, box.maxWidth)),
                  child: SizedBox(
                    height: 80,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: _TokenBarsPainter(
                        tokens: tokens,
                        picked: overall ? null : picked,
                        hover: _hover,
                        bar: c.textMuted.withValues(alpha: 0.65),
                        slow: ChartColors.of(context, 2), // Yellow
                        fast: ChartColors.of(context, 0), // Blue
                        mark: c.text,
                        typical: typical,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                _hover == null
                    ? 'Token 1 to ${tokens.length} · Fast (< ${(typical * 0.85).round()} ms) in blue, slow (> ${(typical * 1.5).round()} ms) in yellow.'
                    : 'Token ${_hover! + 1}: ${tokens[_hover!].toStringAsFixed(1)} ms',
                style: TextStyle(
                  fontSize: 12,
                  color: c.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    super.key,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: enabled ? c.inputFill : c.inputFill.withValues(alpha: 0.4),
          border: Border.all(color: c.inputBorder),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(
          icon,
          size: 16,
          color: enabled ? c.text : c.textMuted.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

class _TokenBarsPainter extends CustomPainter {
  _TokenBarsPainter({
    required this.tokens,
    required this.picked,
    required this.hover,
    required this.bar,
    required this.slow,
    required this.fast,
    required this.mark,
    required this.typical,
  });

  final List<double> tokens;
  final int? picked;
  final int? hover;
  final Color bar;
  final Color slow;
  final Color fast;
  final Color mark;
  final double typical;

  @override
  void paint(Canvas canvas, Size size) {
    final top = math.max(percentile(tokens, 0.995) * 1.15, 1.0);
    final w = size.width, h = size.height;
    final columns = math.min(tokens.length, w.floor());
    if (columns <= 0) return;
    final each = w / columns;

    for (var i = 0; i < columns; i++) {
      final from = i * tokens.length ~/ columns;
      final to = math.max(from + 1, (i + 1) * tokens.length ~/ columns);
      var most = 0.0;
      var at = from;
      for (var k = from; k < to; k++) {
        if (tokens[k] > most) {
          most = tokens[k];
          at = k;
        }
      }
      final bh = math.max(1.0, h * (most / top).clamp(0.0, 1.0));
      final isPicked = picked != null && picked! >= from && picked! < to;
      final isHover = hover != null && hover! >= from && hover! < to;

      Color color;
      if (isPicked || isHover) {
        color = mark;
      } else if (tokens[at] > typical * 1.5) {
        color = slow;
      } else if (tokens[at] < typical * 0.85) {
        color = fast;
      } else {
        color = bar;
      }

      canvas.drawRect(
        Rect.fromLTWH(i * each, h - bh, math.max(1.0, each - (each > 3 ? 0.8 : 0)), bh),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_TokenBarsPainter old) =>
      !identical(old.tokens, tokens) ||
      old.picked != picked ||
      old.hover != hover ||
      old.bar != bar ||
      old.slow != slow ||
      old.fast != fast;
}
