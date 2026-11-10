import '../data/models.dart';

/// How a chat's messages are made to fit its context length: the oldest ones are left out of what the model sees (they
/// stay in the chat). Once messages are left out, the same ones stay out until the chat outgrows the room again, so the
/// engine can reuse its work from the last message.
class ContextFit {
  /// What a message costs besides its text (its role and the marks around it), in tokens.
  static const messageOverhead = 8;

  /// The tokens that must stay free for the reply.
  static int replyRoom(int contextLength) => contextLength ~/ 8;

  /// When too much is sent, messages go until this many tokens are left, so it does not happen again at once.
  static int target(int contextLength) => contextLength * 3 ~/ 4;

  /// Whether [messages] are sure to fit, without counting their tokens: a token is at least a third of a character.
  static bool surelyFits(List<ChatMessage> messages, int contextLength) {
    var most = 0;
    for (final m in messages) {
      most += m.text.length * 3 + messageOverhead;
    }
    return most <= contextLength - replyRoom(contextLength);
  }

  /// How many of the oldest messages to leave out, given each message's [tokens]; 0 when all of them fit. The last
  /// message always stays, and what is sent starts with a user's message.
  static int toDrop(List<ChatMessage> messages, List<int> tokens, int contextLength) {
    int costFrom(int start) {
      var cost = 0;
      for (var i = start; i < messages.length; i++) {
        cost += tokens[i] + messageOverhead;
      }
      return cost;
    }

    if (costFrom(0) <= contextLength - replyRoom(contextLength)) return 0;
    final last = messages.length - 1;
    var start = 0;
    while (start < last && costFrom(start) > target(contextLength)) {
      start++;
    }
    while (start < last && messages[start].role != Role.user) {
      start++;
    }
    return start;
  }
}
