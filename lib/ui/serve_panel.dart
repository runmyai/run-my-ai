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

/// The title bar's Serve button: opens the Serve page, for hosting a model for other programs.
class ServeButton extends ConsumerWidget {
  const ServeButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(backendProvider) is! ServeControl) {
      return const SizedBox.shrink();
    }
    return AppButton(
      key: const Key('serve-button'),
      label: 'Serve',
      icon: Icons.dns_outlined,
      dense: true,
      onTap: ref.read(serveProvider.notifier).openPage,
    );
  }
}

/// The whole window while it is open: first the setup (model, context length, port, API key, Host) with Back to the
/// app; while the model loads and while it is hosted, what is hosted, how other programs connect, what it is doing
/// now and the totals since hosting started, with Stop hosting. Nothing else of the app is reachable meanwhile, so
/// nothing can start, stop or swap the engine. When hosting ends, on its own or by Stop hosting, the setup comes back
/// and says why.
class ServePage extends ConsumerWidget {
  const ServePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final busy = ref.watch(serveProvider.select((s) => s.busy));
    void back() => ref.read(serveProvider.notifier).closePage();
    return Scaffold(
      backgroundColor: c.page,
      body: CallbackShortcuts(
        bindings: {if (!busy) const SingleActivator(LogicalKeyboardKey.escape): back},
        child: Focus(
          autofocus: true,
          child: Column(
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
                  padding: const EdgeInsets.fromLTRB(40, 12, 40, 40),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: busy ? const _Status() : _Setup(onBack: back),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

TextStyle _titleStyle(AppColors c) => TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: c.text);

TextStyle _bodyStyle(AppColors c) => TextStyle(fontSize: 14, height: 1.5, color: c.textSecondary);

/// The key as dots, as long as it is (up to a row's worth).
String _dots(String key) => '•' * key.length.clamp(8, 32);

Widget _copyButton(String key, String value) => AppIconButton(
  key: Key(key),
  size: 28,
  iconSize: 15,
  radius: 6,
  muted: true,
  icon: Icons.copy_outlined,
  tooltip: 'Copy',
  onTap: () => Clipboard.setData(ClipboardData(text: value)),
);

/// Pick a model, its context length, a port and a key, then Host it.
class _Setup extends ConsumerStatefulWidget {
  const _Setup({required this.onBack});

  final VoidCallback onBack;

  @override
  ConsumerState<_Setup> createState() => _SetupState();
}

class _SetupState extends ConsumerState<_Setup> {
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
    final error = ref.watch(serveProvider.select((s) => s.error));
    ref.watch(profilesProvider);
    final files = ref.watch(catalogFilesProvider);
    final downloaded = [for (final id in ref.watch(libraryProvider.select((l) => l.downloaded))) ?files[id]];
    final shown = ref.watch(shownModelProvider);
    final entry =
        downloaded.where((e) => e.file.id == _modelId).firstOrNull ??
        downloaded.where((e) => e.file.id == shown?.file.id).firstOrNull ??
        downloaded.firstOrNull;
    final lengths = entry == null ? const <int>[] : ref.read(profilesProvider.notifier).active(entry.file).lengths;
    final length = lengths.isEmpty
        ? null
        : closestContext(lengths, _context ?? ref.watch(libraryProvider.select((l) => l.contextLength)));
    final port = int.tryParse(_port.text.trim());
    final key = _key.text.trim();

    InputDecoration decoration() => InputDecoration(
      isDense: true,
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

    Widget row(String label, Widget field) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: TextStyle(fontSize: 14, color: c.textSecondary)),
          ),
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: field),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppButton(
          key: const Key('serve-back'),
          label: 'Back',
          icon: Icons.arrow_back_rounded,
          dense: true,
          onTap: widget.onBack,
        ),
        const SizedBox(height: 16),
        Text('Serve a model', key: const Key('serve-title'), style: _titleStyle(c)),
        const SizedBox(height: 8),
        Text(
          'Lets other apps on this computer use a model. In any tool that takes a custom OpenAI-compatible provider, '
          'add the address, the model name and the API key shown once it is hosted. The rest of the app comes back '
          'when you stop hosting.',
          style: _bodyStyle(c),
        ),
        const SizedBox(height: 24),
        if (error != null) ...[
          SelectableText(
            error,
            key: const Key('serve-error'),
            style: TextStyle(fontSize: 14, height: 1.5, color: c.danger),
          ),
          const SizedBox(height: 16),
        ],
        if (entry == null)
          Text(
            'Download a model from the Store first.',
            key: const Key('serve-no-model'),
            style: TextStyle(fontSize: 14, color: c.textMuted),
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
                  SelectEntry(id: e.file.id, value: e.file.id, label: '${e.model.name} (${e.file.quantization})'),
              ],
              onChanged: (id) => setState(() => _modelId = id),
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
              onChanged: (n) => setState(() => _context = n),
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
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (text) {
                  final n = int.tryParse(text.trim());
                  if (validPort(n)) ref.read(serveProvider.notifier).setPort(n!);
                  setState(() {});
                },
                style: TextStyle(fontSize: 14, color: c.text),
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
                // Never shown: typed blindly, generated, or copied with the button.
                Expanded(
                  child: TextField(
                    key: const Key('serve-key'),
                    controller: _key,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    onChanged: (text) {
                      ref.read(serveProvider.notifier).setApiKey(text);
                      setState(() {});
                    },
                    style: TextStyle(fontSize: 14, color: c.text),
                    cursorColor: c.text,
                    decoration: decoration(),
                  ),
                ),
                if (validApiKey(key)) _copyButton('serve-copy-key', key),
                AppButton(
                  key: const Key('serve-generate'),
                  label: 'Generate',
                  dense: true,
                  onTap: () {
                    final generated = generateApiKey();
                    _key.text = generated;
                    ref.read(serveProvider.notifier).setApiKey(generated);
                    setState(() {});
                  },
                ),
              ],
            ),
          ),
          if (!validApiKey(key))
            Padding(
              padding: const EdgeInsets.only(left: 130, bottom: 12),
              child: Text(
                key.isEmpty
                    ? 'Set an API key: other apps use it to connect.'
                    : 'Use letters, digits and signs only, without spaces, commas or quotes.',
                key: const Key('serve-key-note'),
                style: TextStyle(fontSize: 13, color: key.isEmpty ? c.textMuted : c.danger),
              ),
            ),
          if (!validPort(port))
            Padding(
              padding: const EdgeInsets.only(left: 130, bottom: 12),
              child: Text(
                'The port must be a number from 1 to 65535.',
                key: const Key('serve-port-error'),
                style: TextStyle(fontSize: 13, color: c.danger),
              ),
            ),
        ],
        const SizedBox(height: 16),
        MainButton(
          key: const Key('serve-host'),
          label: 'Host',
          onTap: entry == null || !validPort(port) || length == null || !validApiKey(key)
              ? null
              : () => ref.read(serveProvider.notifier).host(entry, length),
        ),
      ],
    );
  }
}

