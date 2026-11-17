import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/backend.dart';
import '../benchmark/hardware.dart';
import '../system/firebase.dart';
import 'about.dart';
import 'providers.dart';

enum FeedbackKind {
  idea('idea', 'Idea'),
  bug('bug', 'Bug'),
  love('love', 'Love it');

  const FeedbackKind(this.id, this.label);

  /// The name the database knows it by.
  final String id;
  final String label;
}

/// The longest values the database accepts, in characters.
const feedbackMessageMax = 5000;
const feedbackEmailMax = 254;
const feedbackLogMax = 200000;

/// [text] cut to at most [max] characters (whole Unicode characters, as the database counts them).
String cutText(String text, int max) {
  final runes = text.runes;
  return runes.length <= max ? text : String.fromCharCodes(runes.take(max));
}

// The engine's output as a bug report may carry it: never any chat text. At its normal log level llama-server writes
// no prompt or reply text, but a few of its lines can quote what it was sent: an error or exception message (a request
// that could not be parsed is quoted in part), the prompt-cache debug lines (old: / new: with the tokens around a
// difference), a request's JSON at a higher log level. Its own log lines start with a time and a level letter, and a
// message with line breaks goes on without that start on the next lines; the engine's other lines (the model's load,
// the RAM / VRAM plan) start with the name of the part that wrote them and a colon. So a line is kept only when it has
// one of those two starts; a server line is dropped when it has a mark of a quoting line, and so are the lines that
// follow it without a start of their own. (The named lines come from the model's load and the engine's own parts, which
// never see a message: an error there, such as the graphics card running out of memory, stays.)
final _loggerLine = RegExp(r'^\d+\.\d+\.\d+\.\d+ [A-Z] ');
final _namedLine = RegExp(r'^(?:[A-Za-z_][A-Za-z0-9_]*: |(?:CUDA|ROCm|HIP|Vulkan) error: |\s+(?:Device \d+|current device): )');
final _quoting = RegExp(
  r'exception|error: |failed to parse|old: \.\.\.|new: \.\.\.|example_format|image from|anthropic|command pipe'
  r'|"(?:content|messages|prompt|text|input|system)"',
  caseSensitive: false,
);

/// The engine's output [lines] with every line that could hold chat text left out, home folders shown as `~`, and the
/// last part kept when it is longer than [max] characters.
String cleanEngineLog(List<String> lines, {int max = feedbackLogMax, String? home, String? user}) {
  final kept = <String>[];
  var dropping = false;
  for (final line in lines) {
    if (_loggerLine.hasMatch(line)) {
      dropping = _quoting.hasMatch(line);
    } else if (!_namedLine.hasMatch(line)) {
      // (Not a line of its own: it goes with the line before it.)
      continue;
    }
    if (dropping) continue;
    var clean = line;
    if (home != null && home.length > 1) clean = clean.replaceAll(home, '~');
    if (user != null && user.isNotEmpty) clean = clean.replaceAll('/$user/', '/user/').replaceAll('\\$user\\', '\\user\\');
    kept.add(clean);
  }
  // The last lines that fit (a line counted with its line break).
  var size = 0, first = kept.length;
  while (first > 0 && size + kept[first - 1].runes.length + 1 <= max) {
    size += kept[--first].runes.length + 1;
  }
  return kept.sublist(first).join('\n');
}

/// The document a feedback sends: exactly the fields the database's rules allow, each within its limit.
Map<String, Object?> feedbackDocument({
  required FeedbackKind kind,
  required String message,
  String? email,
  String? log,
  String? appVersion,
  String? os,
}) {
  final mail = email?.trim() ?? '';
  return {
    'kind': kind.id,
    'message': cutText(message.trim(), feedbackMessageMax),
    if (mail.isNotEmpty) 'email': cutText(mail, feedbackEmailMax),
    if (log != null && log.isNotEmpty) 'log': cutText(log, feedbackLogMax),
    if (appVersion != null) 'appVersion': cutText(appVersion, 40),
    if (os != null && os.isNotEmpty) 'os': cutText(os, 100),
  };
}

enum FeedbackPhase { editing, sending, sent, failed }

class FeedbackState {
  const FeedbackState({this.kind = FeedbackKind.idea, this.attachLog = false, this.phase = FeedbackPhase.editing});

  final FeedbackKind kind;

  /// Whether the engine's log goes with it: on by default for a bug.
  final bool attachLog;
  final FeedbackPhase phase;

  FeedbackState copyWith({FeedbackKind? kind, bool? attachLog, FeedbackPhase? phase}) =>
      FeedbackState(kind: kind ?? this.kind, attachLog: attachLog ?? this.attachLog, phase: phase ?? this.phase);
}

/// The system's name and version (the tests give their own).
final systemNameProvider = Provider<String Function()>((ref) => () => SystemReader(const DiskFiles()).info().os);

/// The feedback form: its choices, and sending it. A new form starts fresh.
class FeedbackNotifier extends Notifier<FeedbackState> {
  @override
  FeedbackState build() => const FeedbackState();

  void setKind(FeedbackKind kind) => state = state.copyWith(kind: kind, attachLog: kind == FeedbackKind.bug);

  void setAttachLog(bool on) => state = state.copyWith(attachLog: on);

  /// Back to the form after a failed send.
  void edit() => state = state.copyWith(phase: FeedbackPhase.editing);

  Future<void> send(String message, String email) async {
    if (state.phase == FeedbackPhase.sending || message.trim().isEmpty) return;
    state = state.copyWith(phase: FeedbackPhase.sending);
    final backend = ref.read(backendProvider);
    final env = Platform.environment;
    final log = state.attachLog && backend is EngineControl
        ? cleanEngineLog(
            (backend as EngineControl).logLines,
            home: env['HOME'] ?? env['USERPROFILE'],
            user: env['USER'] ?? env['USERNAME'],
          )
        : null;
    String? os;
    try {
      os = ref.read(systemNameProvider)();
    } on Object {
      os = Platform.operatingSystem;
    }
    try {
      await ref.read(firestoreProvider).create(
        'feedback',
        feedbackDocument(kind: state.kind, message: message, email: email, log: log, appVersion: appVersion, os: os),
      );
      if (ref.mounted) state = state.copyWith(phase: FeedbackPhase.sent);
    } on FirestoreFailure catch (e) {
      debugPrint('Feedback not sent: $e');
      if (ref.mounted) state = state.copyWith(phase: FeedbackPhase.failed);
    }
  }
}

final feedbackProvider = NotifierProvider.autoDispose<FeedbackNotifier, FeedbackState>(FeedbackNotifier.new);
