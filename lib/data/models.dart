import 'reply_stats.dart';

/// A model in the Store, with the files (quantizations) it can be downloaded as.
class CatalogModel {
  const CatalogModel({
    required this.id,
    required this.name,
    required this.lab,
    required this.parameters,
    required this.activeParameters,
    required this.madeBy,
    required this.country,
    required this.released,
    required this.type,
    required this.input,
    required this.output,
    required this.maxContext,
    required this.files,
    this.thinking = ModelThinking.none,
  });

  final String id;
  final String name;
  final String lab;
  final String parameters;
  final String activeParameters;

  /// The details shown under the card: who made it, where, when, what it is for, what it reads and writes, and its
  /// longest context. Written as the Store shows them.
  final String madeBy;
  final String country;
  final String released;
  final String type;
  final String input;
  final String output;
  final String maxContext;
  final List<ModelFile> files;
  final ModelThinking thinking;
}

/// Whether a model thinks before it answers: never, always, or as the user chooses.
enum ModelThinking { none, always, optional }

/// One downloadable file of a model: one quantization.
class ModelFile {
  const ModelFile({
    required this.id,
    required this.quantization,
    required this.sizeBytes,
    this.repo,
    this.parts = const [],
  });

  final String id;
  final String quantization;
  final int sizeBytes;

  /// The Hugging Face repo it is downloaded from ("owner/name"); null for a model that is not downloaded (the
  /// stand-in).
  final String? repo;

  /// The files it is made of in [repo], used together from one folder: the weights first (the file the engine loads),
  /// then its data files.
  final List<String> parts;
}

enum Role { user, assistant }

class ChatMessage {
  const ChatMessage(
    this.role,
    this.text, {
    this.bookmark = false,
    this.thinking = '',
    this.thinkingMillis,
    this.stopped = false,
    this.node,
    this.version = 0,
    this.versions = 1,
    this.conv,
    this.stats,
  });

  final Role role;
  final String text;

  /// The user marked it as a bookmark of the chat (a place to jump back to).
  final bool bookmark;

  /// What the model thought before this reply; empty when it did not.
  final String thinking;

  /// How long it thought; null while it still is (or when it did not).
  final int? thinkingMillis;

  /// The reply did not get to its end (it was stopped, failed, or the app was closed): with no words it shows a
  /// "Stopped" note where the answer would be.
  final bool stopped;

  /// Its number in its chat: each message, and each version of one, has its own, in the order they were made. Null
  /// for a message outside a saved chat.
  final int? node;

  /// Which version of this message it is (0 is the first) among [versions], the ones made at this place of the
  /// chat: an edited message or a reply written again is a new version, and each keeps its own later messages.
  final int version;
  final int versions;

  /// The conversation the engine keeps this message's saved state under; null: the chat's own id (every message
  /// before the first edit or new reply). A new version starts a new conversation, and the messages after it stay
  /// in it.
  final String? conv;

  /// How the reply went (what the card under it shows); null for a sent message and for a reply written without the
  /// engine's numbers.
  final ReplyStats? stats;

  ChatMessage copyWith(
          {String? text, bool? bookmark, String? thinking, int? thinkingMillis, bool? stopped, ReplyStats? stats}) =>
      ChatMessage(
        role,
        text ?? this.text,
        bookmark: bookmark ?? this.bookmark,
        thinking: thinking ?? this.thinking,
        thinkingMillis: thinkingMillis ?? this.thinkingMillis,
        stopped: stopped ?? this.stopped,
        node: node,
        version: version,
        versions: versions,
        conv: conv,
        stats: stats ?? this.stats,
      );

  ChatMessage withBookmark(bool bookmark) => copyWith(bookmark: bookmark);

  /// This reply as one that did not get to its end, having thought for [thinkingMillis] if that is not known yet.
  ChatMessage asStopped({int? thinkingMillis}) =>
      copyWith(stopped: true, thinkingMillis: this.thinkingMillis ?? (thinking.isEmpty ? null : thinkingMillis));

  Map<String, Object?> toJson() => {'role': role.name, 'text': text};

  factory ChatMessage.fromJson(Map<String, Object?> json) =>
      ChatMessage(Role.values.byName(json['role']! as String), json['text']! as String);
}

/// The part of the app a chat belongs to: each has its own chats.
enum ChatKind { chat, code }

