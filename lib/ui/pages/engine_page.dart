import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/backend.dart';
import '../../benchmark/benchmark.dart';
import '../../benchmark/metrics.dart' show formatNumber;
import '../../data/models.dart';
import '../../engine/commands.dart';
import '../../engine/engine_process.dart';
import '../../state/benchmark.dart';
import '../../state/chats.dart';
import '../../state/library.dart';
import '../../state/prefs.dart';
import '../../state/profiles.dart';
import '../../state/providers.dart';
import '../../theme.dart';
import '../benchmark/fold.dart';
import '../benchmark/history_view.dart';
import '../benchmark/live_graphs.dart';
import '../benchmark/result_view.dart';
import '../buttons.dart';
import '../clicky.dart';
import '../model_picker.dart';
import '../thinking_toggle.dart';

part 'benchmark_tab.dart';

/// The engine: which profile runs each model, the profile's commands, the memory cap, and the engine's output.
class EnginePage extends ConsumerWidget {
  const EnginePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final entry = ref.watch(shownModelProvider);
    final backend = ref.watch(backendProvider);
    final control = backend is EngineControl ? backend as EngineControl : null;
    ref.watch(profilesProvider);
    final benchmarkTab = ref.watch(engineTabProvider);
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 40),
      children: [
        Text('Engine', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: c.text)),
        const SizedBox(height: 14),
        Row(
          children: [
            OptionPill(
              key: const Key('engine-tab-run'),
              label: 'Run',
              chosen: !benchmarkTab,
              onTap: () => ref.read(engineTabProvider.notifier).show(benchmark: false),
            ),
            const SizedBox(width: 8),
            OptionPill(
              key: const Key('engine-tab-benchmark'),
              label: 'Benchmark',
              chosen: benchmarkTab,
              onTap: () => ref.read(engineTabProvider.notifier).show(benchmark: true),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // A soft raised surface, so the model and context stand out a little from the page.
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: c.selected,
              border: Border.all(color: c.inputBorder),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const ModelPicker(),
          ),
        ),
        const SizedBox(height: 16),
        if (entry == null || control == null)
          Text('Get a model from the Store first.', style: TextStyle(fontSize: 14, color: c.textSecondary))
        else if (benchmarkTab)
          _BenchmarkTab(entry: entry, control: control)
        else ...[
          _Status(file: entry.file, control: control),
          const SizedBox(height: 22),
          _Profiles(file: entry.file, control: control),
          const SizedBox(height: 28),
          _Title('Engine output'),
          const SizedBox(height: 10),
          _Log(control: control),
        ],
      ],
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: context.colors.text));
}

/// Why the engine could not be started from this page (Start, or Restart now); null once it has started again.
class _StartErrorNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? message) => state = message;
}

final _startErrorProvider = NotifierProvider<_StartErrorNotifier, String?>(_StartErrorNotifier.new);

/// Starts the engine for [file] as [run] says (with [restart], even if it is running) and shows on this page why it
/// could not, if it could not.
Future<void> _startEngine(WidgetRef ref, EngineControl control, ModelFile file, EngineRun run, {bool restart = false}) async {
  final error = ref.read(_startErrorProvider.notifier)..set(null);
  try {
    await control.startEngine(file, run, restart: restart);
  } on Exception catch (e) {
    error.set(e is EngineFailure ? e.message : '$e');
  }
}

/// What the engine is doing, with Start and Stop.
class _Status extends ConsumerStatefulWidget {
  const _Status({required this.file, required this.control});

  final ModelFile file;
  final EngineControl control;

  @override
  ConsumerState<_Status> createState() => _StatusState();
}

