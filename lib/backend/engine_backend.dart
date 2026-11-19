import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../benchmark/amd_gpu.dart';
import '../benchmark/share.dart' show installIdIn;
import '../benchmark/hardware.dart';
import '../benchmark/nvml.dart';
import '../benchmark/win32_metrics.dart';
import '../data/models.dart';
import '../data/storage.dart';
import '../engine/auto_commands.dart';
import '../engine/commands.dart';
import '../engine/chat_states.dart';
import '../engine/chat_stream.dart';
import '../engine/context_fit.dart';
import '../engine/engine_download.dart';
import '../engine/engine_flags.dart';
import '../engine/engine_process.dart';
import '../engine/gguf.dart';
import '../engine/live_speed.dart';
import '../engine/tuning.dart';
import '../system/busy.dart';
import '../system/downloads.dart';
import '../system/folders.dart';
import 'backend.dart';

/// The models on this computer and how each one starts.
class _LocalModel {
  const _LocalModel({
    required this.model,
    required this.flags,
    required this.smallFlags,
    required this.cpuFlags,
    required this.layers,
    required this.firstMoe,
    required this.layerGiB,
    this.thinkingSwitch = false,
  });

  final CatalogModel model;

  /// The file the engine loads: the weights, the first of the model's files.
  String get path => model.files.first.parts.first;

  /// One command per context length, for a large GPU, a small one, and none.
  final Map<int, String> flags, smallFlags, cpuFlags;

  /// Its layer count, its first MoE layer, and one layer's experts in GiB (for the two-card layout).
  final int layers, firstMoe;
  final double layerGiB;

  /// Its thinking can be turned off.
  final bool thinkingSwitch;
}

/// The real engine: TokenWing's llama-server, started directly by the app. One model is loaded at a time: the first
/// message loads it, a message for another model swaps it.
class EngineBackend implements Backend, EngineControl, BranchControl, EngineInsight, ServeControl, TuneControl {
  EngineBackend(this._storage);

  final Storage _storage;

  /// The app's folders as last set in Settings.
  FolderSet get _folders => FolderSet.load(_storage.dir);

  /// Where the chats' saved states and snapshots are kept: one file per state, in the cache folder.
  String get _activeStateFolder => _folders.cache;

  /// The folder holding all of [m]'s files: the models folder, or a folder models are read from; the models folder
  /// when none has them (where they would be downloaded).
  String _modelFolder(_LocalModel m) {
    final folders = _folders;
    return folders.folderWith(m.model.files.first.parts) ?? folders.models;
  }

  /// The model file the engine loads.
  String _modelPath(_LocalModel m) => '${_modelFolder(m)}${Platform.pathSeparator}${m.path}';

  /// How many "start of message" snapshots each chat keeps.
  static const _snapshots = 4;

  /// The chats whose saved states go last.
  List<String> _pinnedChats = const [];

  /// Where the engine is until the user sets another folder: the app's own folder.
  static String get defaultEngineFolder => File(Platform.resolvedExecutable).parent.path;

  /// The engine folder: the user's own ([own]), else the app's (in its main folder) once an engine is there, else
  /// next to the app.
  static String engineFolder(String? own, FolderSet folders) {
    if (own != null) return own;
    final app = folders.engine;
    return File('$app/llama-server${Platform.isWindows ? '.exe' : ''}').existsSync() ? app : defaultEngineFolder;
  }

  /// The engine program's folder: the engine folder, or its cuda12 folder (the engine built with CUDA 12) on a PC whose NVIDIA
  /// cards or driver the CUDA 13 build cannot run (needsCuda12). Asked once. A downloaded engine is already the build
  /// picked for this PC (the CUDA 12 one included), so no cuda12 folder is looked for in it.
  String get _engineFolder {
    final own = _storage.readPrefs().engineFolder;
    final base = engineFolder(own, _folders);
    if (own == null && installedEngine(base) != null) return base;
    final old = '$base${Platform.pathSeparator}cuda12';
    if (!File('$old/llama-server${Platform.isWindows ? '.exe' : ''}').existsSync()) return base;
    _cuda12 ??= () {
      try {
        final r = Process.runSync('nvidia-smi', ['--query-gpu=compute_cap,driver_version', '--format=csv,noheader']);
        return needsCuda12(r.exitCode == 0 ? r.stdout as String : 'unreadable');
      } on ProcessException {
        return false;   // no NVIDIA driver
      }
    }();
    return _cuda12! ? old : base;
  }

  bool? _cuda12;

