part of 'engine_page.dart';

/// The parts of the benchmark, one on screen at a time.
enum _View { setup, live, history }

/// The Benchmark tab as steps: the setup, the live view of a run (which keeps the whole result of the run once it has
/// ended), and the history beside them. The stepper on top switches; the setup is the only door into a run. Each part
/// keeps its detail behind a click.
class _BenchmarkTab extends ConsumerStatefulWidget {
  const _BenchmarkTab({required this.entry, required this.control});

  final CatalogEntry entry;
  final EngineControl control;

  @override
  ConsumerState<_BenchmarkTab> createState() => _BenchmarkTabState();
}

class _BenchmarkTabState extends ConsumerState<_BenchmarkTab> {
  /// A moment pinned on the graphs (a token clicked in the charts under them).
  final _cursor = ValueNotifier<double?>(null);

  /// The part on screen; chosen from the state the first time it is built.
  _View? _view;

  /// The part that was on screen before History was opened; History toggles back to it.
  _View? _beforeHistory;

  /// Where a step click goes: into History remembers the way back, out of it uses and clears it.
  void _go(_View v) {
    if (v == _View.history && _view != _View.history) {
      _beforeHistory = _view;
    } else if (v != _View.history) {
      _beforeHistory = null;
    }
    setState(() => _view = v);
  }

  @override
  void dispose() {
    _cursor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(benchmarkProvider);
    final notifier = ref.read(benchmarkProvider.notifier);
    final result = state.result;
    // Where the tab opens: in the run while it goes on, at its result when one is here, at the setup otherwise.
    _view ??= state.running || result != null ? _View.live : _View.setup;
    // A view that its step no longer allows is left at once (a run was cleared under us).
    final canLive = state.running || result != null || state.live != null;
    if (_view == _View.live && !canLive) _view = _View.setup;

    // The run itself moves the tab: starting it shows it, and its end keeps it there with the whole run's numbers — or
    // shows the setup when it stopped or failed without a result.
    ref.listen<BenchmarkState>(benchmarkProvider, (before, after) {
      if (after.running && !(before?.running ?? false)) {
        setState(() => _view = _View.live);
      } else if ((before?.running ?? false) && !after.running) {
        setState(() => _view = after.result != null ? _View.live : _View.setup);
      }
    });

    final view = _view!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Steps(
          current: view,
          running: state.running,
          canSetup: !state.running,
          canLive: canLive,
          hasResult: result != null,
          onGo: _go,
          onHistory: () => _go(_view == _View.history ? (_beforeHistory ?? _View.setup) : _View.history),
        ),
        const SizedBox(height: 14),
        switch (view) {
          _View.live => _Panel(
            title: 'Live',
            child: _LivePanel(state: state, control: widget.control, cursor: _cursor),
          ),
          _View.history => _Panel(
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
          // The setup is one small panel, with no heading: the step above it is called Setup.
          _ => Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _setupWidth),
              child: _Panel(key: const Key('benchmark-setup'), child: _BenchmarkSettings(entry: widget.entry, state: state)),
            ),
          ),
        },
      ],
    );
  }
}

/// The stepper at the top of the tab: the two steps and History beside them. The step on screen is lit; a step not
/// reached yet is locked, with the reason under it; a passed step keeps its check. The setup is the only way into a
/// run.
class _Steps extends StatelessWidget {
  const _Steps({
    required this.current,
    required this.running,
    required this.canSetup,
    required this.canLive,
    required this.hasResult,
    required this.onGo,
    required this.onHistory,
  });

