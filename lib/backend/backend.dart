import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../engine/engine_process.dart';

/// The context length of a fresh install, in tokens.
const defaultContextLength = 65536;

/// What happens while a reply is being written.
sealed class ReplyEvent {
  const ReplyEvent();
}

/// A piece of the reply itself.
class ReplyText extends ReplyEvent {
  const ReplyText(this.text);
  final String text;
}

/// A piece of what the model thinks before it answers.
class ReplyThinking extends ReplyEvent {
  const ReplyThinking(this.text);
  final String text;
}

/// How fast the reply is being written, in tokens a second. [live]: right now; [average]: over the reply so far.
class ReplySpeed extends ReplyEvent {
  const ReplySpeed({this.live, this.average});
  final double? live;
  final double? average;
}

/// The reply has ended by itself. [timings]: the engine's own numbers for it.
class ReplyDone extends ReplyEvent {
  const ReplyDone(this.timings, {this.wordMillis = const [], this.finishReason});
  final Map<String, Object?> timings;

  /// The time each word took as the engine counted it, in milliseconds; empty when it did not give them per word.
  final List<double> wordMillis;

  /// Why it ended: `stop` (the model stopped) or `length` (the longest allowed reply was reached).
  final String? finishReason;
}

/// How far the engine is in reading the prompt: [processed] of [total] tokens (the [cached] ones were not read again),
/// [millis] after it began. Only when the request asks for it ([EngineRun.reportProgress]).
class ReplyProgress extends ReplyEvent {
  const ReplyProgress({required this.processed, required this.total, this.cached = 0, this.millis = 0});
  final int processed;
  final int total;
  final int cached;
  final int millis;
}

/// The model is being loaded before it can answer.
class ReplyLoading extends ReplyEvent {
  const ReplyLoading(this.modelName);
  final String modelName;
}

/// The model is loaded.
class ReplyLoaded extends ReplyEvent {
  const ReplyLoaded();
}

/// How to run a model: the engine's flags, the context length they set, and the memory cap.
class EngineRun {
  const EngineRun({
    required this.flags,
    required this.contextLength,
    this.memoryCapGiB,
    this.keepState = true,
    this.reportProgress = false,
  });

  final String flags;
  final int contextLength;

  /// Null: all the RAM but 1 GB.
  final double? memoryCapGiB;

  /// What a request asks besides the chat (these do not change how the engine starts): whether the engine saves the
  /// conversation's state when the reply ends, and whether it reports how far it is in reading the prompt.
  final bool keepState;
  final bool reportProgress;

  EngineRun withFlags(String flags) => EngineRun(
    flags: flags,
    contextLength: contextLength,
    memoryCapGiB: memoryCapGiB,
    keepState: keepState,
    reportProgress: reportProgress,
  );

  EngineRun forBenchmark() => EngineRun(
    flags: flags,
    contextLength: contextLength,
    memoryCapGiB: memoryCapGiB,
    keepState: false,
    reportProgress: true,
  );
}

/// Everything the app needs from the side that has the models.
abstract class Backend {
  Future<List<CatalogModel>> loadCatalog();

  /// Download progress from 0 to 1. Cancelling the subscription cancels the download.
  Stream<double> download(ModelFile file);

  Future<void> deleteDownload(ModelFile file);

  /// The reply to the last message, piece by piece. Cancelling the subscription stops it. [thinking]: the model
  /// thinks before it answers, for a model that can choose. Ends with an EngineFailure error if the engine fails.
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  });

  /// The commands [file] comes with, by context length.
  Map<int, String> autoCommands(ModelFile file);

  /// The longest context [file] can run with, as the model itself says.
  int maxContext(ModelFile file);
}

/// What the engine is doing.
enum EnginePhase { stopped, loading, ready }

class EngineState {
  const EngineState(this.phase, {this.modelId, this.run});

  final EnginePhase phase;

  /// The model file it is loading or running, and how.
  final String? modelId;
  final EngineRun? run;
}

/// A backend with an engine that can be started and watched from the Engine page.
abstract class EngineControl {
  ValueListenable<EngineState> get engineState;

  /// The engine's output, the most recent lines; [logChanged] tells when there is more.
  List<String> get logLines;
  Listenable get logChanged;

  /// Loads [file] the way [run] says; with [restart], even if it is already loaded.
  Future<void> startEngine(ModelFile file, EngineRun run, {bool restart = false});

  Future<void> stopEngine();

  /// Deletes the chat's saved state and snapshots.
  Future<void> eraseChatState(String chatId);

  /// The chats whose saved states should be the last to go when the folder is full.
  Future<void> setPinnedChats(List<String> chatIds);

  /// The version the running engine reports about itself; null when no engine is running or it does not say.
  Future<String?> reportedVersion();
}

/// A backend that can tell more about its engine than the chat needs: what its program accepts and what it counts while
/// it runs. The Benchmark tab uses it; each part is optional, so a missing one only leaves its numbers out.
abstract class EngineInsight {
  /// Whether the engine's program lists [flag] among its options; false when that cannot be told.
  Future<bool> acceptsFlag(String flag);

  /// The running engine's counters (GET /moe-stream/stats) as a JSON map; null when it is not running or has no such
  /// route.
  Future<Map<String, Object?>?> liveStats();

  /// The size and last change of the model file.
  Future<({int bytes, DateTime modified})?> modelFileInfo(ModelFile file);

  /// How many tokens the running engine counts in [text]; null when it cannot say.
  Future<int?> countTokens(String text);
}

/// A backend that keeps a saved state for each branch of a chat (a conversation id each) and can prepare a new
/// branch from the one it came from.
abstract class BranchControl {
  /// The saved state and snapshots of conversation [from] are copied to the new conversation [to] before the first
  /// request that uses [to]. A copy that fails is logged and the request goes ahead: the engine reads the chat
  /// again once.
  void forkBeforeFirstUse(String from, String to);

  /// Reads [messages], the chat up to where an edit will start, into the engine's memory as conversation [to] (a
  /// copy of [from]), without writing a reply or any saved state, so the edited message's reply does not read the
  /// shared part again. Only when the engine is already running [model] the way [run] says: it never starts or
  /// swaps the engine. Returns whether it started.
  Future<bool> readAhead({
    required String from,
    required String to,
    required ModelFile model,
    required EngineRun run,
    required List<ChatMessage> messages,
    bool thinking = false,
  });

  /// Stops the read-ahead of conversation [conversationId], if one is going, and erases that conversation's saved
  /// state.
  Future<void> cancelReadAhead(String conversationId);
}

/// The port asked for is already in use by another program.
class PortInUse extends EngineFailure {
  PortInUse(this.port) : super('Port $port is already in use by another program. Pick another port.');

  final int port;
}

/// A backend that can host a model for other programs on this computer (any tool that takes an OpenAI-compatible
/// server).
abstract class ServeControl {
  /// Stops whatever engine is running, then loads [file] the way [run] says and answers other programs on this
  /// computer's own address, at [port], under the model name [alias] and, when [apiKey] is not null, only with that
  /// key. Returns when the model is loaded. Throws [PortInUse] or an [EngineFailure]. [onEnded]: the engine ended
  /// later on its own (or another start replaced it), with the failure that says so.
  Future<void> startServing(
    ModelFile file,
    EngineRun run, {
    required int port,
    required String alias,
    String? apiKey,
    void Function(EngineFailure ended)? onEnded,
  });

  Future<void> stopServing();
}
