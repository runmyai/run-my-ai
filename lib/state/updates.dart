import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/backend.dart';
import '../backend/engine_backend.dart';
import '../data/models.dart';
import '../engine/engine_download.dart';
import '../system/downloads.dart';
import '../system/folders.dart';
import '../system/relaunch.dart';
import '../system/updater.dart';
import 'about.dart';
import 'benchmark.dart';
import 'chats.dart';
import 'library.dart';
import 'prefs.dart';
import 'providers.dart';
import 'serve.dart';
import 'tuning_runs.dart';

/// A newer version of the app: its releases newest first, and why it is not put in place by the app, if it is not
/// (then the user downloads it from the website).
class AppUpdate {
  const AppUpdate(this.releases, {this.asset, this.manual});

  final List<GitHubRelease> releases;
  final String? asset;
  final String? manual;

  GitHubRelease get newest => releases.first;
  int? get size => newest.assets[asset]?.size;
}

/// A newer version of the downloaded engine: its releases newest first, and the build installed (the one updated).
class EngineUpdate {
  const EngineUpdate(this.releases, this.build, this.asset);

  final List<GitHubRelease> releases;
  final String build, asset;

  GitHubRelease get newest => releases.first;
  int? get size => newest.assets[asset]?.size;
}

/// A downloaded model with newer files: the versions since its own (newest first) and the files that change.
class ModelUpdate {
  const ModelUpdate({
    required this.file,
    required this.name,
    required this.folder,
    required this.versions,
    required this.files,
  });

  final ModelFile file;
  final String name, folder;
  final List<ModelVersion> versions;
  final Map<String, FileSum> files;

  int get size => files.values.fold(0, (sum, f) => sum + f.size);
}

class UpdatesState {
  const UpdatesState({
    this.app,
    this.engine,
    this.models = const [],
    this.updating = false,
    this.step,
    this.progress,
    this.message,
    this.failed = false,
  });

  final AppUpdate? app;
  final EngineUpdate? engine;
  final List<ModelUpdate> models;

  /// An update is running: [step] says what it does, [progress] how far its download is.
  final bool updating;
  final String? step;
  final DownloadProgress? progress;

  /// Why Update did nothing (the engine is in use), why the update failed ([failed]), or that it is done.
  final String? message;
  final bool failed;

  /// Something is newer than what this PC has.
  bool get any => app != null || engine != null || models.isNotEmpty;

  /// Something the Update button puts in place.
  bool get updatable => engine != null || models.isNotEmpty || (app != null && app!.manual == null);

  UpdatesState copyWith({
    AppUpdate? Function()? app,
    EngineUpdate? Function()? engine,
    List<ModelUpdate>? models,
    bool? updating,
    String? Function()? step,
    DownloadProgress? Function()? progress,
    String? Function()? message,
    bool? failed,
  }) => UpdatesState(
    app: app != null ? app() : this.app,
    engine: engine != null ? engine() : this.engine,
    models: models ?? this.models,
    updating: updating ?? this.updating,
    step: step != null ? step() : this.step,
    progress: progress != null ? progress() : this.progress,
    message: message != null ? message() : this.message,
    failed: failed ?? this.failed,
  );
}

/// GitHub's API (tests use their own server).
final gitHubApiProvider = Provider<Uri>((ref) => Uri.parse('https://api.github.com'));

/// Whether updates are looked for: with the real engine (tests that look for them say so).
final updatesEnabledProvider = Provider<bool>((ref) => ref.read(backendProvider) is EngineBackend);

/// The AppImage the app was started from; null when it was not (a build run from its folder).
final appImageProvider = Provider<String?>((ref) => Platform.environment['APPIMAGE']);

/// Starts the new app and ends this one (tests only note it).
final relaunchProvider = Provider<Future<void> Function()>((ref) => relaunchApp);

/// The checksums of the model files, kept in the app's data folder.
final fileHashesProvider = Provider<FileHashes>(
  (ref) => FileHashes(File('${ref.read(storageProvider).dir.path}${Platform.pathSeparator}file_hashes.json')),
);

/// Looks once, when the app starts, for newer versions of the app, the downloaded engine and the downloaded models
/// (quietly: nothing is said when that fails), and updates them all to the newest on the user's click.
class UpdatesNotifier extends Notifier<UpdatesState> {
  @override
  UpdatesState build() {
    if (ref.read(updatesEnabledProvider)) unawaited(Future(check));
    return const UpdatesState();
  }

  /// Looks for newer versions; each part on its own, a part that fails is left out.
  Future<void> check() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    Future<T?> quietly<T>(Future<T?> Function() look) async {
      try {
        return await look();
      } on Object {
        return null;
      }
    }

