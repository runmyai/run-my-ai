import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/backend.dart';
import '../engine/engine_download.dart';
import '../state/download_events.dart';
import '../state/first_run.dart';
import '../state/prefs.dart';
import '../state/providers.dart';
import '../system/downloads.dart';
import '../system/folders.dart';
import '../theme.dart';
import 'buttons.dart';
import 'select_box.dart';
import 'settings/folders_section.dart';

/// Whether the app still has to get its engine: the real engine is used, the user has not chosen their own engine
/// folder, and there is no engine in the app's engine folder or next to the app.
bool engineMissing(WidgetRef ref) =>
    engineMissingFor(ref.read(backendProvider), ref.read(prefsProvider).engineFolder, () => ref.read(foldersProvider));

/// The engine step as a dialog; done when it closes (the engine installed, or put off for later). At the first start
/// ([firstStart]) the app needs its engine: the step cannot be closed until one is installed or chosen.
Future<void> showEngineSetup(BuildContext context, {bool firstStart = false}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => EngineSetup(firstStart: firstStart),
);

enum _Phase { looking, unavailable, choose, downloading, paused, checking, failed }

/// "Download the TokenWing engine": the build picked for this PC chosen (with a list to change it) and its size; one
/// click on Download starts it. Then its progress with Pause / Resume / Cancel and "Checking...", after which the
/// dialog closes by itself. At the first start it has no way to close it before the engine is there, and a Folders
/// list where the app's folders can be changed first, or a folder with the user's own engine chosen.
class EngineSetup extends ConsumerStatefulWidget {
  const EngineSetup({super.key, this.releases, this.firstStart = false});

  /// Where the releases are listed (tests give their own); GitHub's by default.
  final Uri? releases;

  /// The first start's step, which cannot be closed or skipped.
  final bool firstStart;

  @override
  ConsumerState<EngineSetup> createState() => _EngineSetupState();
}

class _EngineSetupState extends ConsumerState<EngineSetup> {
  var _phase = _Phase.looking;
  String? _message;
  EngineRelease? _release;
  var _mixed = false;
  String _build = 'cpu', _picked = 'cpu';
  DownloadProgress? _progress;
  EngineDownload? _download;
  var _cancelled = false;

  /// The Folders list is open.
  var _folders = false;

  @override
  void initState() {
    super.initState();
    _look();
  }

  @override
  void dispose() {
    _download?.stop();
    super.dispose();
  }

