import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The version in the output of `llama-server --version` ("version: 0.8.0-dev (build 12270, commit 1d839794e)"), as
/// "0.8.0-dev (build 12270, commit 1d839794e)"; null when the output has no such line.
String? parseEngineVersion(String output) {
  for (final line in output.split('\n')) {
    final match = RegExp(r'^version:\s*(\S.*?)\s*$').firstMatch(line);
    if (match != null) return match[1];
  }
  return null;
}

/// The version of the engine in [folder], asked from its own program; null when it cannot be run, does not answer
/// within a few seconds, or does not say.
Future<String?> readEngineVersion(String folder) async {
  final program = '$folder/llama-server${Platform.isWindows ? '.exe' : ''}';
  if (!File(program).existsSync()) return null;
  try {
    final process = await Process.start(program, ['--version'], workingDirectory: folder);
    // The engine prints the version on the standard error stream: read both.
    final output = StringBuffer();
    final read = Future.wait([
      for (final stream in [process.stdout, process.stderr])
        stream.transform(const Utf8Decoder(allowMalformed: true)).forEach(output.write),
    ]);
    try {
      await Future.wait([read, process.exitCode]).timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill();
      return null;
    }
    return parseEngineVersion(output.toString());
  } on IOException {
    return null;
  }
}
