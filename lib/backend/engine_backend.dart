import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../data/storage.dart';
import '../engine/auto_commands.dart';
import '../engine/chat_states.dart';
import '../engine/chat_stream.dart';
import '../engine/context_fit.dart';
import '../engine/engine_flags.dart';
import '../engine/engine_process.dart';
import '../engine/gguf.dart';
import '../engine/live_speed.dart';
import 'backend.dart';

/// The models on this computer and how each one starts.
class _LocalModel {
  const _LocalModel({required this.model, required this.path, required this.flags, this.thinkingSwitch = false});

  final CatalogModel model;
  final String path;

  /// One command per context length.
  final Map<int, String> flags;

  /// Its thinking can be turned off.
  final bool thinkingSwitch;
}

/// The real engine: TokenWing's llama-server, started directly by the app. One model is loaded at a time: the first
/// message loads it, a message for another model swaps it.
class EngineBackend implements Backend, EngineControl, BranchControl, EngineInsight {
  EngineBackend(this._storage);

  final Storage _storage;

  static const _root = '/run/media/Harin/Shared/Projects/MoE_Lab';

  /// Where the chats' saved states and snapshots are kept: one file per state, next to the models.
  static const stateFolder = '$_root/traces/run-my-ai-states';

  /// How many "start of message" snapshots each chat keeps.
  static const _snapshots = 4;

  /// The chats whose saved states go last.
  List<String> _pinnedChats = const [];

  /// Where the engine is until the user sets another folder.
  static const defaultEngineFolder = '$_root/llama.cpp/build/bin';

  static const _lingFile = ModelFile(id: 'ling-3.0-flash/MXFP4_MOE', quantization: 'MXFP4', sizeBytes: 70147512048);
  static const _flintFile = ModelFile(id: 'flint-40b/UD-Q4_K_XL', quantization: 'UD-Q4_K_XL', sizeBytes: 25055397324);

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
      path: '$_root/traces/phase1/flash/Ling-3.0-flash-MXFP4_MOE.tokenwing.gguf',
      flags: lingAuto,
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
      path: '$_root/traces/flint/flint-UD-Q4_K_XL.tokenwing.gguf',
      flags: flintAuto,
    ),
  ];

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

  /// Models are read from where they already are on this computer; nothing is fetched yet.
  @override
  Stream<double> download(ModelFile file) => File(_local(file).path).existsSync()
      ? Stream.value(1)
      : Stream.error(EngineFailure('The model file is not on this computer: ${_local(file).path}'));

  @override
  Map<int, String> autoCommands(ModelFile file) => _local(file).flags;

  @override
  int maxContext(ModelFile file) => _maxContexts[file.id] ??= () {
    final local = _local(file);
    return modelContextLength(local.path) ?? local.flags.keys.reduce(max);
  }();

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
  Future<void> eraseChatState(String chatId) async {
    final engine = _engine;
    if (engine != null && engine.running && await _eraseThrough(engine, chatId)) return;
    deleteChatStates(stateFolder, chatId);
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
    final folder = _storage.readPrefs().engineFolder ?? defaultEngineFolder;
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
    final stat = File(_local(file).path).statSync();
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

  /// The model files are never deleted by the app.
  @override
  Future<void> deleteDownload(ModelFile file) async {}

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
  /// same flags and memory cap.
  @visibleForTesting
  static String startedWith(EngineRun run) => '${run.memoryCapGiB}\n${run.flags}';

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

  Future<EngineProcess> _start(_LocalModel local, EngineRun run) async {
    final prefs = _storage.readPrefs();
    final folder = prefs.engineFolder ?? defaultEngineFolder;
    Directory(stateFolder).createSync(recursive: true);
    final program = '$folder/llama-server';
    if (!File(program).existsSync()) throw EngineFailure('The engine is not in this folder: $folder');
    if (!File(local.path).existsSync()) throw EngineFailure('The model file is not on this computer: ${local.path}');
    final flags = EngineFlags.parse(run.flags);
    final port = await EngineProcess.freePort();
    final EngineProcess engine;
    try {
      engine = await EngineProcess.start(
        command: [
          ..._memoryCap(run.memoryCapGiB),
          program,
          '-m',
          local.path,
          ...flags.arguments,
          '--cache-disk',
          stateFolder,
          '--cache-disk-gb',
          '${prefs.stateLimitGiB}',
          '--cache-disk-checkpoints',
          '$_snapshots',
          '--host',
          '127.0.0.1',
          '--port',
          '$port',
        ],
        modelId: local.model.files.first.id,
        contextLength: run.contextLength,
        port: port,
        startedWith: startedWith(run),
        environment: flags.environment,
        workingDirectory: folder,
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

  /// Keeps the engine within headroom of RAM (default: all the RAM but 1 GB), so running out of memory ends only the
  /// engine.
  static List<String> _memoryCap(double? headroomGiB) {
    if (!Directory('/run/systemd/system').existsSync()) return const [];
    final total = RegExp(r'MemTotal:\s+(\d+) kB').firstMatch(File('/proc/meminfo').readAsStringSync());
    if (total == null) return const [];
    final totalKiB = int.parse(total[1]!);
    final headroomKiB = ((headroomGiB ?? 1.0) * 1048576).round();
    final capKiB = (totalKiB - headroomKiB).clamp(4 * 1048576, totalKiB - 524288);
    return ['systemd-run', '--user', '--scope', '-q', '-p', 'MemoryMax=${capKiB}K', '-p', 'MemorySwapMax=0', '--'];
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