  /// Finds the build for this PC and the latest release.
  Future<void> _look() async {
    if (_phase != _Phase.looking) {
      setState(() {
        _phase = _Phase.looking;
        _message = null;
      });
    }
    final pick = await pickEngineBuildHere();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final release = await latestEngineRelease(client, widget.releases ?? engineReleases);
      if (!mounted) return;
      setState(() {
        _release = release;
        _mixed = pick.mixed;
        _build = _picked = pick.build;
        _phase = release == null ? _Phase.unavailable : _Phase.choose;
      });
    } on DownloadFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.unavailable;
        _message = e.message;
      });
    } finally {
      client.close(force: true);
    }
  }

  String get _asset => engineAsset(thisOs, thisArch, _build);

  Future<void> _start() async {
    final release = _release!;
    final own = ref.read(prefsProvider).engineFolder;
    final download = _download = EngineDownload(
      release: release,
      asset: _asset,
      build: _build,
      engineFolder: ref.read(foldersProvider).engine,
      onProgress: (p) {
        if (!mounted) return;
        setState(() {
          _progress = p;
          if (p.checking) _phase = _Phase.checking;
        });
      },
      beforeInstall: () async {
        final Object backend = ref.read(backendProvider);
        if (backend is EngineControl) await backend.stopEngine();
      },
    );
    _cancelled = false;
    setState(() {
      _phase = _Phase.downloading;
      _message = null;
    });
    try {
      final installed = await download.run();
      if (_cancelled) download.cancel();
      if (!mounted) return;
      if (!installed) {
        setState(() => _phase = _cancelled ? _Phase.choose : _Phase.paused);
        return;
      }
      unawaited(ref.read(downloadEventsProvider).engine(_asset, release.tag));
      // a download from Settings replaces the user's own engine folder: the downloaded engine is the one used
      if (own != null) ref.read(prefsProvider.notifier).setEngineFolder('');
      Navigator.pop(context);
    } on DownloadFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _message = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final release = _release;
    final progress = _progress;
    final own = ref.watch(prefsProvider.select((p) => p.engineFolder));
    final small = TextStyle(fontSize: 13, height: 1.4, color: c.textSecondary);
    final first = widget.firstStart;
    // At the first start, a folder with the user's own engine chosen under Folders ends the step.
    ref.listen(prefsProvider.select((p) => p.engineFolder), (_, folder) {
      if (first && folder != null) Navigator.pop(context);
    });

    String size(String build) {
      final bytes = release?.assets[engineAsset(thisOs, thisArch, build)]?.size;
      return bytes == null ? '' : '${(bytes / 1e9).toStringAsFixed(1)} GB';
    }

    final body = <Widget>[
      if (_phase == _Phase.looking)
        Text('Looking for the engine for this PC...', style: small)
      else if (_phase == _Phase.unavailable) ...[
        Text(
          _message ?? "The engine download isn't available yet.",
          key: const Key('engine-unavailable'),
          style: small,
        ),
        const SizedBox(height: 6),
        Text(
          'Run My AI ${first ? 'also' : 'still'} works with an engine you already have: choose its folder '
          '${first ? 'under Folders below' : 'in Settings > Folders > Engine'}.',
          style: small,
        ),
      ] else ...[
        SelectBox<String>(
          id: 'engine-build',
          label: 'Engine build',
          value: _build,
          width: 420,
          entries: [
            for (final b in engineBuilds(thisOs, thisArch))
              SelectEntry(
                id: b,
                value: b,
                label: [
                  engineBuildLabel(b),
                  size(b),
                  if (b == _picked) 'for this PC',
                ].where((s) => s.isNotEmpty).join(' · '),
                enabled: release?.assets.containsKey(engineAsset(thisOs, thisArch, b)) ?? false,
                reason: 'Not in this release',
              ),
          ],
          onChanged: _phase == _Phase.choose || _phase == _Phase.failed ? (b) => setState(() => _build = b) : null,
        ),
        if (_mixed) ...[
          const SizedBox(height: 6),
          Text('Using several GPU brands together comes in an update.', key: const Key('engine-mixed'), style: small),
        ],
        if (own != null && _phase == _Phase.choose) ...[
          const SizedBox(height: 6),
          Text('Run My AI then uses the downloaded engine instead of your own engine folder.', style: small),
        ],
        if (_phase case _Phase.downloading || _Phase.paused || _Phase.checking) ...[
          const SizedBox(height: 14),
          LinearProgressIndicator(
            value: _phase == _Phase.checking
                ? null
                : (progress != null && progress.total > 0 ? progress.done / progress.total : null),
            minHeight: 5,
            borderRadius: BorderRadius.circular(3),
            color: c.text,
            backgroundColor: c.switchTrack,
          ),
          const SizedBox(height: 6),
          Text(_statusLine(_phase, progress), key: const Key('engine-status'), style: small),
        ],
        if (_phase == _Phase.failed && _message != null) ...[
          const SizedBox(height: 8),
          Text(
            _message!,
            key: const Key('engine-failure'),
            style: TextStyle(fontSize: 13, color: c.danger),
          ),
        ],
      ],
    ];

    final buttons = switch (_phase) {
      _Phase.looking || _Phase.checking => <Widget>[],
      _Phase.unavailable => [
        if (!first) AppButton(key: const Key('engine-later'), label: 'Close', onTap: () => Navigator.pop(context)),
        MainButton(key: const Key('engine-retry'), label: 'Try again', onTap: _look),
      ],
      _Phase.choose || _Phase.failed => [
        if (!first) AppButton(key: const Key('engine-later'), label: 'Not now', onTap: () => Navigator.pop(context)),
        MainButton(
          key: const Key('engine-download'),
          label: _phase == _Phase.failed ? 'Try again' : 'Download',
          autofocus: true,
          onTap: _start,
        ),
      ],
      _Phase.downloading || _Phase.paused => [
        AppButton(
          key: const Key('engine-cancel'),
          label: 'Cancel',
          onTap: () {
            _cancelled = true;
            if (_phase == _Phase.paused) {
              _download?.cancel();
              setState(() => _phase = _Phase.choose);
            } else {
              _download?.stop();
            }
          },
        ),
        _phase == _Phase.paused
            ? MainButton(key: const Key('engine-resume'), label: 'Resume', onTap: _start)
            : AppButton(
                key: const Key('engine-pause'),
                label: 'Pause',
                onTap: () {
                  _download?.stop();
                  setState(() => _phase = _Phase.paused);
                },
              ),
      ],
    };

    final dialog = Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            key: const Key('engine-setup'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Download the TokenWing engine',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: c.text),
              ),
              const SizedBox(height: 6),
              Text('The engine runs the models on your PC. It is downloaded once; updates replace it.', style: small),
              const SizedBox(height: 14),
              ...body,
              // Before anything is downloaded, the folders it goes to can still be changed.
              if (_phase case _Phase.looking || _Phase.unavailable || _Phase.choose || _Phase.failed when first) ...[
                const SizedBox(height: 14),
                InkWell(
                  key: const Key('engine-folders'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => setState(() => _folders = !_folders),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Folders',
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: c.text),
                        ),
                        Icon(_folders ? Icons.expand_less : Icons.expand_more, size: 18, color: c.textSecondary),
                      ],
                    ),
                  ),
                ),
                if (_folders) const FoldersSection(firstStart: true),
              ],
              if (buttons.isNotEmpty) ...[
                const SizedBox(height: 18),
                Row(mainAxisAlignment: MainAxisAlignment.end, spacing: 8, children: buttons),
              ],
            ],
          ),
        ),
      ),
    );
    // Escape cannot close the first start's step either.
    return PopScope(canPop: !first, child: dialog);
  }
}

/// What the line under the progress bar says.
String _statusLine(_Phase phase, DownloadProgress? p) {
  final percent = p == null || p.total == 0 ? '0 %' : '${(p.done * 100 / p.total).floor()} %';
  switch (phase) {
    case _Phase.paused:
      return 'Paused · $percent';
    case _Phase.checking:
      return 'Checking...';
    default:
      final speed = p?.bytesPerSecond;
      final left = speed == null || speed <= 0 ? null : Duration(seconds: ((p!.total - p.done) / speed).ceil());
      return [
        percent,
        if (speed != null) '${(speed / 1e6).toStringAsFixed(1)} MB/s',
        if (left != null) '${_duration(left)} left',
      ].join(' · ');
  }
}

String _duration(Duration d) => d.inHours > 0
    ? '${d.inHours} h ${d.inMinutes % 60} min'
    : d.inMinutes > 0
    ? '${d.inMinutes} min'
    : '${d.inSeconds} s';