  final _View current;
  final bool running;
  final bool canSetup;
  final bool canLive;
  final bool hasResult;
  final void Function(_View) onGo;
  final void Function() onHistory;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // A step: its circle, its label and, when it is locked, why. The circle is lit for the step on screen, checked
    // for a passed one, and faint for a locked one.
    Widget step(
      String name,
      _View view, {
      required bool enabled,
      required String? sub,
      Key? key,
    }) {
      final isCurrent = current == view;
      final passed = switch (view) {
        _View.setup => !running,
        _View.live => hasResult,
        _View.history => false,
      };
      final circleColor = isCurrent ? c.text : passed ? c.textSecondary : c.textMuted;
      // A step is a button: a bordered pill that shows the hand (hover) and the press, lit while it is the one
      // on screen, quiet when locked.
      return InkWell(
        key: key,
        onTap: enabled && !isCurrent ? () => onGo(view) : null,
        borderRadius: BorderRadius.circular(9),
        hoverColor: c.rowHover,
        splashColor: c.rowHover,
        highlightColor: c.rowHover,
        child: Opacity(
          opacity: enabled ? 1 : 0.55,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: isCurrent ? c.selected : c.inputFill,
              border: Border.all(color: isCurrent ? c.textSecondary : c.inputBorder),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: isCurrent ? c.text : c.inputBorder, width: isCurrent ? 2 : 1.2),
                  ),
                  child: passed && !isCurrent
                      ? Icon(Icons.check, size: 14, color: circleColor)
                      : Text('${_View.values.indexOf(view) + 1}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: circleColor)),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                        color: enabled ? c.text : c.textMuted,
                      ),
                    ),
                    if (sub != null) Text(sub, style: TextStyle(fontSize: 10.5, color: c.textMuted)),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget link(bool done) => Expanded(child: Container(height: 1.5, color: done ? c.textMuted : c.inputBorder));

    return Row(
      children: [
        step('Setup', _View.setup, key: const Key('bench-step-1'), enabled: canSetup, sub: running ? 'stop the run to change' : null),
        link(hasResult),
        step('Live', _View.live, key: const Key('bench-step-2'), enabled: canLive, sub: canLive ? null : 'start a run first'),
        const SizedBox(width: 18),
        InkWell(
          key: const Key('bench-history'),
          onTap: onHistory,
          borderRadius: BorderRadius.circular(9),
          hoverColor: c.rowHover,
          splashColor: c.rowHover,
          highlightColor: c.rowHover,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
            decoration: BoxDecoration(
              color: current == _View.history ? c.selected : c.inputFill,
              border: Border.all(color: c.inputBorder),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.history, size: 15, color: c.textSecondary),
                const SizedBox(width: 6),
                Text('History', style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A part of the page: a quiet frame, with a small heading when it has a [title].
class _Panel extends StatelessWidget {
  const _Panel({super.key, this.title, required this.child});

  final String? title;
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
          if (title != null) ...[
            Text(
              title!.toUpperCase(),
              style: TextStyle(fontSize: 11.5, letterSpacing: 0.8, fontWeight: FontWeight.w600, color: c.textMuted),
            ),
            const SizedBox(height: 12),
          ],
          child,
        ],
      ),
    );
  }
}

/// How wide the setup panel is at most.
const _setupWidth = 560.0;

/// The setup: three choices, a line on what the test does, and Start.
class _BenchmarkSettings extends ConsumerWidget {
  const _BenchmarkSettings({required this.entry, required this.state});

  final CatalogEntry entry;
  final BenchmarkState state;

  /// The width of the labels' column, so that every label starts at one edge and every box at another.
  static const _labelWidth = 130.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final notifier = ref.read(benchmarkProvider.notifier);
    final setup = state.setup;
    final replying = ref.watch(chatsProvider.select((s) => s.replyingId != null));
    ref.watch(profilesProvider);
    // A run always uses the model's automatic preset, at the chosen context length.
    final presets = ref.read(profilesProvider.notifier).auto(entry.file).lengths;
    final length = contextChoice(presets, setup.contextLength);
    final problem = notifier.problem(contextLength: length);
    final busy = state.running;
    final library = ref.watch(libraryProvider);
    final files = ref.watch(catalogFilesProvider);
    final downloaded = [for (final id in library.downloaded) ?files[id]];
    final modelEntries = [
      for (final e in downloaded)
        SelectEntry(id: e.file.id, value: e.file.id, label: '${e.model.name}  ${e.file.quantization}'),
    ];
    if (!modelEntries.any((e) => e.value == entry.file.id)) {
      modelEntries.insert(
        0,
        SelectEntry(id: entry.file.id, value: entry.file.id, label: '${entry.model.name}  ${entry.file.quantization}'),
      );
    }

