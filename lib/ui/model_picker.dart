import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/commands.dart';
import '../state/chats.dart';
import '../state/library.dart';
import '../state/providers.dart';
import '../state/section.dart';
import '../theme.dart';
import 'clicky.dart';
import 'menu_panel.dart';

/// The model picker at the top of the chat: only downloaded models.
class ModelPicker extends ConsumerWidget {
  const ModelPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final library = ref.watch(libraryProvider);
    final files = ref.watch(catalogFilesProvider);
    final picked = ref.watch(shownModelProvider);
    final downloaded = [for (final id in library.downloaded) ?files[id]];
    void toStore() => ref.read(sectionProvider.notifier).select(Section.store);

    if (picked == null) {
      return _Lift(
        onTap: toStore,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.storefront_outlined, size: 18, color: c.text),
          const SizedBox(width: 8),
          Text('Get a model from the Store', style: TextStyle(fontSize: 14, color: c.text)),
        ]),
      );
    }

    final modelMenu = MenuAnchor(
      style: bareMenuStyle,
      clipBehavior: Clip.none,
      menuChildren: [
        MenuPanel(
          color: c.inputFill,
          border: c.inputBorder,
          elevation: 2,
          shadowColor: Theme.of(context).shadowColor,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            for (final e in downloaded)
              MenuItemButton(
                onPressed: () => ref.read(chatsProvider.notifier).pickModel(e.file.id),
                trailingIcon: e.file.id == picked.file.id ? Icon(Icons.check, size: 16, color: c.text) : null,
                child: _Label(name: e.model.name, quantization: e.file.quantization),
              ),
            const Divider(height: 1),
            MenuItemButton(
              onPressed: toStore,
              child: Text('Get more in the Store', style: TextStyle(fontSize: 14, color: c.textSecondary)),
            ),
          ],
        ),
      ],
      builder: (context, menu, _) => _Lift(
        raised: menu.isOpen,
        onTap: () => menu.isOpen ? menu.close() : menu.open(),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _Label(name: picked.model.name, quantization: picked.file.quantization, bold: true),
          const SizedBox(width: 4),
          Icon(Icons.keyboard_arrow_down, size: 18, color: c.textMuted),
        ]),
      ),
    );
    return Row(mainAxisSize: MainAxisSize.min, children: [modelMenu, const SizedBox(width: 4), const _ContextPicker()]);
  }
}

/// The context length of the chat, next to the model: only the lengths the model can run with.
class _ContextPicker extends ConsumerWidget {
  const _ContextPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final shown = ref.watch(shownContextProvider);
    if (shown == null) return const SizedBox.shrink();
    return MenuAnchor(
      style: bareMenuStyle,
      clipBehavior: Clip.none,
      menuChildren: [
        MenuPanel(
          color: c.inputFill,
          border: c.inputBorder,
          elevation: 2,
          shadowColor: Theme.of(context).shadowColor,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            for (final length in shown.options)
              MenuItemButton(
                key: Key('context-$length'),
                onPressed: () => ref.read(chatsProvider.notifier).pickContext(length),
                trailingIcon: length == shown.value ? Icon(Icons.check, size: 16, color: c.text) : null,
                child: SizedBox(
                  width: 56,
                  child: Text(contextLabel(length), style: TextStyle(fontSize: 14, color: c.text)),
                ),
              ),
          ],
        ),
      ],
      builder: (context, menu, _) => _Lift(
        key: const Key('context-picker'),
        raised: menu.isOpen,
        onTap: () => menu.isOpen ? menu.close() : menu.open(),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(contextLabel(shown.value), style: TextStyle(fontSize: 14, color: c.textSecondary)),
          const SizedBox(width: 4),
          Icon(Icons.keyboard_arrow_down, size: 18, color: c.textMuted),
        ]),
      ),
    );
  }
}

/// The picker's button: plain at rest; under the pointer (and while its list is open, [raised]) it lifts at once
/// into a small raised surface, square-ish, with a clear fill and a very faint, short shadow.
class _Lift extends StatelessWidget {
  const _Lift({super.key, required this.onTap, required this.child, this.raised = false});

  final VoidCallback onTap;
  final Widget child;
  final bool raised;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Clicky.builder(
      key: const Key('picker'),
      onTap: onTap,
      builder: (context, s) {
        final up = s.hovered || s.pressed || raised;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: up
              ? BoxDecoration(
                  color: s.pressed ? c.rowPressed : c.rowHover,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(color: c.shadow.withValues(alpha: c.shadow.a * 0.3), blurRadius: 5, offset: const Offset(0, 1.5)),
                    BoxShadow(color: c.shadow.withValues(alpha: c.shadow.a * 0.25), blurRadius: 1, offset: const Offset(0, 0.5)),
                  ],
                )
              : null,
          child: child,
        );
      },
    );
  }
}

class _Label extends StatelessWidget {
  const _Label({required this.name, required this.quantization, this.bold = false});

  final String name;
  final String quantization;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text.rich(TextSpan(children: [
      TextSpan(
        text: name,
        style: TextStyle(fontSize: 14, color: c.text, fontWeight: bold ? FontWeight.w500 : FontWeight.w400),
      ),
      TextSpan(text: '  $quantization', style: TextStyle(fontSize: 13, color: c.textMuted)),
    ]));
  }
}