    try {
      final app = await quietly(() => _checkApp(client));
      final engine = await quietly(() => _checkEngine(client));
      final models = await quietly(() => _checkModels(client)) ?? const <ModelUpdate>[];
      if (!ref.mounted) return;
      state = state.copyWith(app: () => app, engine: () => engine, models: models);
    } finally {
      client.close(force: true);
    }
  }

  Future<AppUpdate?> _checkApp(HttpClient client) async {
    final api = ref.read(gitHubApiProvider).resolve(appReleasesPath);
    final releases = newerReleases(await gitHubReleases(client, api), appVersion);
    if (releases.isEmpty) return null;
    final asset = appAsset(thisOs, thisArch);
    if (asset == null) {
      return AppUpdate(releases, manual: 'Download the new version from the website.');
    }
    if (!releases.first.assets.containsKey(asset)) return null;
    if (ref.read(appImageProvider) == null) {
      return AppUpdate(
        releases,
        asset: asset,
        manual:
            'This copy of Run My AI was not started from its AppImage, so it is not replaced. Download the new '
            'version from the website.',
      );
    }
    return AppUpdate(releases, asset: asset);
  }

  Future<EngineUpdate?> _checkEngine(HttpClient client) async {
    // the user's own engine folder is never replaced
    if (ref.read(prefsProvider).engineFolder != null) return null;
    final installed = installedEngine(ref.read(foldersProvider).engine);
    if (installed == null) return null;
    final api = ref.read(gitHubApiProvider).resolve(engineReleasesPath);
    final releases = newerReleases(await gitHubReleases(client, api), installed.version);
    final asset = engineAsset(thisOs, thisArch, installed.build);
    if (releases.isEmpty || !releases.first.assets.containsKey(asset)) return null;
    return EngineUpdate(releases, installed.build, asset);
  }

  Future<List<ModelUpdate>> _checkModels(HttpClient client) async {
    final catalog = await ref.read(catalogProvider.future);
    final folders = ref.read(foldersProvider);
    final server = ref.read(downloadServerProvider);
    final hashes = ref.read(fileHashesProvider);
    final lists = <String, List<ModelVersion>?>{};
    final found = <ModelUpdate>[];
    for (final model in catalog) {
      for (final file in model.files) {
        final repo = file.repo;
        final folder = repo == null ? null : folders.folderWith(file.parts);
        if (repo == null || folder == null) continue;
        if (!lists.containsKey(repo)) lists[repo] = await _modelList(client, server, repo);
        final versions = lists[repo];
        if (versions == null) continue;
        final listed = {for (final v in versions) ...v.files.keys};
        final local = {
          for (final name in file.parts)
            if (listed.contains(name)) name: await hashes.of('$folder${Platform.pathSeparator}$name'),
        };
        final update = modelUpdate(versions, local);
        if (update != null) {
          found.add(
            ModelUpdate(file: file, name: model.name, folder: folder, versions: update.versions, files: update.files),
          );
        }
      }
    }
    return found;
  }

  /// The versions in [repo]'s list file; null when it has none (no model updates).
  Future<List<ModelVersion>?> _modelList(HttpClient client, Uri server, String repo) async {
    final response = await (await client.getUrl(server.resolve('/$repo/resolve/main/runmyai.json'))).close();
    final body = await response.transform(utf8.decoder).join();
    return response.statusCode == 200 ? parseModelVersions(body) : null;
  }

  /// Why the engine cannot be stopped for an update now; null when it can.
  String? get busyReason {
    if (ref.read(chatsProvider).replyingId != null) return 'A reply is being written - update when it finishes.';
    if (ref.read(benchmarkProvider).running) return 'A benchmark is running - update when it finishes.';
    if (ref.read(serveProvider).phase != ServePhase.idle) return 'A model is hosted - update when hosting ends.';
    if (ref.read(tuningRunsProvider).tuning != null) {
      return 'The PC is being measured for a model - update when that finishes.';
    }
    return null;
  }

  void _show(DownloadProgress p) {
    if (ref.mounted) state = state.copyWith(progress: () => p);
  }

  void _step(String step) => state = state.copyWith(step: () => step, progress: () => null);

  /// Updates everything newer to the newest: the engine stopped first, then the engine, the models and last the app
  /// (which then starts again in its new version). Each is downloaded and checked before it replaces the old one, so a
  /// failure leaves it as it was. Nothing happens while the engine writes a reply, runs a benchmark, hosts or tunes.
  Future<void> update() async {
    if (state.updating) return;
    final busy = busyReason;
    if (busy != null) {
      state = state.copyWith(message: () => busy, failed: false);
      return;
    }
    state = state.copyWith(updating: true, message: () => null, failed: false);
    try {
      final Object backend = ref.read(backendProvider);
      if (backend is EngineControl) await backend.stopEngine();
      if (state.engine case final engine?) {
        _step('Updating the engine to ${engine.newest.tag}...');
        final done = await EngineDownload(
          release: engine.newest.asEngine,
          asset: engine.asset,
          build: engine.build,
          engineFolder: ref.read(foldersProvider).engine,
          onProgress: _show,
        ).run();
        if (!done) throw const DownloadFailure('The engine update stopped. Nothing was changed.');
        state = state.copyWith(engine: () => null);
      }
      for (final model in state.models) {
        _step('Updating ${model.name}...');
        await updateModelFiles(
          repo: model.file.repo!,
          folder: model.folder,
          files: model.files,
          server: ref.read(downloadServerProvider),
          hashes: ref.read(fileHashesProvider),
          onProgress: _show,
        );
        state = state.copyWith(
          models: [
            for (final m in state.models)
              if (m != model) m,
          ],
        );
      }
      final app = state.app, appImage = ref.read(appImageProvider);
      if (app != null && app.manual == null && appImage != null) {
        _step('Updating Run My AI to ${app.newest.tag}...');
        await replaceAppImage(release: app.newest, asset: app.asset!, appImage: appImage, onProgress: _show);
        state = state.copyWith(app: () => null);
        await ref.read(relaunchProvider)();
        return;
      }
      state = state.copyWith(updating: false, step: () => null, progress: () => null, message: () => 'Updated.');
    } on Exception catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(
        updating: false,
        step: () => null,
        progress: () => null,
        failed: true,
        message: () => e is DownloadFailure ? e.message : 'The update stopped: $e',
      );
    }
  }
}

final updatesProvider = NotifierProvider<UpdatesNotifier, UpdatesState>(UpdatesNotifier.new);
