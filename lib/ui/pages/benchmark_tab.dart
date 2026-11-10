part of 'engine_page.dart';

/// The Benchmark tab, one page from top to bottom: the settings, the live view of a run, the full result of the run
/// that just ended, and the history. Each part keeps its detail behind a click.
class _BenchmarkTab extends ConsumerStatefulWidget {
  const _BenchmarkTab({required this.entry, required this.control});

  final CatalogEntry entry;
  final EngineControl control;

  @override
  ConsumerState<_BenchmarkTab> createState() => _BenchmarkTabState();
}

class _BenchmarkTabState extends ConsumerState<_BenchmarkTab> {
  /// A moment pinned on the graphs (a word clicked in the result).
  final _cursor = ValueNotifier<double?>(null);
  final _graphs = GlobalKey();

  @override
  void dispose() {
    _cursor.dispose();
    super.dispose();
  }

  void _showMoment(double seconds) {
    _cursor.value = seconds;
    final box = _graphs.currentContext;
    if (box != null) {
      unawaited(Scrollable.ensureVisible(box, duration: const Duration(milliseconds: 250), alignment: 0.02));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(benchmarkProvider);
    final notifier = ref.read(benchmarkProvider.notifier);
    final result = state.result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Panel(title: 'Settings', child: _BenchmarkSettings(entry: widget.entry, state: state)),
        _Panel(
          key: _graphs,
          title: 'Live',
          child: _LivePanel(state: state, control: widget.control, cursor: _cursor),
        ),
        if (result != null)
          _Panel(
            title: 'Full result',
            child: ResultView(result: result, others: state.history, onShowMoment: _showMoment),
          ),
        _Panel(
          title: 'History',
          child: state.history.isEmpty
              ? Text('Finished runs are kept here.', style: TextStyle(fontSize: 13, color: context.colors.textMuted))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final run in state.history)
                      HistoryRow(
                        key: ValueKey(run.id ?? run.at),
                        result: run,
                        others: state.history,
                        onDelete: () => notifier.delete(run),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// A part of the page: a quiet frame with a small heading.
class _Panel extends StatelessWidget {
  const _Panel({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.inputFill,
        border: Border.all(color: c.inputBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(fontSize: 11.5, letterSpacing: 0.8, fontWeight: FontWeight.w600, color: c.textMuted),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _BenchmarkSettings extends ConsumerWidget {
  const _BenchmarkSettings({required this.entry, required this.state});

  final CatalogEntry entry;
  final BenchmarkState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final notifier = ref.read(benchmarkProvider.notifier);
    final setup = state.setup;
    final replying = ref.watch(chatsProvider.select((s) => s.replyingId != null));
    final profiles = (ref.watch(profilesProvider), ref.read(profilesProvider.notifier)).$2.all(entry.file);
    final testing = setup.profileId == BenchmarkSetup.testProfileId;
    final profile = profiles.firstWhere((p) => p.id == setup.profileId, orElse: () => profiles.first);
    final options = profile.lengths;
    final length = testing ? contextOf(setup.testFlags) : closestContext(options, setup.contextLength);
    final problem = notifier.problem(entry.file, contextLength: length);
    final thinking = ref.watch(prefsProvider.select((p) => p.thinking));
    final busy = state.running;

    // A prompt that no longer fits the context falls back to the story chat.
    BenchmarkSetup fitted(BenchmarkSetup s, int? length) {
      final tokens = BenchmarkPrompt.byId(s.promptId).tokens;
      return tokens != null && length != null && !promptFits(tokens, s.replyLength, length) ? s.copyWith(promptId: BenchmarkPrompt.story.id) : s;
    }

    Widget group(String label, Widget child) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(label, style: TextStyle(fontSize: 12.5, color: c.textMuted))),
        child,
      ],
    );

    final flags = testing ? setup.testFlags : ref.read(profilesProvider.notifier).runWith(entry.file, setup.profileId, length ?? setup.contextLength).flags;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 28,
          runSpacing: 14,
          children: [
            group(
              'Profile',
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in profiles)
                    OptionPill(
                      label: p.name,
                      chosen: setup.profileId == p.id,
                      onTap: busy
                          ? null
                          : () {
                              final length = closestContext(p.lengths, setup.contextLength);
                              notifier.setSetup(fitted(setup.copyWith(profileId: p.id, contextLength: length), length));
                            },
                    ),
                  OptionPill(
                    key: const Key('benchmark-test-mode'),
                    label: 'Test mode',
                    chosen: testing,
                    onTap: busy ? null : () => notifier.setSetup(setup.copyWith(profileId: BenchmarkSetup.testProfileId)),
                  ),
                ],
              ),
            ),
            if (!testing)
              group(
                'Context length',
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final n in options)
                      OptionPill(
                        key: Key('benchmark-context-$n'),
                        label: contextLabel(n),
                        chosen: n == length,
                        onTap: busy ? null : () => notifier.setSetup(fitted(setup.copyWith(contextLength: n), n)),
                      ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        group(
          'Prompt',
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in BenchmarkPrompt.all)
                Builder(
                  builder: (context) {
                    final fits = p.tokens == null || length == null || promptFits(p.tokens!, setup.replyLength, length);
                    final pill = OptionPill(
                      key: Key('benchmark-prompt-${p.id}'),
                      label: p.label,
                      chosen: setup.promptId == p.id,
                      onTap: busy || !fits ? null : () => notifier.setSetup(setup.copyWith(promptId: p.id)),
                    );
                    return fits ? pill : Tooltip(message: 'This does not fit the context length.', child: pill);
                  },
                ),
            ],
          ),
        ),
        if (setup.promptId == BenchmarkPrompt.custom.id) ...[
          const SizedBox(height: 10),
          _TextBox(
            key: const Key('benchmark-custom-text'),
            text: setup.customText,
            hint: 'Your text, sent as the measured message',
            enabled: !busy,
            onChanged: (t) => notifier.setSetup(setup.copyWith(customText: t)),
          ),
        ] else if (BenchmarkPrompt.byId(setup.promptId).tokens != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Varied real text, cut to about ${contextLabel(BenchmarkPrompt.byId(setup.promptId).tokens!)} tokens as the engine counts them.',
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
          ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 28,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Longest reply', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                const SizedBox(width: 10),
                SizedBox(
                  width: 96,
                  child: _TextBox(
                    key: const Key('benchmark-reply-length'),
                    text: '${setup.replyLength}',
                    enabled: !busy,
                    onChanged: (t) {
                      final n = int.tryParse(t.trim());
                      if (n != null && n > 0) notifier.setSetup(fitted(setup.copyWith(replyLength: n), length));
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text('tokens at most; it stops sooner when the model stops', style: TextStyle(fontSize: 12, color: c.textMuted)),
                ),
              ],
            ),
            if (entry.model.thinking != ModelThinking.none)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ThinkingToggle(canChoose: entry.model.thinking == ModelThinking.optional),
                  const SizedBox(width: 6),
                  Text(
                    entry.model.thinking == ModelThinking.always
                        ? 'Thinking: always on for this model'
                        : 'Thinking: ${thinking ? 'on' : 'off'}',
                    key: const Key('benchmark-thinking'),
                    style: TextStyle(fontSize: 12.5, color: c.textSecondary),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 10),
        _Warmups(setup: setup, enabled: !busy, onChanged: (w) => notifier.setSetup(setup.copyWith(warmups: w))),
        if (testing) ...[
          const SizedBox(height: 10),
          group(
            'Flags to try (Test mode: nothing here is saved to a profile)',
            _TextBox(
              key: const Key('benchmark-test-flags'),
              text: setup.testFlags,
              hint: '-c 65536 --some-flag 1',
              mono: true,
              enabled: !busy,
              onChanged: (t) => notifier.setSetup(setup.copyWith(testFlags: t)),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 200,
            child: _TextBox(
              key: const Key('benchmark-test-cap'),
              text: setup.testMemoryCapGiB?.toString() ?? '',
              hint: 'Memory cap in GB',
              enabled: !busy,
              onChanged: (t) => notifier.setSetup(setup.copyWith(testMemoryCapGiB: () => double.tryParse(t.trim()))),
            ),
          ),
        ] else
          Fold(
            title: 'Flags (fixed here, edited in the Run tab)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(flags, style: TextStyle(fontSize: 12, height: 1.5, color: c.textSecondary, fontFamily: 'monospace')),
                const SizedBox(height: 6),
                AppButton(
                  key: const Key('benchmark-copy-flags'),
                  label: 'Copy flags',
                  dense: true,
                  onTap: () => Clipboard.setData(ClipboardData(text: flags)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            if (busy)
              AppButton(key: const Key('benchmark-stop'), label: 'Stop', onTap: notifier.stop)
            else
              MainButton(
                key: const Key('benchmark-start'),
                label: 'Start',
                onTap: replying || problem != null
                    ? null
                    : () => notifier.start(entry.file, entry.model.name, length ?? setup.contextLength, thinking: entry.model.thinking),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                busy
                    ? _phaseText(state)
                    : replying
                    ? 'A chat is replying. Wait for it to finish, or stop it.'
                    : problem ?? 'For accurate results, close other apps first.',
                style: TextStyle(fontSize: 13, color: !busy && problem != null ? c.danger : c.textMuted),
              ),
            ),
          ],
        ),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: SelectableText(state.error!, style: TextStyle(fontSize: 13, color: c.danger)),
          ),
      ],
    );
  }

  static String _phaseText(BenchmarkState state) {
    final progress = state.promptProgress;
    final read = progress == null ? '' : ' (${formatNumber(progress.$1.toDouble(), 0)} of ${formatNumber(progress.$2.toDouble(), 0)} tokens)';
    return switch (state.phase) {
      BenchmarkPhase.loading => 'Starting the engine and loading the model…',
      BenchmarkPhase.warmingUp => 'Warm-up ${state.warmup + 1} of ${state.setup.warmups.length}, not counted$read…',
      BenchmarkPhase.measuring =>
        state.replyWords == 0 ? 'Reading the prompt$read…' : 'Writing the reply: ${state.replyWords} tokens of at most ${state.setup.replyLength}…',
      BenchmarkPhase.idle => '',
    };
  }
}

