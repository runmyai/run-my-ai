import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which message a thinking block belongs to: its chat and the message's number in it ([ChatMessage.node], so each
/// version of a message has its own block).
typedef ThinkingKey = ({String chatId, int index});

/// What is remembered of one message's thinking block, outside its widget.
class ThinkingView {
  const ThinkingView({this.since, this.open = false});

  /// When the model started to think, on the app's thinking clock; null for a message that was saved.
  final Duration? since;

  /// The user opened the block (it is closed until they do).
  final bool open;
}

/// The clock the thinking time is read from; a test replaces it.
final thinkingClockProvider = Provider<Duration Function()>((ref) {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
});

/// The thinking time and the open or closed state of each message's thinking block. They live here, not in the
/// block's widget, so leaving the chat, scrolling away and coming back changes neither.
class ThinkingNotifier extends Notifier<Map<ThinkingKey, ThinkingView>> {
  @override
  Map<ThinkingKey, ThinkingView> build() => const {};

  /// The model starts thinking for [key]'s message: its clock starts and the block is closed.
  void begin(ThinkingKey key) {
    state = {...state, key: ThinkingView(since: ref.read(thinkingClockProvider)())};
  }

  /// How long the model has been thinking for [key]'s message; null if it is not (or was never) thinking.
  int? elapsedMillis(ThinkingKey key) {
    final since = state[key]?.since;
    return since == null ? null : (ref.read(thinkingClockProvider)() - since).inMilliseconds;
  }

  /// Opens the block of [key]'s message, or closes it.
  void toggle(ThinkingKey key) {
    final view = state[key];
    state = {...state, key: ThinkingView(since: view?.since, open: !(view?.open ?? false))};
  }

  /// Forgets one message's block.
  void forget(ThinkingKey key) {
    if (state.containsKey(key)) state = {...state}..remove(key);
  }

  /// Forgets the blocks of [chatId]'s messages from place [from] on (the messages are gone or will be written again).
  void forgetFrom(String chatId, [int from = 0]) {
    if (!state.keys.any((k) => k.chatId == chatId && k.index >= from)) return;
    state = {
      for (final e in state.entries)
        if (e.key.chatId != chatId || e.key.index < from) e.key: e.value,
    };
  }
}

final thinkingProvider = NotifierProvider<ThinkingNotifier, Map<ThinkingKey, ThinkingView>>(ThinkingNotifier.new);

/// How long a thought is, as the block's title shows it: "12 s", "1 min 5 s". The same rounding is used while the
/// model thinks and afterwards, so the number never jumps when the thinking ends; at least 1 s.
String thoughtLength(int millis) {
  final seconds = math.max(1, (millis / 1000).round());
  return seconds < 60 ? '$seconds s' : '${seconds ~/ 60} min ${seconds % 60} s';
}

/// How many milliseconds until [thoughtLength] shows another number, after [millis] of thinking.
int millisToNextLength(int millis) {
  final next = millis < 1500 ? 1500 : 500 + 1000 * ((millis - 500) ~/ 1000 + 1);
  return next - millis;
}
