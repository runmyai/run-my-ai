import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'win32_job.dart';

/// The engine could not start or stopped answering. [log]: its last lines of output.
class EngineFailure implements Exception {
  const EngineFailure(this.message, {this.log = const []});

  final String message;
  final List<String> log;

  @override
  String toString() => message;
}

/// The engine was stopped on purpose while it was still loading its model.
class EngineStopped extends EngineFailure {
  const EngineStopped() : super('The engine was stopped while it loaded the model.');
}

/// One running engine (llama-server) with its model, closed with the app even if the app crashes.
///
/// The engine runs under a small watcher that waits on a pipe from the app. The operating system closes that pipe
/// however the app ends, so the watcher then stops the engine: politely first, and by force if it has not stopped
/// within [_graceSeconds] seconds.
class EngineProcess {
  EngineProcess._(
    this._process, {
    required this.modelId,
    required this.contextLength,
    required this.port,
    required this.startedWith,
    this.onOutput,
    this._win32Job,
  }) {
    void read(Stream<List<int>> output) => output
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_addLine, onError: (Object _) {});
    read(_process.stdout);
    read(_process.stderr);
    exited = _process.exitCode.then((code) {
      _running = false;
      _win32Job?.close();
      return code;
    });
  }

  /// Starts [command] (the program and its arguments) under the watcher (POSIX) or Job Object (Windows).
  static Future<EngineProcess> start({
    required List<String> command,
    required String modelId,
    int contextLength = 0,
    required int port,
    String startedWith = '',
    Map<String, String> environment = const {},
    String? workingDirectory,
    void Function()? onOutput,
  }) async {
    if (Platform.isWindows) {
      final process = await Process.start(
        command.first,
        command.sublist(1),
        environment: environment,
        workingDirectory: workingDirectory,
      );
      final job = Win32Job.attach(process.pid);
      return EngineProcess._(
        process,
        modelId: modelId,
        contextLength: contextLength,
        port: port,
        startedWith: startedWith,
        onOutput: onOutput,
        win32Job: job,
      );
    }
    final process = await Process.start(
      '/bin/sh',
      ['-c', _watcher, 'run-my-ai-engine', ...command],
      environment: environment,
      workingDirectory: workingDirectory,
    );
    return EngineProcess._(
      process,
      modelId: modelId,
      contextLength: contextLength,
      port: port,
      startedWith: startedWith,
      onOutput: onOutput,
    );
  }

  static const _graceSeconds = 5;
  static const _keptLines = 400;

  // The app's pipe is standard input. The engine must not hold it, or the pipe would never close.
  static const _watcher = '''
exec 3<&0
"\$@" 3<&- </dev/null &
engine=\$!
{
  read -r _ <&3
  kill -TERM "\$engine" 2>/dev/null
  n=0
  while [ "\$n" -lt $_graceSeconds ] && kill -0 "\$engine" 2>/dev/null; do sleep 1; n=\$((n+1)); done
  kill -KILL "\$engine" 2>/dev/null
} >/dev/null 2>&1 &
watcher=\$!
exec 3<&-
wait "\$engine"
code=\$?
kill "\$watcher" 2>/dev/null
exit "\$code"
''';

  final Process _process;
  final Win32Job? _win32Job;

  /// Called after each new line of output.
  final void Function()? onOutput;
  final _lines = <String>[];
  var _running = true;

  /// The model file it runs.
  final String modelId;

  /// The context length it runs with.
  final int contextLength;
  final int port;

  /// How it was started (its flags and memory cap, in whatever form the caller compares them): an engine started
  /// another way is not the one asked for.
  final String startedWith;

  /// Completes with its exit code when it has ended.
  late final Future<int> exited;

  bool get running => _running;

  /// Its output so far, the most recent lines only.
  List<String> get log => List.unmodifiable(_lines);

  /// Its last [count] lines of output.
  List<String> lastLines(int count) => _lines.sublist(_lines.length > count ? _lines.length - count : 0);

  Uri uri(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: port, path: path, queryParameters: query);

  void _addLine(String line) {
    _lines.add(line);
    if (_lines.length > _keptLines) _lines.removeAt(0);
    onOutput?.call();
  }

  /// Returns when the model is loaded and the engine answers; throws [EngineFailure] if it ends first.
  Future<void> waitUntilReady() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      while (true) {
        if (!_running) throw EngineFailure('The engine stopped while loading the model.', log: lastLines(_failureLines));
        if (await _healthy(client)) return;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } finally {
      client.close(force: true);
    }
  }

  static const _failureLines = 12;

  Future<bool> _healthy(HttpClient client) async {
    try {
      final response = await (await client.getUrl(uri('/health'))).close();
      await response.drain<void>();
      return response.statusCode == 200; // 503 while the model loads.
    } on IOException {
      return false;
    }
  }

  /// Stops the engine and returns when it has ended.
  Future<void> stop() async {
    if (Platform.isWindows) {
      _process.kill();
      try {
        await exited.timeout(const Duration(seconds: _graceSeconds));
      } on TimeoutException {
        _win32Job?.close();
        await exited;
      }
      return;
    }
    try {
      await _process.stdin.close();
    } on IOException {
      // The watcher is already gone.
    }
    await exited;
  }

  /// A port nothing is using now.
  static Future<int> freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }
}