/// A text box that keeps its own text while the user types.
class _TextBox extends StatefulWidget {
  const _TextBox({super.key, required this.text, required this.onChanged, this.hint, this.mono = false, this.enabled = true});

  final String text;
  final String? hint;
  final bool mono;
  final bool enabled;
  final void Function(String) onChanged;

  @override
  State<_TextBox> createState() => _TextBoxState();
}

class _TextBoxState extends State<_TextBox> {
  late final _text = TextEditingController(text: widget.text);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return TextField(
      controller: _text,
      enabled: widget.enabled,
      onChanged: widget.onChanged,
      minLines: 1,
      maxLines: 6,
      style: TextStyle(fontSize: 13, color: c.text, fontFamily: widget.mono ? 'monospace' : null),
      cursorColor: c.text,
      decoration: _boxDecoration(c, hint: widget.hint),
    );
  }
}

/// The warm-up messages, folded until opened.
class _Warmups extends StatelessWidget {
  const _Warmups({required this.setup, required this.enabled, required this.onChanged});

  final BenchmarkSetup setup;
  final bool enabled;
  final void Function(List<String>) onChanged;

  @override
  Widget build(BuildContext context) {
    final warmups = setup.warmups;
    return Fold(
      key: const Key('benchmark-warmups'),
      title: 'Warm-up: ${warmups.length} messages, not counted',
      hint: 'sent first, in the same conversation',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < warmups.length; i++)
            Padding(
              key: ValueKey('warmup-$i-${warmups.length}'),
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _TextBox(
                      text: warmups[i],
                      enabled: enabled,
                      onChanged: (t) => onChanged([...warmups]..[i] = t),
                    ),
                  ),
                  AppIconButton(
                    size: 24,
                    iconSize: 14,
                    radius: 6,
                    muted: true,
                    icon: Icons.close,
                    tooltip: 'Remove',
                    onTap: enabled ? () => onChanged([...warmups]..removeAt(i)) : null,
                  ),
                ],
              ),
            ),
          AppButton(label: '+ Add a message', dense: true, onTap: enabled ? () => onChanged([...warmups, '']) : null),
        ],
      ),
    );
  }
}