class _StatusState extends ConsumerState<_Status> {
  void _start() {
    final shown = ref.read(shownContextProvider);
    if (shown == null) return;
    unawaited(_startEngine(ref, widget.control, widget.file, ref.read(profilesProvider.notifier).runFor(widget.file, shown.value)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final error = ref.watch(_startErrorProvider);
    final benchmarking = ref.watch(benchmarkProvider.select((s) => s.running));
    final replyingChat = ref.watch(chatsProvider.select((s) => s.replyingId == null ? null : (s.byId(s.replyingId)?.title ?? '')));
    final replying = replyingChat != null || benchmarking;
    // Why Start is greyed out.
    final why = benchmarking
        ? 'A benchmark is running.'
        : replyingChat != null
        ? '"$replyingChat" is generating a response.'
        : null;
    final files = ref.watch(catalogFilesProvider);
    return ValueListenableBuilder<EngineState>(
      valueListenable: widget.control.engineState,
      builder: (context, state, _) {
        final name = files[state.modelId]?.model.name;
        final length = state.run == null ? '' : ' at ${contextLabel(state.run!.contextLength)}';
        final text = switch (state.phase) {
          EnginePhase.stopped => 'Not running. A model loads when you send a message, or with Start.',
          EnginePhase.loading => 'Loading $name$length…',
          EnginePhase.ready => 'Running $name$length.',
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(text, style: TextStyle(fontSize: 14, color: c.textSecondary))),
                const SizedBox(width: 12),
                if (state.phase == EnginePhase.stopped)
                  MainButton(key: const Key('engine-start'), label: 'Start', onTap: replying ? null : _start)
                else
                  AppButton(
                    key: const Key('engine-stop'),
                    label: 'Stop',
                    // (Stop while it loads ends the load.)
                    onTap: replying ? null : widget.control.stopEngine,
                  ),
              ],
            ),
            if (state.phase == EnginePhase.stopped && why != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(why, key: const Key('engine-start-note'), style: TextStyle(fontSize: 13, color: c.textMuted)),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(error, style: TextStyle(fontSize: 13, color: c.danger)),
              ),
          ],
        );
      },
    );
  }
}

/// The model's profiles, and the commands and memory cap of the one in use.
class _Profiles extends ConsumerStatefulWidget {
  const _Profiles({required this.file, required this.control});

  final ModelFile file;
  final EngineControl control;

  @override
  ConsumerState<_Profiles> createState() => _ProfilesState();
}

class _ProfilesState extends ConsumerState<_Profiles> {
  var _adding = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final notifier = ref.read(profilesProvider.notifier);
    final file = widget.file;
    final active = notifier.active(file);
    final maxContext = ref.watch(backendProvider).maxContext(file);
    final benchmark = ref.watch(benchmarkProvider);
    final replying = ref.watch(chatsProvider.select((s) => s.replyingId != null)) || benchmark.running;
    // The profile a benchmark is using cannot be changed until it ends.
    final locked = benchmark.running && benchmark.modelId == file.id && benchmark.profileId == active.id;
    final commands = active.commands;

    List<int> takenBesides(int? index) => [
      for (var i = 0; i < commands.length; i++)
        if (i != index) ?contextOf(commands[i]),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Title('Profile'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final p in notifier.all(file))
              OptionPill(
                key: Key('profile-${p.id}'),
                label: p.name,
                chosen: p.id == active.id,
                onTap: () {
                  setState(() => _adding = false);
                  notifier.setActive(file, p.id);
                },
              ),
            AppButton(key: const Key('profile-new'), label: '+ New profile', onTap: () => notifier.create(file)),
            _RestartNow(file: file, control: widget.control, replying: replying),
          ],
        ),
        if (locked)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('A benchmark is using this profile.', style: TextStyle(fontSize: 13, color: c.textMuted)),
          ),
        if (!active.isAuto && !locked) ...[
          const SizedBox(height: 14),
          _ProfileName(key: ValueKey('name-${active.id}'), file: file, profile: active),
        ],
        const SizedBox(height: 18),
        _MemoryCap(key: ValueKey('cap-${active.id}-$locked'), file: file, profile: active, locked: locked),
        const SizedBox(height: 24),
        const _Title('Commands'),
        const SizedBox(height: 2),
        Text(
          active.isAuto
              ? 'Auto cannot be changed. Copy a command into your own profile to change it.'
              : 'Only the engine\'s flags and settings. The app adds the engine, the model, the address and the port.',
          style: TextStyle(fontSize: 13, color: c.textSecondary),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < commands.length; i++)
          _Command(
            key: ValueKey('${active.id}-$i-${commands.length}-$locked'),
            saved: commands[i],
            readOnly: active.isAuto || locked,
            problemIn: (text) => commandProblem(text, maxContext: maxContext, taken: takenBesides(i)),
            onSave: (text) =>
                notifier.update(file, active.copyWith(commands: [...commands]..[i] = text)),
            onDelete: active.isAuto || locked || commands.length == 1
                ? null
                : () => notifier.update(file, active.copyWith(commands: [...commands]..removeAt(i))),
          ),
        if (_adding)
          _Command(
            key: ValueKey('${active.id}-adding'),
            saved: '',
            readOnly: false,
            startOpen: true,
            problemIn: (text) => commandProblem(text, maxContext: maxContext, taken: takenBesides(null)),
            onSave: (text) {
              setState(() => _adding = false);
              notifier.update(file, active.copyWith(commands: [...commands, text]));
            },
            onDelete: () => setState(() => _adding = false),
          )
        else if (!active.isAuto && !locked)
          AppButton(key: const Key('command-add'), label: '+ Add a length', onTap: () => setState(() => _adding = true)),
      ],
    );
  }
}