  // Each model's files on Hugging Face (the weights first: the file the engine loads), downloaded into one folder.
  static const _lingFile = ModelFile(
    id: 'ling-3.0-flash/MXFP4_MOE',
    quantization: 'MXFP4',
    sizeBytes: 70147512048,
    repo: 'runmyai/Ling-3.0-Flash-TokenWing',
    parts: ['Ling-3.0-flash-MXFP4_MOE.tokenwing.gguf'],
  );
  static const _flintFile = ModelFile(
    id: 'flint-40b/UD-Q4_K_XL',
    quantization: 'UD-Q4_K_XL',
    sizeBytes: 25055397324,
    repo: 'runmyai/Flint-40B-TokenWing',
    parts: ['flint-UD-Q4_K_XL.tokenwing.gguf'],
  );
  // the model, its n-gram table (...-00002-of-00002.gguf) and its data files
  static const _qwenFile = ModelFile(
    id: 'qwen3.8-flash-next/WV-v5-3.5bpw',
    quantization: 'WV-v5 3.5bpw',
    sizeBytes: 55203205120 + 28800138432 + 482000000,
    repo: 'runmyai/Qwen3.8-Flash-Next-TokenWing',
    parts: [
      'Qwen3.8-Flash-Next-WV-v5-3.5bpw.tokenwing-00001-of-00002.gguf',
      'Qwen3.8-Flash-Next-WV-v5-3.5bpw.tokenwing-00002-of-00002.gguf',
      'Qwen3.8-Flash-Next-WV-v5-3.5bpw.correction',
      'Qwen3.8-Flash-Next-WV-v5-3.5bpw.vram-experts.json',
      'Qwen3.8-Flash-Next-WV-v5-3.5bpw.tokenwing-00001-of-00002.gguf.usage-seed.json',
    ],
  );

  static const _models = [
    _LocalModel(
      model: CatalogModel(
        id: 'ling-3.0-flash',
        name: 'Ling 3.0 Flash',
        lab: 'inclusionAI',
        description: 'Everyday chat, math and code. (Placeholder text.)',
        parameters: '124B',
        activeParameters: '5.1B',
        thinking: ModelThinking.optional,
        files: [_lingFile],
      ),
      layers: 42,
      firstMoe: 2,
      layerGiB: 1.494,
      flags: lingAuto,
      smallFlags: lingAutoSmall,
      cpuFlags: lingAutoCpu,
      thinkingSwitch: true,
    ),
    _LocalModel(
      model: CatalogModel(
        id: 'flint-40b',
        name: 'Flint 40B',
        lab: 'Recursive',
        description: 'Coding. (Placeholder text.)',
        parameters: '40B',
        activeParameters: '2.5B',
        thinking: ModelThinking.always,
        files: [_flintFile],
      ),
      layers: 49,
      firstMoe: 2,
      layerGiB: 0.49,
      flags: flintAuto,
      smallFlags: flintAutoSmall,
      cpuFlags: flintAutoCpu,
    ),
    _LocalModel(
      model: CatalogModel(
        id: 'qwen3.8-flash-next',
        name: 'Qwen3.8 Flash Next',
        lab: 'Qwen',
        description: 'Everyday chat, math and code. (Placeholder text.)',
        parameters: '126B',
        activeParameters: '7.3B',
        thinking: ModelThinking.optional,
        files: [_qwenFile],
      ),
      layers: 48,
      firstMoe: 0,
      layerGiB: 1.1,
      flags: qwenAuto,
      smallFlags: qwenAutoSmall,
      cpuFlags: qwenAutoCpu,
      thinkingSwitch: true,
    ),
  ];

  /// The largest graphics card's memory, read once through NVML / AMD's driver files: the cards before the autotuner's
  /// first run.
  static final ({double giB}) _gpu = () {
    final nvidia = NvmlReader.open();
    final amd = AmdGpuReader.open(const DiskFiles(), firstIndex: nvidia?.names.length ?? 0);
    final gpus = GpuSources([?nvidia, ?amd]);
    try {
      return (giB: gpus.read().entries.where((e) => e.key.endsWith('.vramTotal')).fold(0.0, (a, e) => max(a, e.value ?? 0)));
    } finally {
      gpus.close();
    }
  }();

  static const _tuneVersion = 2;

  File get _tuneFile => File('${_storage.dir.path}${Platform.pathSeparator}autotuner.json');

  /// The autotuner's saved results (the cards, and per model what it measured), or null before its first run; a file
  /// from an older app is ignored (measured again).
  Map<String, dynamic>? get _savedTune {
    try {
      if (!_tuneFile.existsSync()) return null;
      final decoded = jsonDecode(_tuneFile.readAsStringSync());
      return decoded is Map<String, dynamic> && decoded['version'] == _tuneVersion ? decoded : null;
    } on Exception {
      return null;
    }
  }

  /// The graphics cards the engine sees (name and MiB), largest first: the autotuner's list once it has run, else the
  /// largest card read through NVML / AMD's driver files.
  List<({String name, int mib})> get _cards {
    final tune = _savedTune;
    if (tune == null || tune['gpus'] == null) return _gpu.giB > 0 ? [(name: '', mib: (_gpu.giB * 1024).round())] : const [];
    return cardsFrom(tune);
  }

  /// The key a model's result is kept under: the model file (name and size) and the autotuner build (size and time),
  /// so either changing measures again; null when the autotuner or the model file is missing.
  String? _tuneKey(_LocalModel local) {
    final tool = File('$_engineFolder/autotuner${Platform.isWindows ? '.exe' : ''}');
    final model = File(_modelPath(local));
    final m = model.statSync(), a = tool.statSync();
    if (m.type == FileSystemEntityType.notFound || a.type == FileSystemEntityType.notFound) return null;
    return '${model.uri.pathSegments.last}:${m.size}:${a.size}:${a.modified.millisecondsSinceEpoch}';
  }

