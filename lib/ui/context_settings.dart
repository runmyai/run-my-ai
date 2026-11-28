import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/commands.dart';
import '../state/prefs.dart';
import '../state/profiles.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'buttons.dart';
import 'clicky.dart';
import 'menu_panel.dart';
import 'model_picker.dart';

/// A context length the KV cache picker lists.
class _ContextNode {
  const _ContextNode({required this.tokens, required this.label});

  final int tokens;
  final String label;
}

const _contextLengths = [
  _ContextNode(tokens: 4096, label: '4k'),
  _ContextNode(tokens: 8192, label: '8k'),
  _ContextNode(tokens: 16384, label: '16k'),
  _ContextNode(tokens: 32768, label: '32k'),
  _ContextNode(tokens: 65536, label: '65k'),
  _ContextNode(tokens: 100000, label: '100k'),
  _ContextNode(tokens: 131072, label: '131k'),
  _ContextNode(tokens: 200000, label: '200k'),
  _ContextNode(tokens: 262144, label: '262k'),
];

/// Calculates the exact KV cache memory size based on model architecture and quantization format.
String _calculateKvCacheSize({required String modelName, required int tokens, required String quant}) {
  final isFlint = modelName.toLowerCase().contains('flint');
  final double bpe = switch (quant.toLowerCase()) {
    'fp16' => 2.0,
    'q4_0' => 18.0 / 32.0, // 0.5625 bytes per element
    _ => 34.0 / 32.0, // 1.0625 bytes per element (Q8_0)
  };

  final double totalBytes;
  if (isFlint) {
    // Flint-40B: 49 layers total (14 full-attention, 35 sliding window attention).
    // Full-attention layers: 14 layers x 2 (K+V) x 4 heads x 128 dim = 14,336 elements/token.
    // Sliding-window layers: 35 layers x 2 (K+V) x 4 heads x 128 dim = 35,840 elements/cell.
    // SWA cell buffer is padded in llama-kv-cache-iswa: GGML_PAD(n_swa + n_ubatch, 256) = PAD(513 + 2048, 256) = 2,816 cells.
    const fullElemPerTok = 14 * 2 * 4 * 128; // 14,336 elem/tok
    const swaFixedCells = 2816; // GGML_PAD(513 + 2048, 256)
    const swaElemPerCell = 35 * 2 * 4 * 128; // 35,840 elem/cell
    totalBytes = (tokens * fullElemPerTok + swaFixedCells * swaElemPerCell) * bpe;
  } else {
    // Ling-3.0-flash: 8 MLA layers (K-only latent + decoupled rope, V absorbed) x 576 dim = 4,608 elem/tok.
    // Recurrent state for 35 linear layers is fixed at ~11 MB independent of context tokens.
    const elemPerTok = 8 * 576;
    const recurrentFixedBytes = 11.0 * 1024 * 1024;
    totalBytes = (tokens * elemPerTok * bpe) + recurrentFixedBytes;
  }

  if (totalBytes >= 1024 * 1024 * 1024) {
    return '${(totalBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  } else {
    return '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// The KV cache quantization picker: for each context length, the type the context cache (KV cache) is stored in, with
/// its memory (saved per model; applies the next time the model loads at that length). Which length a chat runs with
/// is chosen in the chat window's picker, not here.
class ContextSettings extends ConsumerWidget {
  const ContextSettings({super.key, required this.entry});

  final CatalogEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final kv = ref.watch(profilesProvider)[entry.file.id]?.kv ?? const <int, String>{};

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      decoration: BoxDecoration(
        color: c.inputFill,
        border: Border.all(color: c.inputBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Center(
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: c.selected,
                border: Border.all(color: c.inputBorder),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const ModelPicker(showContext: false),
            ),
          ),
          const SizedBox(height: 28),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final node in _contextLengths)
                Expanded(
                  child: _ContextColumn(
                    node: node,
                    quant: kv[node.tokens] ?? 'q8_0',
                    modelName: entry.model.name,
                    onSelectQuant: (q) => ref.read(profilesProvider.notifier).setKv(entry.file, node.tokens, q),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The graphics card memory (VRAM) left free on one card ([card]: its key), with Save and Reset.
class VramHeadroomInput extends ConsumerStatefulWidget {
  const VramHeadroomInput({super.key, required this.card});

  final String card;

  @override
  ConsumerState<VramHeadroomInput> createState() => _VramHeadroomInputState();
}

class _VramHeadroomInputState extends ConsumerState<VramHeadroomInput> {
  static String _show(double gib) => gib == gib.roundToDouble() ? '${gib.round()}' : '$gib';

  double _current(WidgetRef ref) => ref.read(prefsProvider).vramHeadroomSetting.of(widget.card);

  late final _text = TextEditingController(text: _show(_current(ref)));
  String? _problem;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final gib = double.tryParse(_text.text.trim());
    if (gib == null || !gib.isFinite || gib <= 0) {
      setState(() => _problem = 'Enter a number of GB (e.g. 0.5 or 1).');
      return;
    }
    ref.read(prefsProvider.notifier).setVramHeadroom(widget.card, gib);
    setState(() {
      _problem = null;
      // (A value under the minimum shows as the minimum it was raised to.)
      _text.text = _show(_current(ref));
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final current = ref.watch(prefsProvider.select((p) => p.vramHeadroomSetting.of(widget.card)));
    final dirty = _text.text.trim() != _show(current);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 160,
              child: TextField(
                key: Key('vram-headroom-${widget.card}'),
                controller: _text,
                onChanged: (_) => setState(() => _problem = null),
                style: TextStyle(fontSize: 13, color: c.text),
                cursorColor: c.text,
                decoration: _boxDecoration(c, hint: '$defaultVramHeadroomGiB'),
              ),
            ),
            const SizedBox(width: 8),
            Text('GB', style: TextStyle(fontSize: 13, color: c.textMuted)),
            if (dirty) ...[
              const SizedBox(width: 12),
              MainButton(key: Key('vram-headroom-save-${widget.card}'), label: 'Save', onTap: _save),
              const SizedBox(width: 6),
              AppButton(
                key: Key('vram-headroom-reset-${widget.card}'),
                label: 'Reset',
                onTap: () => setState(() {
                  _text.text = _show(current);
                  _problem = null;
                }),
              ),
            ],
          ],
        ),
        if (_problem != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_problem!, style: TextStyle(fontSize: 13, color: c.danger)),
          ),
      ],
    );
  }
}

