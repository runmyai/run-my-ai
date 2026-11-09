import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';

/// The sections (Chat, Code) whose sidebar shows the archived chats in place of the list.
class ArchiveViewNotifier extends Notifier<Set<ChatKind>> {
  @override
  Set<ChatKind> build() => const {};

  void toggle(ChatKind kind) => state = state.contains(kind) ? ({...state}..remove(kind)) : {...state, kind};

  void close(ChatKind kind) => state = {...state}..remove(kind);
}

final archiveViewProvider = NotifierProvider<ArchiveViewNotifier, Set<ChatKind>>(ArchiveViewNotifier.new);
