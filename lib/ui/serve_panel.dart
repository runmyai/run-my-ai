import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/backend.dart';
import '../benchmark/metrics.dart';
import '../engine/commands.dart';
import '../state/library.dart';
import '../state/profiles.dart';
import '../state/providers.dart';
import '../state/serve.dart';
import '../theme.dart';
import 'buttons.dart';
import 'select_box.dart';
import 'title_bar.dart';

/// The title bar's Serve button: opens the panel for hosting a model for other programs. It shows that hosting is on.
class ServeButton extends ConsumerWidget {
  const ServeButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(backendProvider) is! ServeControl) {
      return const SizedBox.shrink();
    }
    // Hosting only once the model is loaded; while it loads the panel says so.
    final hosting = ref.watch(serveProvider.select((s) => s.hosting));
    void open() => showDialog<void>(context: context, builder: (_) => const ServePanel());
    return hosting
        ? OptionPill(key: const Key('serve-button'), label: 'Hosting', chosen: true, onTap: open)
        : AppButton(key: const Key('serve-button'), label: 'Serve', icon: Icons.dns_outlined, dense: true, onTap: open);
  }
}

/// Pick a model, its context length, a port and a key, then Host it; shows what another program needs to use it as a
/// custom OpenAI-compatible provider. Once the model is loaded the hosting screen takes the window and this closes.
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
    ref.listen(serveProvider.select((s) => s.hosting), (_, hosting) {
      if (hosting) Navigator.pop(context);
    });
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
    final key = serve.hosted != null ? serve.hosted!.apiKey : _key.text.trim();

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
                          Row(
                            spacing: 8,
                            children: [
                              Expanded(
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
                                  decoration: decoration(),
                                ),
                              ),
                              AppButton(
                                key: const Key('serve-generate'),
                                label: 'Generate',
                                dense: true,
                                onTap: idle
                                    ? () {
                                        final generated = generateApiKey();
                                        _key.text = generated;
                                        ref.read(serveProvider.notifier).setApiKey(generated);
                                        setState(() {});
                                      }
                                    : null,
                              ),
                            ],
                          ),
                        ),
                        if (!validApiKey(key))
                          Padding(
                            padding: const EdgeInsets.only(left: 110, bottom: 10),
                            child: Text(
                              key.isEmpty
                                  ? 'Set an API key: other apps use it to connect.'
                                  : 'Use letters, digits and signs only, without spaces, commas or quotes.',
                              key: const Key('serve-key-note'),
                              style: TextStyle(fontSize: 12.5, color: key.isEmpty ? c.textMuted : c.danger),
                            ),
                          ),
                        const SizedBox(height: 6),
                        if (validPort(port)) copyRow('endpoint', 'Address', 'http://127.0.0.1:$port/v1'),
                        copyRow('model', 'Model name', alias),
                        if (validApiKey(key)) copyRow('key', 'API key', key),
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
                      onTap: entry == null || !validPort(port) || length == null || !validApiKey(key)
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

/// The whole window while a model is hosted: what is hosted, how other programs connect, what it is doing now, the
/// totals since hosting started, and Stop hosting. Nothing else of the app is reachable, so nothing can start, stop or
/// swap the engine meanwhile.
class HostingScreen extends ConsumerWidget {
  const HostingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final hosted = ref.watch(serveProvider.select((s) => s.hosted));
    if (hosted == null) return const SizedBox.shrink();
    final stats = ref.watch(hostStatsProvider);
    final name = ref.watch(catalogFilesProvider)[hosted.modelId]?.model.name ?? hosted.alias;

    Widget card(String title, Widget child) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.text.withValues(alpha: 0.035),
        border: Border.all(color: c.text.withValues(alpha: 0.08)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textSecondary),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );

    // A value another program needs, with a button that copies it.
    Widget copyRow(String id, String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: TextStyle(fontSize: 14, color: c.textSecondary)),
          ),
          Expanded(
            child: SelectableText(
              value,
              key: Key('hosting-show-$id'),
              style: TextStyle(fontSize: 14, color: c.text),
            ),
          ),
          AppIconButton(
            key: Key('hosting-copy-$id'),
            size: 28,
            iconSize: 15,
            radius: 6,
            muted: true,
            icon: Icons.copy_outlined,
            tooltip: 'Copy',
            onTap: () => Clipboard.setData(ClipboardData(text: value)),
          ),
        ],
      ),
    );

    Widget total(String id, String label, int value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatNumber(value.toDouble(), 0),
            key: Key('hosting-total-$id'),
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: c.text),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 13, color: c.textMuted)),
        ],
      ),
    );

    final (status, speedLabel) = switch (stats.activity) {
      HostActivity.idle => ('Idle', 'Waiting for a request'),
      HostActivity.reading => ('Reading prompt…', 'prompt speed'),
      HostActivity.writing => ('Writing…', 'writing speed'),
    };
    final active = stats.activity != HostActivity.idle;

    return Scaffold(
      backgroundColor: c.page,
      body: Column(
        children: [
          WindowDragArea(
            child: SizedBox(
              height: titleBarHeight,
              child: Row(
                children: [const Spacer(), if (!isMacLook) const WindowButtons() else const SizedBox(width: 8)],
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$name is hosted',
                        key: const Key('hosting-title'),
                        style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: c.text),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Other apps on this computer can use it as a custom OpenAI-compatible provider with the details '
                        'below. Context length ${contextLabel(hosted.contextLength)}. The rest of the app comes back '
                        'when you stop hosting.',
                        style: TextStyle(fontSize: 14.5, height: 1.5, color: c.textSecondary),
                      ),
                      const SizedBox(height: 24),
                      card(
                        'Now',
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              margin: const EdgeInsets.only(right: 8, bottom: 7),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: active ? c.text : c.textMuted.withValues(alpha: 0.6),
                              ),
                            ),
                            Text(
                              status,
                              key: const Key('hosting-status'),
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500, color: c.text),
                            ),
                            const Spacer(),
                            if (active)
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    stats.speed == null ? '–' : '${formatNumber(stats.speed!, 1)} tokens/s',
                                    key: const Key('hosting-speed'),
                                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: c.text),
                                  ),
                                  Text(speedLabel, style: TextStyle(fontSize: 13, color: c.textMuted)),
                                ],
                              )
                            else
                              Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: Text(speedLabel, style: TextStyle(fontSize: 13, color: c.textMuted)),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      card(
                        'Connection',
                        Column(
                          children: [
                            copyRow('endpoint', 'Address', 'http://127.0.0.1:${hosted.port}/v1'),
                            copyRow('model', 'Model name', hosted.alias),
                            copyRow('key', 'API key', hosted.apiKey),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      card(
                        'Since hosting started',
                        Row(
                          children: [
                            total('requests', 'Requests served', stats.requests),
                            total('generated', 'Tokens generated', stats.generated),
                            total('prompt', 'Prompt tokens read', stats.promptRead),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                      Center(
                        child: MainButton(
                          key: const Key('hosting-stop'),
                          label: 'Stop hosting',
                          danger: true,
                          onTap: ref.read(serveProvider.notifier).stop,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
