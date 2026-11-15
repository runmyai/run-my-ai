import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../benchmark/benchmark.dart';
import '../../engine/commands.dart';
import '../../theme.dart';
import '../buttons.dart';
import '../clicky.dart';
import 'live_graphs.dart';
import 'result_view.dart';

/// One past run as a compact row: the model, profile, context, prompt, reply speed and date. A click opens its full
/// result with the graphs it was made with; the row also has Copy flags and Delete.
class HistoryRow extends StatefulWidget {
  const HistoryRow({super.key, required this.result, required this.others, required this.onDelete});

  final BenchmarkResult result;

  /// The runs it can be compared with (the whole history).
  final List<BenchmarkResult> others;
  final VoidCallback onDelete;

  @override
  State<HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<HistoryRow> {
  var _open = false;
  var _sure = false;
  Timer? _unsure;
  final _cursor = ValueNotifier<double?>(null);
  final _graphs = GlobalKey();

  @override
  void dispose() {
    _unsure?.cancel();
    _cursor.dispose();
    super.dispose();
  }

  void _delete() {
    // (A second click within a few seconds: a run is not deleted by one slip.)
    if (_sure) return widget.onDelete();
    setState(() => _sure = true);
    _unsure = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _sure = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = widget.result;
    String two(int n) => n.toString().padLeft(2, '0');
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final date = '${r.at.day} ${months[r.at.month - 1]} ${two(r.at.hour)}:${two(r.at.minute)}';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
      decoration: BoxDecoration(
        border: Border.all(color: _open ? c.inputBorder : c.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Clicky(
                  key: Key('history-${r.id ?? r.at.millisecondsSinceEpoch}'),
                  onTap: () => setState(() => _open = !_open),
                  radius: 6,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Icon(_open ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, size: 16, color: c.textMuted),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            '${r.modelName}  ·  ${r.profileName}  ·  ${contextLabel(r.contextLength)}  ·  ${r.promptLabel}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: c.textSecondary),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(date, style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 92,
                          child: Text(
                            '${r.tokensPerSecond.toStringAsFixed(1)} tokens/s',
                            textAlign: TextAlign.end,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.text, fontFeatures: const [FontFeature.tabularFigures()]),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AppIconButton(
                key: Key('history-copy-${r.id ?? r.at.millisecondsSinceEpoch}'),
                size: 26,
                iconSize: 14,
                radius: 6,
                muted: true,
                icon: Icons.copy_outlined,
                tooltip: 'Copy flags',
                onTap: () => Clipboard.setData(ClipboardData(text: r.flags)),
              ),
              if (_sure)
                AppButton(
                  key: Key('history-delete-${r.id ?? r.at.millisecondsSinceEpoch}'),
                  label: 'Delete this run',
                  danger: true,
                  dense: true,
                  onTap: _delete,
                )
              else
                AppIconButton(
                  key: Key('history-delete-${r.id ?? r.at.millisecondsSinceEpoch}'),
                  size: 26,
                  iconSize: 15,
                  radius: 6,
                  muted: true,
                  icon: Icons.delete_outline,
                  tooltip: 'Delete',
                  onTap: _delete,
                ),
            ],
          ),
          if (_open) ...[
            const SizedBox(height: 8),
            if (r.series != null) ...[
              Container(
                key: _graphs,
                child: LiveGraphs(series: r.series!, cursor: _cursor, gpuNames: r.environment.hardware.gpus),
              ),
              const SizedBox(height: 14),
            ],
            ResultView(
              result: r,
              others: widget.others,
              onShowMoment: r.series == null
                  ? null
                  : (t) {
                      _cursor.value = t;
                      final box = _graphs.currentContext;
                      if (box != null) unawaited(Scrollable.ensureVisible(box, duration: const Duration(milliseconds: 250), alignment: 0.05));
                    },
            ),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}