/// "Restart now": the engine is running this model with flags or a memory cap other than those saved.
class _RestartNow extends ConsumerWidget {
  const _RestartNow({required this.file, required this.control, required this.replying});

  final ModelFile file;
  final EngineControl control;
  final bool replying;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(profilesProvider);
    return ValueListenableBuilder<EngineState>(
      valueListenable: control.engineState,
      builder: (context, state, _) {
        final running = state.run;
        if (state.phase != EnginePhase.ready || running == null || state.modelId != file.id) {
          return const SizedBox.shrink();
        }
        final saved = ref.read(profilesProvider.notifier).runFor(file, running.contextLength);
        if (saved.flags == running.flags && saved.memoryCapGiB == running.memoryCapGiB) return const SizedBox.shrink();
        return AppButton(
          key: const Key('engine-restart'),
          label: 'Restart now',
          dense: true,
          onTap: replying ? null : () => unawaited(_startEngine(ref, control, file, saved, restart: true)),
        );
      },
    );
  }
}

class _ProfileName extends ConsumerStatefulWidget {
  const _ProfileName({super.key, required this.file, required this.profile});

  final ModelFile file;
  final EngineProfile profile;

  @override
  ConsumerState<_ProfileName> createState() => _ProfileNameState();
}

class _ProfileNameState extends ConsumerState<_ProfileName> {
  late final _text = TextEditingController(text: widget.profile.name);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final notifier = ref.read(profilesProvider.notifier);
    return Row(
      children: [
        SizedBox(
          width: 240,
          child: TextField(
            key: const Key('profile-name'),
            controller: _text,
            onChanged: (name) {
              if (name.trim().isNotEmpty) notifier.update(widget.file, widget.profile.copyWith(name: name.trim()));
            },
            style: TextStyle(fontSize: 13, color: c.text),
            cursorColor: c.text,
            decoration: _boxDecoration(c),
          ),
        ),
        const SizedBox(width: 8),
        AppButton(
          key: const Key('profile-delete'),
          label: 'Delete profile',
          dense: true,
          onTap: () => notifier.delete(widget.file, widget.profile.id),
        ),
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

/// The memory cap. Save and Reset show only while there is a change.
class _MemoryCap extends ConsumerStatefulWidget {
  const _MemoryCap({super.key, required this.file, required this.profile, this.locked = false});

  final ModelFile file;
  final EngineProfile profile;
  final bool locked;

  @override
  ConsumerState<_MemoryCap> createState() => _MemoryCapState();
}

class _MemoryCapState extends ConsumerState<_MemoryCap> {
  static String _show(double? gib) => gib == null ? '' : (gib == gib.roundToDouble() ? '${gib.round()}' : '$gib');

  late final _text = TextEditingController(text: _show(widget.profile.memoryCapGiB));
  String? _problem;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final text = _text.text.trim();
    final gib = double.tryParse(text);
    if (text.isNotEmpty && (gib == null || gib <= 0)) {
      setState(() => _problem = 'Enter a number of GB, or leave it empty.');
      return;
    }
    setState(() => _problem = null);
    ref.read(profilesProvider.notifier).update(widget.file, widget.profile.copyWith(memoryCapGiB: () => text.isEmpty ? null : gib));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    const allButOne = 'All RAM but 1 GB';
    final dirty = _text.text.trim() != _show(widget.profile.memoryCapGiB);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Memory cap', style: TextStyle(fontSize: 13, color: c.textSecondary)),
            const SizedBox(width: 12),
            if (widget.profile.isAuto || widget.locked)
              Text(_show(widget.profile.memoryCapGiB).isEmpty ? allButOne : '${_show(widget.profile.memoryCapGiB)} GB', style: TextStyle(fontSize: 13, color: c.text))
            else ...[
              SizedBox(
                width: 150,
                child: TextField(
                  key: const Key('memory-cap'),
                  controller: _text,
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(fontSize: 13, color: c.text),
                  cursorColor: c.text,
                  decoration: _boxDecoration(c, hint: allButOne),
                ),
              ),
              const SizedBox(width: 6),
              Text('GB', style: TextStyle(fontSize: 13, color: c.textMuted)),
              if (dirty) ...[
                const SizedBox(width: 10),
                MainButton(key: const Key('memory-cap-save'), label: 'Save', onTap: _save),
                const SizedBox(width: 6),
                AppButton(
                  label: 'Reset',
                  onTap: () => setState(() {
                    _text.text = _show(widget.profile.memoryCapGiB);
                    _problem = null;
                  }),
                ),
              ],
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

/// One command, folded to its length until clicked. Save and Reset show only while there is a change; what cannot run
/// cannot be saved.
class _Command extends StatefulWidget {
  const _Command({
    super.key,
    required this.saved,
    required this.readOnly,
    required this.problemIn,
    required this.onSave,
    required this.onDelete,
    this.startOpen = false,
  });

  /// It starts unfolded (a new one, to be typed in).
  final bool startOpen;
  final String saved;
  final bool readOnly;
  final String? Function(String) problemIn;
  final void Function(String) onSave;
  final VoidCallback? onDelete;

  @override
  State<_Command> createState() => _CommandState();
}

class _CommandState extends State<_Command> {
  late final _text = TextEditingController(text: widget.saved);
  late var _open = widget.startOpen;
  String? _problem;

  @override
  void didUpdateWidget(_Command old) {
    super.didUpdateWidget(old);
    if (old.saved != widget.saved && _text.text == old.saved) _text.text = widget.saved;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final text = _text.text.trim();
    final problem = widget.problemIn(text);
    setState(() {
      _problem = problem;
      if (problem != null) _open = true;
    });
    if (problem == null) widget.onSave(text);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style = TextStyle(fontSize: 12, height: 1.5, color: c.text, fontFamily: 'monospace');
    final dirty = _text.text != widget.saved;
    final length = contextOf(_text.text);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
      decoration: BoxDecoration(
        color: c.inputFill,
        border: Border.all(color: c.inputBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Clicky(
                  key: Key('command-fold-${length ?? 'new'}'),
                  onTap: () => setState(() => _open = !_open),
                  child: Row(
                    children: [
                      AnimatedRotation(
                        turns: _open ? 0 : -0.25,
                        duration: const Duration(milliseconds: 150),
                        child: Icon(Icons.keyboard_arrow_down, size: 16, color: c.textMuted),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        length == null ? 'New length' : contextLabel(length),
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.text),
                      ),
                    ],
                  ),
                ),
              ),
              if (dirty && !widget.readOnly) ...[
                MainButton(key: const Key('command-save'), label: 'Save', onTap: _save),
                const SizedBox(width: 6),
                AppButton(
                  label: 'Reset',
                  onTap: () => setState(() {
                    _text.text = widget.saved;
                    _problem = null;
                  }),
                ),
                const SizedBox(width: 6),
              ],
              AppIconButton(size: 24, iconSize: 14, radius: 6, muted: true, 
                icon: Icons.copy_outlined,
                tooltip: 'Copy',
                onTap: () => Clipboard.setData(ClipboardData(text: _text.text)),
              ),
              if (widget.onDelete != null)
                AppIconButton(size: 24, iconSize: 14, radius: 6, muted: true, icon: Icons.close, tooltip: 'Remove this length', onTap: widget.onDelete!),
            ],
          ),
          if (_open) const SizedBox(height: 6),
          if (_open && widget.readOnly)
            SelectableText(widget.saved, style: style)
          else if (_open)
            TextField(
              controller: _text,
              onChanged: (_) => setState(() => _problem = null),
              minLines: 2,
              maxLines: null,
              style: style,
              cursorColor: c.text,
              decoration: const InputDecoration(border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero),
            ),
          if (_open && _problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_problem!, style: TextStyle(fontSize: 13, color: c.danger)),
            ),
        ],
      ),
    );
  }
}

/// The engine's output as it comes.
class _Log extends StatelessWidget {
  const _Log({required this.control});

  final EngineControl control;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      height: 200,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: c.inputFill,
        border: Border.all(color: c.inputBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ListenableBuilder(
        listenable: control.logChanged,
        builder: (context, _) {
          final lines = control.logLines;
          return SingleChildScrollView(
            reverse: true,
            child: SizedBox(
              width: double.infinity,
              child: SelectableText(
                lines.isEmpty ? 'Nothing yet.' : lines.join('\n'),
                style: TextStyle(fontSize: 11.5, height: 1.45, color: c.textMuted, fontFamily: 'monospace'),
              ),
            ),
          );
        },
      ),
    );
  }
}
