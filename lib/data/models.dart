/// A model in the Store, with the files (quantizations) it can be downloaded as.
class CatalogModel {
  const CatalogModel({
    required this.id,
    required this.name,
    required this.lab,
    required this.description,
    required this.parameters,
    required this.activeParameters,
    required this.files,
  });

  final String id;
  final String name;
  final String lab;
  final String description;
  final String parameters;
  final String activeParameters;
  final List<ModelFile> files;
}

/// One downloadable file of a model: one quantization.
class ModelFile {
  const ModelFile({required this.id, required this.quantization, required this.sizeBytes});

  final String id;
  final String quantization;
  final int sizeBytes;
}

enum Role { user, assistant }

class ChatMessage {
  const ChatMessage(this.role, this.text, {this.bookmark = false});

  final Role role;
  final String text;

  /// The user marked it as a bookmark of the chat (a place to jump back to).
  final bool bookmark;

  ChatMessage withBookmark(bool bookmark) => ChatMessage(role, text, bookmark: bookmark);

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

  bool get archived => archivedAt != null;

  /// When it was last active: its last message, or its archiving if later (the order of the archived chats).
  DateTime get lastActive => archivedAt != null && archivedAt!.isAfter(updatedAt) ? archivedAt! : updatedAt;

  /// What orders the chats of one day: the higher, the higher in the list.
  double get order => sort ?? updatedAt.millisecondsSinceEpoch.toDouble();

  ChatInfo withTitle(String title) => ChatInfo(
      id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, kind: kind, sort: sort, archivedAt: archivedAt);

  ChatInfo withSort(double sort) => ChatInfo(
      id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, kind: kind, sort: sort, archivedAt: archivedAt);

  /// A new message at [time]: it leaves any place it was dragged to; archived or not, it stays so.
  ChatInfo withUpdated(DateTime time) =>
      ChatInfo(id: id, title: title, createdAt: createdAt, updatedAt: time, kind: kind, archivedAt: archivedAt);

  /// Archived at [time], or (null) unarchived at [now]: it comes back as last used now, at the top of Today.
  ChatInfo withArchived(DateTime? time, {required DateTime now}) => time != null
      ? ChatInfo(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, kind: kind, sort: sort, archivedAt: time)
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
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ChatMessage> messages;
  final ChatKind kind;

  Chat copyWith({String? title, DateTime? updatedAt, List<ChatMessage>? messages}) => Chat(
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        messages: messages ?? this.messages,
        kind: kind,
      );

  ChatInfo get info => ChatInfo(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, kind: kind);

  factory Chat.of(ChatInfo info, List<ChatMessage> messages) => Chat(
      id: info.id,
      title: info.title,
      createdAt: info.createdAt,
      updatedAt: info.updatedAt,
      messages: messages,
      kind: info.kind);

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