    Widget row(String label, Widget box) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(
            width: _labelWidth,
            child: Text(label, style: TextStyle(fontSize: 13, color: c.textSecondary)),
          ),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: box)),
        ],
      ),
    );

    final String status;
    final Color statusColor;
    if (busy) {
      (status, statusColor) = (_phaseText(state), c.textMuted);
    } else if (replying) {
      (status, statusColor) = ('A chat is replying. Wait for it to finish, or stop it.', c.danger);
    } else if (problem != null) {
      (status, statusColor) = (problem, c.danger);
    } else {
      (status, statusColor) = ('Close other apps for accurate results.', c.textMuted);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row(
          'Model',
          SelectBox<String>(
            id: 'benchmark-model',
            label: 'Model',
            value: entry.file.id,
            entries: modelEntries,
            onChanged: busy ? null : (id) => ref.read(chatsProvider.notifier).pickModel(id),
          ),
        ),
        row(
          'Context length',
          SelectBox<int>(
            id: 'benchmark-context',
            label: 'Context length',
            value: length,
            entries: [
              for (final n in presets) SelectEntry(id: '$n', value: n, label: contextLabel(n)),
            ],
            onChanged: busy ? null : (n) => notifier.setSetup(setup.copyWith(contextLength: n)),
          ),
        ),
        row(
          'KV cache',
          // A placeholder for now: the choice is kept and shown, and the run does not use it (every preset runs q8_0).
          SelectBox<KvCache>(
            id: 'benchmark-kv',
            label: 'KV cache',
            value: setup.kvCache,
            entries: [for (final k in KvCache.all) SelectEntry(id: k.id, value: k, label: k.label)],
            onChanged: busy ? null : (k) => notifier.setSetup(setup.copyWith(kvCache: k)),
          ),
        ),
        row(
          'Test',
          SelectBox<BenchmarkTest>(
            id: 'benchmark-test',
            label: 'Test',
            value: setup.test,
            entries: [
              for (final t in BenchmarkTest.all)
                SelectEntry(
                  id: t.id,
                  value: t,
                  label: t.label,
                  enabled: t.fits(length),
                  reason: t.fits(length) ? null : 'Needs a longer context',
                ),
            ],
            onChanged: busy ? null : (t) => notifier.setSetup(setup.copyWith(test: t)),
          ),
        ),
        Text(setup.test.description, key: const Key('benchmark-test-line'), style: TextStyle(fontSize: 12.5, color: c.textMuted)),
        Container(margin: const EdgeInsets.symmetric(vertical: 16), height: 1, color: c.inputBorder),
        Row(
          children: [
            Expanded(
              child: Text(status, key: const Key('benchmark-status'), style: TextStyle(fontSize: 13, color: statusColor)),
            ),
            const SizedBox(width: 16),
            if (busy)
              AppButton(key: const Key('benchmark-stop'), label: 'Stop', onTap: notifier.stop)
            else
              MainButton(
                key: const Key('benchmark-start'),
                label: 'Start',
                onTap: replying || problem != null
                    ? null
                    : () => notifier.start(entry.file, entry.model.name, length, thinking: entry.model.thinking),
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
      BenchmarkPhase.warmingUp => 'Warm-up ${state.warmup + 1} of ${state.setup.warmups.length}$read…',
      BenchmarkPhase.measuring =>
        state.replyTokens == 0 ? 'Reading the prompt$read…' : 'Writing the reply: ${state.replyTokens} tokens of at most ${state.setup.replyLength}…',
      BenchmarkPhase.idle => '',
    };
  }
}

/// The run as it goes on and after it: the turns, the four numbers that matter, what is happening, the graphs and the
/// engine's output. The turn tabs pick the turn: the current one live, finished ones frozen with their own real numbers
/// and, under the graphs, their details — the user can go back to an earlier turn, and the view follows the run
/// otherwise. Each turn has its own graphs (its stretch of the run); the tab before the turns is the whole run. When a run
/// ends the whole run is shown, with every number taken over all the turns together, the turns side by side, and the
/// folds of the run (its phases, memory layout, hardware, setup and engine output).
class _LivePanel extends StatefulWidget {
  const _LivePanel({required this.state, required this.control, required this.cursor});

  final BenchmarkState state;
  final EngineControl control;
  final ValueNotifier<double?> cursor;

  @override
  State<_LivePanel> createState() => _LivePanelState();
}

class _LivePanelState extends State<_LivePanel> {
  bool _overall = false;
  int? _pickedToken;

  @override
  void initState() {
    super.initState();
    _overall = !widget.state.running;
    _pickedToken = null;
  }

  @override
  void didUpdateWidget(_LivePanel old) {
    super.didUpdateWidget(old);
    final (before, now) = (old.state, widget.state);
    if (!before.running && now.running) {
      _overall = false;
      _pickedToken = null;
      widget.cursor.value = null;
    } else if (before.running && !now.running && now.result != null) {
      _overall = true;
      _pickedToken = null;
      widget.cursor.value = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = widget.state;
    final series = state.live;
    final result = state.result;
    final turns = state.turns.isNotEmpty ? state.turns : (result?.turns ?? const <TurnRecord>[]);
    final total = state.setup.warmups.length + 1;
    final liveIndex = state.running ? turns.length.clamp(0, total - 1) : -1;
    final measuredTurn = turns.isNotEmpty ? turns.lastWhere((t) => !t.warmup, orElse: () => turns.last) : null;
    final whole = !state.running && measuredTurn != null ? WholeRun([measuredTurn]) : (!state.running && turns.isNotEmpty ? WholeRun(turns) : null);
    final tokens = measuredTurn != null && measuredTurn.tokens.isNotEmpty
        ? measuredTurn.tokens
        : (result?.tokens ?? const <double>[]);

    final String turnTitle = liveIndex == 0
        ? 'Warm-up 1'
        : liveIndex == 1
        ? 'Warm-up 2'
        : 'Benchmark Run';

    final bool isOverall = !state.running && _overall;
    final activeTokenMillis = !isOverall && _pickedToken != null && _pickedToken! < tokens.length
        ? tokens[_pickedToken!]
        : null;

    final hint = state.note ?? (!state.running && result == null ? 'Press Start. The graphs fill in while the run goes on.' : null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hint != null) ...[
          Text(hint, style: TextStyle(fontSize: 12.5, color: c.textMuted)),
          const SizedBox(height: 12),
        ],

        // In-place live header during run
        if (state.running) ...[
          Row(
            children: [
              Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Text(turnTitle, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.text)),
              if (state.replyTokens > 0) ...[
                const SizedBox(width: 12),
                Text('Writing reply: ${state.replyTokens} tokens…', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
              ] else ...[
                const SizedBox(width: 12),
                Text('Reading prompt…', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
              ],
            ],
          ),
          const SizedBox(height: 12),
        ],

        // After run finishes: TokenScrubber at the top
        if (!state.running && tokens.isNotEmpty) ...[
          TokenScrubber(
            tokens: tokens,
            overall: isOverall,
            picked: _pickedToken,
            onSelectOverall: () {
              setState(() {
                _overall = true;
                _pickedToken = null;
              });
              widget.cursor.value = null;
            },
            onPickToken: (index) {
              setState(() {
                _overall = false;
                _pickedToken = index;
              });
              final at = measuredTurn != null ? turnTokenSeconds(measuredTurn, index) : (result != null ? tokenTimeSeconds(result, index) : null);
              if (at != null) {
                widget.cursor.value = at;
              }
            },
          ),
          const SizedBox(height: 14),
        ],

        // Metric Cards (Speed, GPUs, CPU, RAM, SSD, Engine)
        if (series == null || series.isEmpty)
          Text(state.running ? 'Starting…' : '', style: TextStyle(fontSize: 13, color: c.textMuted))
        else
          MetricCards(
            series: series,
            rows: metricRows(series, gpuNames: state.hardware.gpus),
            cursor: isOverall ? null : widget.cursor.value,
            overall: isOverall,
            whole: isOverall ? whole : null,
            activeTokenMillis: activeTokenMillis,
          ),

        // Under the cards when run has ended:
        if (!state.running && whole != null) ...[
          // 1. Where the time per token went (Turn 3 only)
          if (measuredTurn != null) ...[
            Builder(
              builder: (context) {
                final parts = timeParts(measuredTurn.engineStats);
                final totalMs = measuredTurn.replyTokens > 0 ? measuredTurn.replyMillis / measuredTurn.replyTokens : 0.0;
                if (!hasTimeSplit(parts) || totalMs <= 0) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 18),
                    const SectionLabel('Where the time per token went'),
                    TimePerToken(total: totalMs, parts: parts),
                  ],
                );
              },
            ),
          ],

          // 2. The Run Facts (Load time, Cache hits, Misses, SSD wait, Correct guesses, Wrong guesses)
          const SizedBox(height: 18),
          Fold(
            title: 'The run',
            child: Facts([
              if (result?.loadMillis case final load?)
                ('Load time', '${(load / 1000).toStringAsFixed(1)} s'),
              ...engineFacts(whole.engine, whole: false),
            ]),
          ),

          // 3. Dropdowns / Collapsible folds
          if (result != null) ...[
            const SizedBox(height: 14),
            RunFolds(result: result, others: state.history),
          ],
        ],
      ],
    );
  }
}