  @override
  Map<String, dynamic>? savedTune(ModelFile file) {
    final local = _models.where((m) => m.model.files.contains(file)).firstOrNull;
    final key = local == null ? null : _tuneKey(local);
    if (key == null) return null;
    final kept = (_savedTune?['models'] as Map<String, dynamic>?)?[key];
    return kept is Map<String, dynamic> ? kept : null;
  }

  final _tuning = ValueNotifier<String?>(null);

  @override
  ValueListenable<String?> get tuning => _tuning;

  /// The latest tune: the next one, and every engine start, waits for it.
  Future<Map<String, dynamic>?>? _tuneRun;

  @override
  Future<Map<String, dynamic>?> tune(ModelFile file) {
    final before = _tuneRun;
    return _tuneRun = () async {
      await before;
      return _measure(_local(file));
    }();
  }

  /// Runs the autotuner for [local] (the cards, threads, fast cores, SSD readers at the model's expert size), with the busy
  /// check beside it, and keeps the result in autotuner.json per model.
  Future<Map<String, dynamic>?> _measure(_LocalModel local) async {
    final id = local.model.files.first.id;
    try {
      final folder = _engineFolder;
      final key = _tuneKey(local);
      if (key == null) return null;
      _tuning.value = id;
      final model = _modelPath(local);
      final p = await Process.start('$folder/autotuner${Platform.isWindows ? '.exe' : ''}', ['--file', model],
          workingDirectory: folder);
      final meter = BusyMeter.start(p.pid, model);
      final out = p.stdout.transform(utf8.decoder).join();
      unawaited(p.stderr.drain<void>());
      // a hung autotuner (a broken driver, a stalled disk) is stopped: the engine then starts with the table's values
      final code = await p.exitCode.timeout(const Duration(seconds: 30), onTimeout: () {
        p.kill();
        return -1;
      });
      final busy = meter?.stop() ?? false;
      if (code != 0) return null;
      final t = parseAutotunerJson(await out);
      if (t == null) return null;
      t['busy'] = busy;
      final store = _savedTune;
      final models = <String, dynamic>{...?(store?['models'] as Map<String, dynamic>?), key: t};
      _tuneFile.writeAsStringSync(jsonEncode({
        'version': _tuneVersion,
        'gpus': t['gpus'] ?? store?['gpus'] ?? const [],
        'igpus': t['igpus'] ?? store?['igpus'] ?? const [],
        'models': models,
      }));
      return t;
    } on Exception {
      return null;   // the table's values then stand
    } finally {
      if (_tuning.value == id) _tuning.value = null;
    }
  }

  /// What the autotuner measured on this PC for [local]: the kept result, or measured now for a model never tuned (one
  /// found in a folder, or a tune that failed); first waits for a tune that is running.
  Future<Map<String, dynamic>?> _tuned(_LocalModel local) async {
    await _tuneRun;
    final file = local.model.files.first;
    return savedTune(file) ?? await tune(file);
  }

  /// The model's commands for this machine: a large GPU (10 GiB and up), a small one (4 GiB and up), or none, by the
  /// largest card. With several cards all of them share the model, filled fastest first (cardFlags).
  /// shortcut: three kinds of machine from the card's memory alone; the full autotuner replaces this
  Map<int, String> _flagsFor(_LocalModel m) {
    final cards = _cards;
    final gib = cards.isEmpty ? 0.0 : cards.map((c) => c.mib).reduce(max) / 1024;
    final flags = gib >= 10 ? m.flags : (gib >= 4 ? m.smallFlags : m.cpuFlags);
    if (identical(flags, m.cpuFlags)) return flags;
    // Windows: the copy from RAM to the GPU without waiting measured slower there (7 of 7 pairs)
    final extra = [
      if (Platform.isWindows) '--moe-stream-async-h2d 0',
      if (cards.length > 1 && cards.every((c) => c.name.isNotEmpty))
        ...cardFlags(cards, m.layers, m.firstMoe, m.layerGiB)
      // one card: named, so a built-in GPU chosen for lack of a separate card is the one used
      else if (cards.length == 1 && cards[0].name.isNotEmpty)
        '--device ${cards[0].name}',
    ].join(' ');
    return extra.isEmpty ? flags : {for (final e in flags.entries) e.key: '${e.value} $extra'};
  }

  static _LocalModel _local(ModelFile file) => _models.firstWhere((m) => m.model.files.contains(file));

  EngineProcess? _engine;

  /// The latest load or swap: the next one waits for it.
  Future<EngineProcess>? _loading;

  /// The engine that is loading its model, until it answers: Stop ends it.
  EngineProcess? _loadingEngine;

  /// How many times the engine has been stopped, so a load can tell it was stopped on purpose.
  var _stops = 0;

  /// How many of each chat's oldest messages are left out, by chat and context length.
  final _leftOut = <String, int>{};

  /// Each message's length in tokens, as far as it has been counted, by model.
  final _tokens = <String, Expando<int>>{};

  /// Conversations that start as a copy of another's saved state, copied before their first request: the new id,
  /// and the one it comes from.
  final _forks = <String, String>{};

  /// Conversations whose state has been copied from another's (or tried), so it is not done twice.
  final _forked = <String>{};

  /// The reads ahead made for an edit that may still be cancelled, by conversation id: the request, and its end.
  final _readAheads = <String, (_Turn, Future<void>)>{};

