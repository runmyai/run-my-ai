import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/backend.dart';
import '../engine/commands.dart';
import '../state/library.dart';
import '../state/profiles.dart';
import '../state/providers.dart';
import '../state/serve.dart';
import '../theme.dart';
import 'buttons.dart';
import 'select_box.dart';

/// The title bar's Serve button: opens the panel for hosting a model for other programs. It shows that hosting is on.
class ServeButton extends ConsumerWidget {
  const ServeButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(backendProvider) is! ServeControl) {
      return const SizedBox.shrink();
    }
    final hosting = ref.watch(serveProvider.select((s) => s.phase != ServePhase.idle));
    void open() => showDialog<void>(context: context, builder: (_) => const ServePanel());
    return hosting
        ? OptionPill(key: const Key('serve-button'), label: 'Hosting', chosen: true, onTap: open)
        : AppButton(key: const Key('serve-button'), label: 'Serve', icon: Icons.dns_outlined, dense: true, onTap: open);
  }
}

/// Pick a model, its context length, a port and an optional key, then Host it; shows what another program needs to
/// use it as a custom OpenAI-compatible provider.
class ServePanel extends ConsumerStatefulWidget {
  const ServePanel({super.key});

  @override
  ConsumerState<ServePanel> createState() => _ServePanelState();
}

class _ServePanelState extends ConsumerState<ServePanel> {
  late final _port = TextEditingController(text: '${ref.read(serveProvider).port}');
  late final _key = TextEditingController(text: ref.read(serveProvider).apiKey);
  String? _modelId;
  int? _context;

