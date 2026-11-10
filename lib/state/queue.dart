import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// Why a chat's waiting messages are not going out: the user stopped a reply, or the engine failed. The second ends
/// with a successful Try again; the first only with Send next.
enum QueueHold { stopped, failed }

class QueuedMessage {
  const QueuedMessage(this.id, this.text);

  /// Tells it from the others while the list is reordered.
  final int id;
  final String text;
}

class ChatQueue {
  const ChatQueue(this.messages, {this.hold});

  final List<QueuedMessage> messages;

  /// Set while the messages wait for the user; null: each goes out when the reply before it ends.
  final QueueHold? hold;
}

/// The messages waiting to be sent, by chat. Saved to queues.json on every change; after a restart they are on hold.
class QueueNotifier extends Notifier<Map<String, ChatQueue>> {
  var _nextId = 0;

  @override
  Map<String, ChatQueue> build() {
    return {
      for (final MapEntry(key: chatId, value: texts) in ref.read(storageProvider).readQueues().entries)
        chatId: ChatQueue([for (final text in texts) QueuedMessage(_nextId++, text)], hold: QueueHold.stopped),
    };
  }

  void add(String chatId, String text) {
    final queue = state[chatId];
    _set(chatId, ChatQueue([...?queue?.messages, QueuedMessage(_nextId++, text)], hold: queue?.hold));
  }

  void remove(String chatId, int id) {
    final queue = state[chatId];
    if (queue == null) return;
    _set(chatId, ChatQueue([for (final m in queue.messages) if (m.id != id) m], hold: queue.hold));
  }

  /// The chat is gone: its waiting messages too.
  void forget(String chatId) {
    if (state.containsKey(chatId)) _changed({...state}..remove(chatId));
  }

  /// Moves the message at [from] so it ends up at [to].
  void move(String chatId, int from, int to) {
    final queue = state[chatId];
    if (queue == null || from < 0 || from >= queue.messages.length) return;
    final messages = [...queue.messages];
    messages.insert(to.clamp(0, messages.length - 1), messages.removeAt(from));
    _set(chatId, ChatQueue(messages, hold: queue.hold));
  }

  /// Takes the first waiting message off the queue; null when none is waiting.
  String? take(String chatId) {
    final queue = state[chatId];
    if (queue == null || queue.messages.isEmpty) return null;
    _set(chatId, ChatQueue(queue.messages.sublist(1), hold: queue.hold));
    return queue.messages.first.text;
  }

  /// Puts the chat's waiting messages on hold, unless they already are.
  void hold(String chatId, QueueHold why) {
    final queue = state[chatId];
    if (queue != null && queue.hold == null) _set(chatId, ChatQueue(queue.messages, hold: why));
  }

  /// Lets the chat's waiting messages go out again. [only]: only if they are on hold for that reason.
  void release(String chatId, {QueueHold? only}) {
    final queue = state[chatId];
    if (queue == null || queue.hold == null || (only != null && queue.hold != only)) return;
    _set(chatId, ChatQueue(queue.messages));
  }

  void _set(String chatId, ChatQueue queue) {
    _changed(queue.messages.isEmpty ? ({...state}..remove(chatId)) : {...state, chatId: queue});
  }

  void _changed(Map<String, ChatQueue> queues) {
    state = queues;
    ref.read(storageProvider).writeQueues({
      for (final MapEntry(key: chatId, value: queue) in queues.entries)
        chatId: [for (final m in queue.messages) m.text],
    });
  }
}

final queueProvider = NotifierProvider<QueueNotifier, Map<String, ChatQueue>>(QueueNotifier.new);