/// A chat as the list shows it: everything but its messages (those are loaded when the chat is opened).
class ChatInfo {
  const ChatInfo({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.kind = ChatKind.chat,
    this.sort,
    this.archivedAt,
    this.modelId,
    this.contextLength,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final ChatKind kind;

  /// Its place among the chats of its day, set when the user drags it; null = by when it was last used. A new
  /// message clears it, so the chat goes to the top of Today.
  final double? sort;

  /// When it was archived; null = not archived. An archived chat is out of the list (in Archived) but works as
  /// usual; it stays archived until the user unarchives it.
  final DateTime? archivedAt;

  /// The model file this chat uses, and its context length in tokens; null until one is chosen for it.
  final String? modelId;
  final int? contextLength;

  bool get archived => archivedAt != null;

  ChatInfo withChoices({required String? modelId, required int? contextLength}) => ChatInfo(
      id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, kind: kind, sort: sort, archivedAt: archivedAt,
      modelId: modelId, contextLength: contextLength);

  /// When it was last active: its last message, or its archiving if later (the order of the archived chats).
  DateTime get lastActive => archivedAt != null && archivedAt!.isAfter(updatedAt) ? archivedAt! : updatedAt;

  /// What orders the chats of one day: the higher, the higher in the list.
  double get order => sort ?? updatedAt.millisecondsSinceEpoch.toDouble();

  ChatInfo withTitle(String title) => ChatInfo(
      id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, kind: kind, modelId: modelId, contextLength: contextLength, sort: sort, archivedAt: archivedAt);

  ChatInfo withSort(double sort) => ChatInfo(
      id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, kind: kind, modelId: modelId, contextLength: contextLength, sort: sort, archivedAt: archivedAt);

  /// A new message at [time]: it leaves any place it was dragged to; archived or not, it stays so.
  ChatInfo withUpdated(DateTime time) =>
      ChatInfo(id: id, title: title, createdAt: createdAt, updatedAt: time, kind: kind, modelId: modelId, contextLength: contextLength, archivedAt: archivedAt);

  /// Archived at [time], or (null) unarchived at [now]: it comes back as last used now, at the top of Today.
  ChatInfo withArchived(DateTime? time, {required DateTime now}) => time != null
      ? ChatInfo(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, kind: kind, modelId: modelId, contextLength: contextLength, sort: sort, archivedAt: time)
      : ChatInfo(id: id, title: title, createdAt: createdAt, updatedAt: now, kind: kind);
}

class Chat {
  const Chat({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
    this.kind = ChatKind.chat,
    this.nextNode = 0,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The messages shown: one path through the chat's versions (see [ChatMessage.versions]).
  final List<ChatMessage> messages;
  final ChatKind kind;

  /// The number the next new message gets ([ChatMessage.node]): one more than any message of the chat has, in any
  /// version.
  final int nextNode;

  Chat copyWith({String? title, DateTime? updatedAt, List<ChatMessage>? messages, int? nextNode}) => Chat(
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        messages: messages ?? this.messages,
        kind: kind,
        nextNode: nextNode ?? this.nextNode,
      );

  /// The conversation the engine answers the next message in: that of the last message shown ([ChatMessage.conv]),
  /// the chat's own id before any new version was made.
  String get conversationId => messages.isEmpty ? id : messages.last.conv ?? id;

  ChatInfo get info => ChatInfo(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, kind: kind);

  factory Chat.of(ChatInfo info, List<ChatMessage> messages, {int nextNode = 0}) => Chat(
      id: info.id,
      title: info.title,
      createdAt: info.createdAt,
      updatedAt: info.updatedAt,
      messages: messages,
      kind: info.kind,
      nextNode: nextNode);

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'messages': [for (final m in messages) m.toJson()],
      };

  factory Chat.fromJson(Map<String, Object?> json) => Chat(
        id: json['id']! as String,
        title: json['title']! as String,
        createdAt: DateTime.parse(json['createdAt']! as String),
        updatedAt: DateTime.parse(json['updatedAt']! as String),
        messages: [
          for (final m in json['messages']! as List) ChatMessage.fromJson((m as Map).cast<String, Object?>()),
        ],
      );
}

/// A chat's messages as shown (one path through its versions) and the number its next new message gets.
class ChatPath {
  const ChatPath(this.messages, this.nextNode);

  final List<ChatMessage> messages;
  final int nextNode;
}