/// What is hosted (or loading), how other programs connect, what it does now, the totals, and Stop hosting.
class _Status extends ConsumerWidget {
  const _Status();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final serve = ref.watch(serveProvider);
    final hosted = serve.hosted;
    if (hosted == null) return const SizedBox.shrink();
    final loading = !serve.hosting;
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

    // A value another program needs, with a button that copies it ([shown] in its place on screen).
    Widget copyRow(String id, String label, String value, {String? shown}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: TextStyle(fontSize: 14, color: c.textSecondary)),
          ),
          Expanded(
            child: shown != null
                ? Text(shown, key: Key('hosting-show-$id'), style: TextStyle(fontSize: 14, color: c.text))
                : SelectableText(value, key: Key('hosting-show-$id'), style: TextStyle(fontSize: 14, color: c.text)),
          ),
          _copyButton('hosting-copy-$id', value),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(loading ? 'Loading $name…' : '$name is hosted', key: const Key('hosting-title'), style: _titleStyle(c)),
        const SizedBox(height: 8),
        Text(
          loading
              ? 'Other apps can connect with the details below once it is loaded. Context length '
                    '${contextLabel(hosted.contextLength)}.'
              : 'Other apps on this computer can use it as a custom OpenAI-compatible provider with the details '
                    'below. Context length ${contextLabel(hosted.contextLength)}. The rest of the app comes back when '
                    'you stop hosting.',
          style: _bodyStyle(c),
        ),
        const SizedBox(height: 24),
        if (!loading) ...[
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
        ],
        card(
          'Connection',
          Column(
            children: [
              copyRow('endpoint', 'Address', 'http://127.0.0.1:${hosted.port}/v1'),
              copyRow('model', 'Model name', hosted.alias),
              copyRow('key', 'API key', hosted.apiKey, shown: _dots(hosted.apiKey)),
            ],
          ),
        ),
        if (!loading) ...[
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
        ],
        const SizedBox(height: 28),
        MainButton(
          key: const Key('hosting-stop'),
          label: 'Stop hosting',
          danger: true,
          onTap: ref.read(serveProvider.notifier).stop,
        ),
      ],
    );
  }
}