/// The run as it goes on: the four numbers that matter, what is happening, why the run is not fair if it is not, the
/// graphs and the engine's output. After the run the graphs stay as they were.
class _LivePanel extends StatelessWidget {
  const _LivePanel({required this.state, required this.control, required this.cursor});

  final BenchmarkState state;
  final EngineControl control;
  final ValueNotifier<double?> cursor;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final series = state.live;
    final result = state.result;
    double? last(String id) {
      final column = series?.series(id);
      if (column == null) return null;
      for (var i = column.length - 1; i >= 0; i--) {
        if (column[i] != null) return column[i];
      }
      return null;
    }

    String show(double? v, int digits) => v == null ? '–' : formatNumber(v, digits);
    final tiles = [
      ('TTFT', result != null ? (result.firstWordMillis / 1000).toStringAsFixed(2) : show(last('speed.ttft'), 2), 's'),
      ('Prompt processing', result != null ? formatNumber(result.promptTokensPerSecond, 0) : show(last('speed.prompt'), 0), 'tokens/s'),
      ('Generation speed', result != null ? result.tokensPerSecond.toStringAsFixed(1) : show(last('speed.words'), 1), 'tokens/s'),
      ('p99', result != null ? result.slowestOnePercent.toStringAsFixed(0) : '–', 'ms/token'),
    ];
    final hint = state.running
        ? null
        : state.note ?? (result != null ? 'Hover a graph for any moment. Click a line for its detail.' : 'Press Start. The graphs fill in while the run goes on.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final (name, value, unit) in tiles)
              Container(
                width: 170,
                padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                decoration: BoxDecoration(color: c.text.withValues(alpha: 0.04), borderRadius: BorderRadius.circular(10)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: c.text)),
                          TextSpan(text: ' $unit', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                        ],
                      ),
                      style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                    Text(name, style: TextStyle(fontSize: 12, color: c.textMuted)),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (hint != null) Text(hint, style: TextStyle(fontSize: 13, color: c.textMuted)),
        if (state.disturbed.isNotEmpty)
          for (final reason in state.disturbed)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('Disturbed: $reason', key: const Key('benchmark-disturbed'), style: TextStyle(fontSize: 13, color: c.danger)),
            ),
        const SizedBox(height: 12),
        if (series == null || series.isEmpty)
          Text(state.running ? 'Starting…' : '', style: TextStyle(fontSize: 13, color: c.textMuted))
        else
          LiveGraphs(
            series: series,
            revision: state.revision,
            cursor: cursor,
            counters: state.counters,
            running: state.running,
            gpuNames: state.hardware.gpus,
          ),
        if (state.running) Fold(title: 'Engine output', child: _Log(control: control)),
      ],
    );
  }
}