  @override
  void dispose() {
    _port.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final serve = ref.watch(serveProvider);
    ref.watch(profilesProvider);
    final files = ref.watch(catalogFilesProvider);
    final downloaded = [for (final id in ref.watch(libraryProvider.select((l) => l.downloaded))) ?files[id]];
    final shown = ref.watch(shownModelProvider);
    final entry = serve.hosted != null
        ? files[serve.hosted!.modelId]
        : downloaded.where((e) => e.file.id == _modelId).firstOrNull ??
              downloaded.where((e) => e.file.id == shown?.file.id).firstOrNull ??
              downloaded.firstOrNull;
    final lengths = entry == null ? const <int>[] : ref.read(profilesProvider.notifier).active(entry.file).lengths;
    final length =
        serve.hosted?.contextLength ??
        (lengths.isEmpty
            ? null
            : closestContext(lengths, _context ?? ref.watch(libraryProvider.select((l) => l.contextLength))));
    final port = serve.hosted?.port ?? int.tryParse(_port.text.trim());
    final idle = serve.phase == ServePhase.idle;
    final alias = entry == null ? '' : serveAlias(entry.model);
    final key = serve.hosted != null ? serve.hosted!.apiKey ?? '' : _key.text.trim();

    InputDecoration decoration() => InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: c.inputBorder),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: c.inputBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: c.text.withValues(alpha: 0.35)),
      ),
    );

    Widget row(String label, Widget field) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: TextStyle(fontSize: 13, color: c.textSecondary)),
          ),
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: field),
          ),
        ],
      ),
    );

    // A value another program needs, with a button that copies it.
    Widget copyRow(String id, String label, String value) => row(
      label,
      Row(
        children: [
          Expanded(
            child: SelectableText(
              value,
              key: Key('serve-show-$id'),
              style: TextStyle(fontSize: 13, color: c.text),
            ),
          ),
          AppIconButton(
            key: Key('serve-copy-$id'),
            size: 26,
            iconSize: 14,
            radius: 6,
            muted: true,
            icon: Icons.copy_outlined,
            tooltip: 'Copy',
            onTap: () => Clipboard.setData(ClipboardData(text: value)),
          ),
        ],
      ),
    );

    // (Not an AlertDialog: it measures its content before laying it out, which a select box cannot answer.)
    return Dialog(
      backgroundColor: c.page,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                serve.hosting && entry != null ? 'Hosting ${entry.model.name}' : 'Serve a model',
                key: const Key('serve-title'),
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: c.text),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Lets other apps on this computer use the model. In any tool that takes a custom OpenAI-compatible provider, '
                        'add the address, the model name and the key below. Chatting here is paused while it is hosted.',
                        style: TextStyle(fontSize: 13, height: 1.4, color: c.textMuted),
                      ),
                      const SizedBox(height: 16),
                      if (entry == null)
                        Text(
                          'Download a model from the Store first.',
                          key: const Key('serve-no-model'),
                          style: TextStyle(fontSize: 13, color: c.textMuted),
                        )
                      else ...[
                        row(
                          'Model',
                          SelectBox<String>(
                            id: 'serve-model',
                            label: 'Model',
                            value: entry.file.id,
                            entries: [
                              for (final e in downloaded)
                                SelectEntry(
                                  id: e.file.id,
                                  value: e.file.id,
                                  label: '${e.model.name} (${e.file.quantization})',
                                ),
                            ],
                            onChanged: idle ? (id) => setState(() => _modelId = id) : null,
                            width: 320,
                          ),
                        ),
                        row(
                          'Context length',
                          SelectBox<int>(
                            id: 'serve-context',
                            label: 'Context length',
                            value: length!,
                            entries: [for (final n in lengths) SelectEntry(id: '$n', value: n, label: contextLabel(n))],
                            onChanged: idle ? (n) => setState(() => _context = n) : null,
                            width: 320,
                          ),
                        ),
                        row(
                          'Port',
                          SizedBox(
                            width: 120,
                            child: TextField(
                              key: const Key('serve-port'),
                              controller: _port,
                              enabled: idle,
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                              onChanged: (text) {
                                final n = int.tryParse(text.trim());
                                if (validPort(n)) {
                                  ref.read(serveProvider.notifier).setPort(n!);
                                }
                                setState(() {});
                              },
                              style: TextStyle(fontSize: 13, color: c.text),
                              cursorColor: c.text,
                              decoration: decoration(),
                            ),
                          ),
                        ),
                        row(
                          'API key',
                          SizedBox(
                            width: 320,
                            child: TextField(
                              key: const Key('serve-key'),
                              controller: _key,
                              enabled: idle,
                              onChanged: (text) {
                                ref.read(serveProvider.notifier).setApiKey(text);
                                setState(() {});
                              },
                              style: TextStyle(fontSize: 13, color: c.text),
                              cursorColor: c.text,
                              decoration: decoration().copyWith(
                                hintText: 'Optional',
                                hintStyle: TextStyle(color: c.textMuted),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (validPort(port)) copyRow('endpoint', 'Address', 'http://127.0.0.1:$port/v1'),
                        copyRow('model', 'Model name', alias),
                        copyRow('key', 'API key', key.isEmpty ? 'any text' : key),
                      ],
                      if (!validPort(port) && idle)
                        Text(
                          'The port must be a number from 1 to 65535.',
                          key: const Key('serve-port-error'),
                          style: TextStyle(fontSize: 13, color: c.danger),
                        ),
                      if (serve.phase == ServePhase.starting)
                        Text(
                          'Loading the model…',
                          key: const Key('serve-loading'),
                          style: TextStyle(fontSize: 13, color: c.textMuted),
                        ),
                      if (serve.error != null)
                        SelectableText(
                          serve.error!,
                          key: const Key('serve-error'),
                          style: TextStyle(fontSize: 13, height: 1.4, color: c.danger),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  AppButton(key: const Key('serve-close'), label: 'Close', onTap: () => Navigator.pop(context)),
                  if (idle)
                    MainButton(
                      key: const Key('serve-host'),
                      label: 'Host',
                      onTap: entry == null || !validPort(port) || length == null
                          ? null
                          : () => ref.read(serveProvider.notifier).host(entry, length),
                    )
                  else
                    MainButton(
                      key: const Key('serve-stop'),
                      label: 'Stop',
                      danger: true,
                      onTap: ref.read(serveProvider.notifier).stop,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