  @override
  Future<List<CatalogModel>> loadCatalog() async => [for (final m in _models) m.model];

  /// Whether the model is on this computer (in the models folder or a folder models are read from): the Store
  /// downloads Hugging Face models itself (lib/system/downloads.dart).
  @override
  Stream<double> download(ModelFile file) => File(_modelPath(_local(file))).existsSync()
      ? Stream.value(1)
      : Stream.error(EngineFailure('The model file is not on this computer: ${_modelPath(_local(file))}'));

  @override
  Map<int, String> autoCommands(ModelFile file) => _flagsFor(_local(file));

  @override
  int maxContext(ModelFile file) {
    if (_maxContexts[file.id] case final known?) return known;
    final local = _local(file);
    final read = modelContextLength(_modelPath(local));
    // (Not kept until the file is there: a model downloaded later is read then.)
    if (read != null) _maxContexts[file.id] = read;
    return read ?? local.flags.keys.reduce(max);
  }

  /// The longest context each model file says it can run with, once read.
  final _maxContexts = <String, int>{};

  final _engineState = ValueNotifier(const EngineState(EnginePhase.stopped));
  final _logChanged = _Changed();

  /// The engine whose output is shown: the last one started, also after it has ended.
  EngineProcess? _lastEngine;

  @override
  ValueListenable<EngineState> get engineState => _engineState;

  @override
  List<String> get logLines => _lastEngine?.log ?? const [];

  @override
  Listenable get logChanged => _logChanged;

  @override
  Future<void> startEngine(ModelFile file, EngineRun run, {bool restart = false}) async {
    if (restart) await stopEngine();
    try {
      await _engineFor(_local(file), run);
    } on EngineStopped {
      // Stopped while it loaded: nothing went wrong.
    }
  }

  @override
  Future<void> startServing(
    ModelFile file,
    EngineRun run, {
    required int port,
    required String alias,
    required String apiKey,
    void Function(EngineFailure ended)? onEnded,
  }) async {
    await stopEngine();
    final stops = _stops;
    try {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await socket.close();
    } on SocketException {
      throw PortInUse(port);
    }
    final id = file.id;
    _engineState.value = EngineState(EnginePhase.loading, modelId: id, run: run);
    try {
      final engine = await _start(_local(file), run, serve: (port: port, alias: alias, apiKey: apiKey));
      if (stops != _stops) {
        await engine.stop();
        throw const EngineStopped();
      }
      _engine = engine;
      _engineState.value = EngineState(EnginePhase.ready, modelId: id, run: run);
      unawaited(engine.exited.then((_) {
        if (identical(_engine, engine)) _engineState.value = const EngineState(EnginePhase.stopped);
        onEnded?.call(EngineFailure('The engine stopped.', log: engine.lastLines(4)));
      }));
    } on Exception {
      _engineState.value = const EngineState(EnginePhase.stopped);
      if (stops != _stops) throw const EngineStopped();
      rethrow;
    }
  }

  @override
  Future<void> stopServing() => stopEngine();

  @override
  Future<void> eraseChatState(String chatId) async {
    final engine = _engine;
    if (engine != null && engine.running && await _eraseThrough(engine, chatId)) return;
    deleteChatStates(_activeStateFolder, chatId);
  }

  @override
  Future<void> setPinnedChats(List<String> chatIds) async {
    _pinnedChats = chatIds;
    final engine = _engine;
    if (engine != null && engine.running) await _sendPinned(engine);
  }

  @override
  Future<String?> reportedVersion() async {
    final engine = _engine;
    if (engine == null || !engine.running) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final response = await (await client.getUrl(engine.uri('/props'))).close();
      final body = await response.transform(utf8.decoder).join();
      final info = response.statusCode == 200 ? (jsonDecode(body) as Map<String, dynamic>)['build_info'] : null;
      return info is String ? info : null;
    } on IOException {
      return null;
    } on FormatException {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// The options each engine program lists in its help, by program path and the program's size and date (read once).
  final _options = <String, Set<String>>{};

  @override
  Future<bool> acceptsFlag(String flag) async {
    final folder = _engineFolder;
    final program = File('$folder/llama-server${Platform.isWindows ? '.exe' : ''}');
    if (!program.existsSync()) return false;
    final stat = program.statSync();
    final key = '${program.path}:${stat.size}:${stat.modified.millisecondsSinceEpoch}';
    var options = _options[key];
    if (options == null) {
      final text = await _helpText(program.path, folder);
      if (text == null) return false;
      options = RegExp(r'(?<![\w-])--?[A-Za-z][\w-]*').allMatches(text).map((m) => m[0]!).toSet();
      _options[key] = options;
    }
    return options.contains(flag);
  }

  /// What the engine program prints for --help; null when it cannot be run or does not finish within a few seconds.
  static Future<String?> _helpText(String program, String folder) async {
    try {
      final process = await Process.start(program, ['--help'], workingDirectory: folder);
      final output = StringBuffer();
      final read = Future.wait([
        for (final stream in [process.stdout, process.stderr])
          stream.transform(const Utf8Decoder(allowMalformed: true)).forEach(output.write),
      ]);
      try {
        await Future.wait([read, process.exitCode]).timeout(const Duration(seconds: 15));
      } on TimeoutException {
        process.kill();
        return null;
      }
      return output.toString();
    } on IOException {
      return null;
    }
  }

  @override
  Future<Map<String, Object?>?> liveStats() async {
    final engine = _engine;
    if (engine == null || !engine.running) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final response = await (await client.getUrl(engine.uri('/moe-stream/stats'))).close().timeout(const Duration(seconds: 2));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) return null;
      final json = jsonDecode(body);
      return json is Map ? json.cast<String, Object?>() : null;
    } on Exception {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<({int bytes, DateTime modified})?> modelFileInfo(ModelFile file) async {
    final stat = File(_modelPath(_local(file))).statSync();
    return stat.type == FileSystemEntityType.notFound ? null : (bytes: stat.size, modified: stat.modified);
  }

  @override
  Future<int?> countTokens(String text) async {
    final engine = _engine;
    if (engine == null || !engine.running) return null;
    final client = HttpClient();
    try {
      return await _countTokens(client, engine, text);
    } on Exception {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Tells the engine the pinned chats; it does not remember them between starts.
  Future<void> _sendPinned(EngineProcess engine) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.postUrl(engine.uri('/cache-disk/pins'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'pinned': _pinnedChats}));
      await (await request.close()).drain<void>();
    } on IOException {
      // The engine has ended: the next one is told when it starts.
    } finally {
      client.close(force: true);
    }
  }

