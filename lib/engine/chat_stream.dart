import 'dart:convert';

import '../backend/backend.dart';

/// Reads the lines of the engine's streamed chat reply (`data: {...}`), one at a time.
class ChatStreamReader {
  /// The reply ended by itself, as the engine says at its end.
  bool get finished => _finished;
  var _finished = false;

  /// The tokens of the reply written so far, as the engine counts them.
  int get written => _written;
  var _written = 0;

  /// The engine's average speed for the reply so far, in tokens a second.
  double? get average => _average;
  double? _average;

  /// The engine's latest timings for the reply, as it sent them.
  Map<String, Object?> get timings => _timings;
  Map<String, Object?> _timings = const {};

  /// Why the reply ended (`stop`, `length`); null while it goes on.
  String? get finishReason => _finishReason;
  String? _finishReason;

  /// The time each word of the reply took in milliseconds, as the engine counted it: the running total in each
  /// message's timings, taken apart. A message that brings several words shares their time evenly.
  List<double> get wordMillis => _wordMillis;
  final _wordMillis = <double>[];
  var _lastWords = 0;
  var _lastMillis = 0.0;

  /// The reply's pieces in [line]; throws [FormatException] with the engine's message if the line reports an error.
  List<ReplyEvent> read(String line) {
    final String data;
    if (line.startsWith('data:')) {
      data = line.substring(5).trim();
    } else if (line.startsWith('error:')) {
      throw FormatException(_errorIn(line.substring(6).trim()));
    } else {
      return const [];
    }
    if (data == '[DONE]') {
      _finished = true;
      return const [];
    }
    final Object? json = jsonDecode(data);
    if (json is! Map<String, Object?>) return const [];
    if (json['error'] != null) throw FormatException(_errorIn(data));
    _readTimings(json['timings']);
    final progress = json['prompt_progress'];
    final events = <ReplyEvent>[
      if (progress is Map<String, Object?>)
        ReplyProgress(
          processed: (progress['processed'] as num?)?.toInt() ?? 0,
          total: (progress['total'] as num?)?.toInt() ?? 0,
          cached: (progress['cache'] as num?)?.toInt() ?? 0,
          millis: (progress['time_ms'] as num?)?.toInt() ?? 0,
        ),
    ];
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) return events;
    final choice = choices.first as Map<String, Object?>;
    if (choice['finish_reason'] case final String reason) {
      _finished = true;
      _finishReason = reason;
    }
    final delta = choice['delta'];
    if (delta is! Map<String, Object?>) return events;
    return [
      ...events,
      if (delta['reasoning_content'] case final String thinking when thinking.isNotEmpty) ReplyThinking(thinking),
      if (delta['content'] case final String text when text.isNotEmpty) ReplyText(text),
    ];
  }

  void _readTimings(Object? timings) {
    if (timings is! Map<String, Object?>) return;
    _timings = timings;
    if (timings['predicted_n'] case final int written) {
      _written = written;
      if (timings['predicted_ms'] case final num millis when written > _lastWords) {
        final each = (millis - _lastMillis) / (written - _lastWords);
        for (var i = _lastWords; i < written; i++) {
          _wordMillis.add(each < 0 ? 0 : each);
        }
        _lastWords = written;
        _lastMillis = millis.toDouble();
      }
    }
    if (timings['predicted_per_second'] case final num speed when speed.isFinite && speed > 0) _average = speed.toDouble();
  }

  /// The message inside an error the engine sent as JSON; the text itself when it is something else.
  static String _errorIn(String text) {
    try {
      final json = jsonDecode(text);
      final error = json is Map<String, Object?> ? json['error'] ?? json : null;
      if (error is Map<String, Object?> && error['message'] is String) return error['message']! as String;
      if (error is String) return error;
    } on FormatException {
      // Not JSON: the text as it is.
    }
    return text;
  }
}