/// One context length: its name, its KV cache type (a drop-down) and the memory the cache takes at that type.
class _ContextColumn extends StatelessWidget {
  const _ContextColumn({required this.node, required this.quant, required this.modelName, required this.onSelectQuant});

  final _ContextNode node;
  final String quant;
  final String modelName;
  final ValueChanged<String> onSelectQuant;

  static const _quantOptions = [
    (id: 'q4_0', name: 'Efficient', tag: 'Q4_0', desc: 'Lowest RAM consumption'),
    (id: 'q8_0', name: 'Balanced', tag: 'Q8_0', desc: '50% compared to FP16, near-lossless'),
    (id: 'f16', name: 'Full Quality', tag: 'F16', desc: 'Maximum precision'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final size = _calculateKvCacheSize(modelName: modelName, tokens: node.tokens, quant: quant);
    final quantItem = _quantOptions.firstWhere((q) => q.id == quant, orElse: () => _quantOptions[1]);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(node.label, style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
        ),
        // Dropdown for Quantization
        MenuAnchor(
          style: bareMenuStyle,
          alignmentOffset: const Offset(0, 4),
          menuChildren: [
            MenuPanel(
              color: c.inputFill,
              border: c.inputBorder,
              elevation: 2,
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                for (final opt in _quantOptions)
                  MenuItemButton(
                    onPressed: () => onSelectQuant(opt.id),
                    trailingIcon: opt.id == quant ? Icon(Icons.check, size: 14, color: c.text) : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${opt.name} (${opt.tag})',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: opt.id == quant ? FontWeight.w600 : FontWeight.w500,
                                  color: c.text,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                _calculateKvCacheSize(modelName: modelName, tokens: node.tokens, quant: opt.id),
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.textSecondary),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(opt.desc, style: TextStyle(fontSize: 11, color: c.textMuted)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
          builder: (context, menu, _) => Clicky.builder(
            key: Key('kv-${node.tokens}'),
            onTap: () => menu.isOpen ? menu.close() : menu.open(),
            builder: (context, state) {
              final active = state.hovered || menu.isOpen;
              return Container(
                height: 32,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: state.hovered ? c.buttonHoverFill : c.inputFill,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: state.hovered ? c.buttonHoverBorder : c.inputBorder),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      quantItem.tag,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: active ? c.text : c.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.keyboard_arrow_down, size: 14, color: active ? c.text : c.textMuted),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        // Memory footprint size
        Text(size, style: TextStyle(fontSize: 11, color: c.textMuted)),
      ],
    );
  }
}

InputDecoration _boxDecoration(AppColors c, {String? hint}) => InputDecoration(
  isDense: true,
  hintText: hint,
  hintStyle: TextStyle(color: c.textMuted),
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(color: c.inputBorder),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(color: c.text.withValues(alpha: 0.35)),
  ),
);