  @override
  void forkBeforeFirstUse(String from, String to) {
    // A read ahead has copied it already: the conversation is in use now, so it is not cancelled any more.
    if (_readAheads.remove(to) != null || _forked.contains(to)) return;
    _forks[to] = from;
    _inheritLeftOut(from, to);
  }

  /// The new conversation leaves out the same oldest messages as the one it comes from (so what it sends is the
  /// same text, which the copied state matches).
  void _inheritLeftOut(String from, String to) {
    for (final key in [for (final k in _leftOut.keys) if (k.startsWith('$from@')) k]) {
      _leftOut['$to${key.substring(from.length)}'] = _leftOut[key]!;
    }
  }

  Future<void> _forkIfNeeded(EngineProcess engine, String to) async {
    final from = _forks.remove(to);
    if (from == null) return;
    _forked.add(to);
    await _fork(engine, from, to);
  }

  /// Has the engine copy conversation [from]'s saved state and snapshots to [to]; false (logged) if it could not.
  static Future<bool> _fork(EngineProcess engine, String from, String to) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.postUrl(engine.uri('/cache-disk/fork'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'from': from, 'to': to}));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 200) return true;
      stderr.writeln('Run My AI: the engine could not copy a chat state (${response.statusCode}): $body');
    } on IOException catch (e) {
      stderr.writeln('Run My AI: the engine could not copy a chat state: $e');
    } finally {
      client.close(force: true);
    }
    return false;
  }

  @override
  Future<bool> readAhead({
    required String from,
    required String to,
    required ModelFile model,
    required EngineRun run,
    required List<ChatMessage> messages,
    bool thinking = false,
  }) async {
    final local = _local(model);
    final engine = _engine;
    // Never starts or swaps the engine: only one already running this model, this way.
    if (engine == null || !isRunning(engine, local.model.files.first.id, run) || _readAheads.containsKey(to)) {
      return false;
    }
    final turn = _Turn(to);
    _forks.remove(to);
    _forked.add(to);
    _inheritLeftOut(from, to);
    _readAheads[to] = (turn, _readAhead(engine, turn, local, from, messages, thinking));
    return true;
  }

  Future<void> _readAhead(
    EngineProcess engine,
    _Turn turn,
    _LocalModel local,
    String from,
    List<ChatMessage> messages,
    bool thinking,
  ) async {
    final to = turn.chatId;
    try {
      await _fork(engine, from, to);
      if (turn.cancelled) return;
      final fitted = await _fit(engine, to, local, messages);
      if (turn.cancelled) return;
      final client = HttpClient();
      turn.begin(engine, client);
      try {
        final request = await client.postUrl(engine.uri('/v1/chat/completions'));
        request.headers
          ..contentType = ContentType.json
          ..set('X-Conversation-Id', to);
        request.write(
          jsonEncode({
            'messages': [
              for (final m in fitted) {'role': m.role.name, 'content': m.text},
            ],
            'n_predict': 0,
            'cache_prompt': true,
            'cache_disk_save': false,
            if (local.thinkingSwitch) 'chat_template_kwargs': {'enable_thinking': thinking},
          }),
        );
        await (await request.close()).drain<void>();
      } finally {
        if (!turn.cancelled) client.close(force: true);
      }
    } on Exception catch (e) {
      // Nothing is lost: the reply reads the chat itself.
      if (!turn.cancelled) stderr.writeln('Run My AI: could not read the chat ahead: $e');
    }
  }

  @override
  Future<void> cancelReadAhead(String conversationId) async {
    _forks.remove(conversationId);
    final going = _readAheads.remove(conversationId);
    if (going == null) return;
    // Its state is erased once its last request is out of the way, or the copy could come back.
    await going.$1.cancel();
    await going.$2;
    _forked.remove(conversationId);
    await eraseChatState(conversationId);
  }

  /// Has the running engine delete the state (it keeps a list of its files); false if it could not.
  static Future<bool> _eraseThrough(EngineProcess engine, String chatId) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.postUrl(engine.uri('/cache-disk/erase'));
      request.headers.set('X-Conversation-Id', chatId);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == 200;
    } on IOException {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> stopEngine() async {
    _stops++;
    final engine = _engine;
    _engine = null;
    final loading = _loadingEngine;
    await Future.wait([?engine?.stop(), ?loading?.stop()]);
    _engineState.value = const EngineState(EnginePhase.stopped);
  }

  /// Deletes the model's files from the models folder (never from a folder models are only read from), after
  /// stopping the engine if it runs that model.
  @override
  Future<void> deleteDownload(ModelFile file) async {
    if (_engine?.modelId == file.id || _loadingEngine?.modelId == file.id) await stopEngine();
    deleteModelFiles(_folders.models, file);
  }

  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) {
    late final StreamController<ReplyEvent> out;
    final turn = _Turn(chatId);
    out = StreamController<ReplyEvent>(
      onListen: () => unawaited(_write(out, turn, _local(model), messages, thinking, run, maxTokens)),
      onCancel: turn.cancel,
    );
    return out.stream;
  }

  Future<void> _write(
    StreamController<ReplyEvent> out,
    _Turn turn,
    _LocalModel local,
    List<ChatMessage> messages,
    bool thinking,
    EngineRun run,
    int? maxTokens,
  ) async {
    EngineProcess? engine;
    try {
      final loaded = isRunning(_engine, local.model.files.first.id, run);
      if (!loaded) out.add(ReplyLoading(local.model.name));
      engine = await _engineFor(local, run);
      if (!loaded && !turn.cancelled) out.add(const ReplyLoaded());
      if (turn.cancelled) return;
      await _forkIfNeeded(engine, turn.chatId);
      if (turn.cancelled) return;
      final fitted = await _fit(engine, turn.chatId, local, messages);
      if (turn.cancelled) return;
      await _stream(out, turn, engine, local, fitted, thinking, maxTokens, run);
    } on EngineFailure catch (failure) {
      if (!turn.cancelled) out.addError(failure);
    } on Exception {
      if (!turn.cancelled) out.addError(await _broken(engine));
    } finally {
      await out.close();
    }
  }

  /// The failure to report when the connection to [engine] broke.
  static Future<EngineFailure> _broken(EngineProcess? engine) async {
    // (A crash closes the connection a moment before the process is seen to have ended.)
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final message = engine == null || !engine.running
        ? 'The engine stopped unexpectedly.'
        : 'The connection to the engine broke.';
    return EngineFailure(message, log: engine?.lastLines(12) ?? const []);
  }

  Future<void> _stream(
    StreamController<ReplyEvent> out,
    _Turn turn,
    EngineProcess engine,
    _LocalModel local,
    List<ChatMessage> messages,
    bool thinking,
    int? maxTokens,
    EngineRun run,
  ) async {
    final client = HttpClient();
    turn.begin(engine, client);
    final reader = ChatStreamReader();
    final speed = LiveSpeed();
    final clock = Stopwatch()..start();
    final ticks = Timer.periodic(LiveSpeed.every, (_) {
      final live = speed.tick(clock.elapsed);
      if (live != null && !turn.cancelled) out.add(ReplySpeed(live: live, average: reader.average));
    });
    try {
      final request = await client.postUrl(engine.uri('/v1/chat/completions'));
      request.headers
        ..contentType = ContentType.json
        ..set('X-Conversation-Id', turn.chatId);
      request.write(
        jsonEncode({
          'messages': [
            for (final m in messages) {'role': m.role.name, 'content': m.text},
          ],
          'stream': true,
          'timings_per_token': true,
          if (run.reportProgress) 'return_progress': true,
          // (A benchmark's conversation is not kept: it would only use up the saved states' room.)
          if (!run.keepState) 'cache_disk_save': false,
          'max_tokens': ?maxTokens,
          if (local.thinkingSwitch) 'chat_template_kwargs': {'enable_thinking': thinking},
        }),
      );
      final response = await request.close();
      final lines = response.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter());
      if (response.statusCode != 200) {
        final body = (await lines.toList()).join('\n');
        throw EngineFailure('The engine could not answer: ${_message(body)}', log: engine.lastLines(12));
      }
      await for (final line in lines) {
        if (turn.cancelled) return;
        final List<ReplyEvent> pieces;
        try {
          pieces = reader.read(line);
        } on FormatException catch (e) {
          throw EngineFailure('The engine could not answer: ${e.message}', log: engine.lastLines(12));
        }
        speed.add(clock.elapsed, reader.written);
        pieces.forEach(out.add);
      }
      if (!reader.finished && !turn.cancelled) throw await _broken(engine);
      if (reader.average != null) out.add(ReplySpeed(average: reader.average));
      if (reader.finished) {
        out.add(ReplyDone(reader.timings, wordMillis: reader.wordMillis, finishReason: reader.finishReason));
      }
    } finally {
      ticks.cancel();
      if (!turn.cancelled) client.close(force: true);
    }
  }

  static String _message(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map<String, Object?> && json['error'] is Map<String, Object?>) {
        final message = (json['error']! as Map<String, Object?>)['message'];
        if (message is String) return message;
      }
    } on FormatException {
      // Not JSON: the text as it is.
    }
    return body;
  }

  /// How [run] starts an engine: an engine already running is the one asked for only if it was started with the
  /// same flags, memory cap and graphics card headroom.
  @visibleForTesting
  static String startedWith(EngineRun run) => '${run.memoryCapGiB}\n${run.vramHeadroomGiB}\n${run.flags}';

  /// Whether [engine] is the one asked for: running the model [modelId] at the length [run] says, started with its
  /// flags and memory cap. One started another way (a benchmark's test flags left running) is started again.
  @visibleForTesting
  static bool isRunning(EngineProcess? engine, String modelId, EngineRun run) =>
      engine != null &&
      engine.running &&
      engine.modelId == modelId &&
      engine.contextLength == run.contextLength &&
      engine.startedWith == startedWith(run);

  /// What of [messages] the model is sent: all of them, or without the oldest when they do not fit its context.
  Future<List<ChatMessage>> _fit(
    EngineProcess engine,
    String chatId,
    _LocalModel local,
    List<ChatMessage> messages,
  ) async {
    final key = '$chatId@${engine.contextLength}';
    final before = (_leftOut[key] ?? 0).clamp(0, messages.length - 1);
    final kept = messages.sublist(before);
    if (ContextFit.surelyFits(kept, engine.contextLength)) return kept;
    final known = _tokens.putIfAbsent(local.model.id, Expando<int>.new);
    final client = HttpClient();
    try {
      final tokens = [
        for (final m in kept) known[m] ??= await _countTokens(client, engine, m.text),
      ];
      final more = ContextFit.toDrop(kept, tokens, engine.contextLength);
      _leftOut[key] = before + more;
      return kept.sublist(more);
    } finally {
      client.close(force: true);
    }
  }

  static Future<int> _countTokens(HttpClient client, EngineProcess engine, String text) async {
    final request = await client.postUrl(engine.uri('/tokenize'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'content': text}));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return ((jsonDecode(body) as Map<String, Object?>)['tokens']! as List).length;
  }

  /// The engine running [local]'s model the way [run] says: the one already running if it was started that way
  /// (edits to a profile apply at the next send), or a new one once the old one has ended. Throws [EngineStopped]
  /// when the engine is stopped while this one loads.
  Future<EngineProcess> _engineFor(_LocalModel local, EngineRun run) {
    final before = _loading;
    return _loading = () async {
      try {
        await before;
      } on Exception {
        // That load failed and whoever asked for it has reported it.
      }
      final stops = _stops;
      final id = local.model.files.first.id;
      final current = _engine;
      if (isRunning(current, id, run)) return current!;
      _engine = null;
      await current?.stop();
      if (stops != _stops) throw const EngineStopped();
      _engineState.value = EngineState(EnginePhase.loading, modelId: id, run: run);
      try {
        final engine = await _start(local, run);
        if (stops != _stops) {
          await engine.stop();
          throw const EngineStopped();
        }
        _engine = engine;
        await _sendPinned(engine);
        _engineState.value = EngineState(EnginePhase.ready, modelId: id, run: run);
        unawaited(engine.exited.then((_) {
          if (identical(_engine, engine)) _engineState.value = const EngineState(EnginePhase.stopped);
        }));
        return engine;
      } on Exception {
        _engineState.value = const EngineState(EnginePhase.stopped);
        if (stops != _stops) throw const EngineStopped();
        rethrow;
      }
    }();
  }

  /// Starts the engine for [local]. [serve]: for other programs instead of the app's chats (see [startServing]).
  Future<EngineProcess> _start(
    _LocalModel local,
    EngineRun run, {
    ({int port, String alias, String apiKey})? serve,
  }) async {
    final prefs = _storage.readPrefs();
    final folder = _engineFolder;
    final states = _activeStateFolder;
    Directory(states).createSync(recursive: true);
    final program = '$folder/llama-server${Platform.isWindows ? '.exe' : ''}';
    if (!File(program).existsSync()) throw EngineFailure('The engine is not in this folder: $folder');
    if (!File(_modelPath(local)).existsSync()) throw EngineFailure('The model file is not on this computer: ${_modelPath(local)}');
    final tuned = await _tuned(local);
    // the table's row as the autotuner's card list now picks it (the first start may have shown another)
    final flags = EngineFlags.parse(
      withVramFree(_flagsFor(local)[run.contextLength] ?? run.flags, run.vramHeadroomGiB ?? defaultVramHeadroomGiB),
    );
    final port = serve?.port ?? await EngineProcess.freePort();
    final hosting = serve == null ? null : serveSetup(alias: serve.alias, apiKey: serve.apiKey, environment: flags.environment);
    final EngineProcess engine;
    try {
      engine = await EngineProcess.start(
        command: [
          ..._memoryCap(run.memoryCapGiB),
          program,
          '-m',
          _modelPath(local),
          ...withTuning([
            // the model's data files are next to it
            for (final a in flags.arguments) a.replaceAll('{models}', _modelFolder(local)),
          ], tuned),
          '--cache-disk',
          states,
          '--cache-disk-gb',
          '${prefs.stateLimitGiB}',
          '--cache-disk-checkpoints',
          '$_snapshots',
          '--host',
          '127.0.0.1',
          '--port',
          '$port',
          ...?hosting?.arguments,
        ],
        modelId: local.model.files.first.id,
        contextLength: run.contextLength,
        port: port,
        // (Never the engine a chat would reuse: it answers only to its key.)
        startedWith: serve == null ? startedWith(run) : 'serve\n${startedWith(run)}',
        environment: {
          ...(hosting?.environment ?? flags.environment),
          ...launcherEnvironment(installIdIn(_storage.dir), prefs.shareBenchmarks),
        },
        workingDirectory: folder,
        memoryCapBytes: _windowsJobCap(run.memoryCapGiB, tuned),
        onOutput: _logChanged.changed,
      );
      _lastEngine = engine;
      _logChanged.changed();
    } on ProcessException catch (e) {
      throw EngineFailure('The engine could not start: ${e.message}');
    }
    _loadingEngine = engine;
    try {
      await engine.waitUntilReady();
    } finally {
      if (identical(_loadingEngine, engine)) _loadingEngine = null;
    }
    return engine;
  }

  /// What tells the engine which program started it: the app, this install's random name (for the engine's own daily
  /// record) and, when the user does not share, that it must send nothing.
  static Map<String, String> launcherEnvironment(String installId, bool share) => {
    'TOKENWING_LAUNCHER': 'run-my-ai',
    'TOKENWING_INSTALL_ID': installId,
    if (!share) 'TOKENWING_NO_STATS': '1',
  };

  /// What hosting adds to the engine's start: the model name other programs use, the counters the hosting screen reads
  /// (GET /metrics), and the key in the engine's environment (LLAMA_API_KEY), not on its command line, so other
  /// programs on this computer cannot read it from the process list.
  static ({List<String> arguments, Map<String, String> environment}) serveSetup({
    required String alias,
    required String apiKey,
    Map<String, String> environment = const {},
  }) => (arguments: ['--alias', alias, '--metrics'], environment: {...environment, 'LLAMA_API_KEY': apiKey});

  /// Keeps the engine within headroom of RAM (default: all the RAM but 1 GB), so running out of memory ends only the
  /// engine.
  static List<String> _memoryCap(double? headroomGiB) {
    if (!Directory('/run/systemd/system').existsSync()) return const [];
    final total = RegExp(r'MemTotal:\s+(\d+) kB').firstMatch(File('/proc/meminfo').readAsStringSync());
    if (total == null) return const [];
    final totalKiB = int.parse(total[1]!);
    final headroomKiB = ((headroomGiB ?? defaultHeadroomGiB) * 1048576).round();
    final capKiB = (totalKiB - headroomKiB).clamp(4 * 1048576, totalKiB - 524288);
    return ['systemd-run', '--user', '--scope', '-q', '-p', 'MemoryMax=${capKiB}K', '-p', 'MemorySwapMax=0', '--'];
  }

  /// The Windows job's memory limit that leaves [headroomGiB] of RAM free (default [defaultHeadroomGiB]), as [_memoryCap] does on Linux:
  /// all the RAM but the headroom, at least 4 GiB and at most all but 0.5 GiB. Windows counts what a program puts in the
  /// graphics card's memory against the job's limit too, and the engine fills the card, so the job also gets the cards'
  /// video memory: the headroom then stays free in RAM. The cards are the autotuner's (every discrete card, any make;
  /// built-in GPUs share the RAM and are listed apart), else NVIDIA's read through NVML.
  static int? _windowsJobCap(double? headroomGiB, Map<String, dynamic>? tuned) {
    if (!Platform.isWindows) return null;
    final totalGiB = Win32Metrics().memory()?.totalGiB;
    if (totalGiB == null) return null;
    var bytes = ((totalGiB - (headroomGiB ?? defaultHeadroomGiB)).clamp(4.0, totalGiB - 0.5) * 1073741824).round();
    if (tuned?['gpus'] case final List cards when cards.isNotEmpty) {
      return bytes + cards.fold<int>(0, (sum, g) => sum + ((g as Map)['mib'] as int)) * 1048576;
    }
    final gpus = NvmlReader.open();
    if (gpus == null) return bytes;
    try {
      for (final reading in gpus.read().entries) {
        final gib = reading.value;
        if (reading.key.endsWith('.vramTotal') && gib != null) bytes += (gib * 1073741824).round();
      }
    } finally {
      gpus.close();
    }
    return bytes;
  }
}

class _Changed extends ChangeNotifier {
  void changed() => notifyListeners();
}

/// One reply being written, and how to stop it.
class _Turn {
  _Turn(this.chatId);

  final String chatId;
  var cancelled = false;
  EngineProcess? _engine;
  HttpClient? _client;

  void begin(EngineProcess engine, HttpClient client) {
    _engine = engine;
    _client = client;
  }

  /// The engine goes on writing until it is told to stop: closing the connection is not enough.
  Future<void> cancel() async {
    cancelled = true;
    final engine = _engine;
    final client = _client;
    if (engine == null || client == null) return;
    final stopper = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await stopper.deleteUrl(engine.uri('/v1/stream', {'conv_id': chatId}));
      await (await request.close()).drain<void>();
    } on IOException {
      // The engine has ended: nothing to stop.
    } finally {
      stopper.close(force: true);
      client.close(force: true);
    }
  }
}
