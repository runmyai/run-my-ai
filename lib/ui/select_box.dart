import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'clicky.dart';
import 'menu_panel.dart';

/// One entry of a [SelectBox]. A disabled entry is listed but cannot be chosen; its [reason], when it has one, is
/// written beside it.
class SelectEntry<T> {
  const SelectEntry({required this.id, required this.value, required this.label, this.enabled = true, this.reason});

  /// Names the entry's widget (`<box id>-<id>`), for tests.
  final String id;
  final T value;
  final String label;
  final bool enabled;
  final String? reason;
}

/// A drop-down for choosing one of a few entries, drawn like the app's text boxes (the same height, corners, border
/// and colours). A click, Enter or Space opens the list, with the chosen entry (or the first one that can be chosen)
/// ready; the arrow keys move in it, Enter chooses and Escape closes, and the focus goes back to the box. Without
/// [onChanged] it is greyed out. It is [width] wide, or as wide as its place when that is narrower.
class SelectBox<T> extends StatefulWidget {
  const SelectBox({
    super.key,
    required this.id,
    required this.label,
    required this.value,
    required this.entries,
    required this.onChanged,
    this.width = 260,
  });

  /// The box's own key is `Key(id)`; its entries' are `Key('<id>-<entry id>')`.
  final String id;

  /// What a screen reader says the box is.
  final String label;
  final T value;
  final List<SelectEntry<T>> entries;
  final ValueChanged<T>? onChanged;
  final double width;

  /// The height of the app's text boxes: a line of text and their padding.
  static const height = 40.0;

  @override
  State<SelectBox<T>> createState() => _SelectBoxState<T>();
}

class _SelectBoxState<T> extends State<SelectBox<T>> {
  /// The box itself, and each entry (by its place in the list), so that the list can be entered and left with the
  /// keyboard.
  final _box = FocusNode(debugLabel: 'select box');
  final _entryNodes = <int, FocusNode>{};

  FocusNode _node(int i) => _entryNodes.putIfAbsent(i, () => FocusNode(debugLabel: 'select entry $i'));

  @override
  void dispose() {
    _box.dispose();
    for (final node in _entryNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Puts the focus into the opened list: on the chosen entry, else on the first one that can be chosen.
  void _enterList() {
    final entries = widget.entries;
    var at = entries.indexWhere((e) => e.value == widget.value && e.enabled);
    if (at < 0) at = entries.indexWhere((e) => e.enabled);
    if (at < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _node(at).requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final entries = widget.entries;
    final chosen = entries.where((e) => e.value == widget.value).firstOrNull;
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxWidth = math.min(widget.width, constraints.maxWidth);
        return MenuAnchor(
          style: bareMenuStyle,
          clipBehavior: Clip.none,
          alignmentOffset: const Offset(0, 4),
          childFocusNode: _box,
          onOpen: _enterList,
          menuChildren: [
            MenuPanel(
              color: c.inputFill,
              border: c.inputBorder,
              elevation: 2,
              shadowColor: Theme.of(context).shadowColor,
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                for (var i = 0; i < entries.length; i++)
                  MenuItemButton(
                    key: Key('${widget.id}-${entries[i].id}'),
                    focusNode: _node(i),
                    onPressed: entries[i].enabled ? () => widget.onChanged?.call(entries[i].value) : null,
                    trailingIcon: entries[i] == chosen ? Icon(Icons.check, size: 16, color: c.text) : null,
                    style: ButtonStyle(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      minimumSize: WidgetStatePropertyAll(Size(boxWidth, 34)),
                      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(entries[i].label, style: TextStyle(fontSize: 13, color: entries[i].enabled ? c.text : c.disabledText)),
                        if (entries[i].reason != null) ...[
                          const SizedBox(width: 12),
                          Text(entries[i].reason!, style: TextStyle(fontSize: 12, color: c.disabledText)),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ],
          builder: (context, menu, _) => Clicky.builder(
            key: Key(widget.id),
            focusNode: _box,
            label: widget.label,
            onTap: widget.onChanged == null ? null : () => menu.isOpen ? menu.close() : menu.open(),
            builder: (context, s) {
              final Color border;
              if (!s.enabled) {
                border = c.disabledBorder;
              } else if (menu.isOpen) {
                border = c.text.withValues(alpha: 0.35);
              } else {
                border = s.hovered ? c.buttonHoverBorder : c.inputBorder;
              }
              return Container(
                width: boxWidth,
                height: SelectBox.height,
                padding: const EdgeInsets.only(left: 12, right: 8),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(border: Border.all(color: border), borderRadius: BorderRadius.circular(8)),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        chosen?.label ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: s.enabled ? c.text : c.disabledText),
                      ),
                    ),
                    Icon(Icons.keyboard_arrow_down, size: 18, color: s.enabled ? c.textMuted : c.disabledText),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
