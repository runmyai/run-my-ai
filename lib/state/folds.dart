import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import 'chats.dart';
import 'providers.dart';
import 'search.dart';

/// The chat list's folded groups, for each section (Chat, Code): "pinned", or a day as "2026-10-30" (so a day
/// folded today is still folded tomorrow, under Yesterday). Saved to folds.json on every change.
class FoldsNotifier extends Notifier<Map<ChatKind, Set<String>>> {
  @override
  Map<ChatKind, Set<String>> build() {
    // A search match opened in a folded group: the group opens.
    ref.listen(findProvider, (_, find) {
      final chats = ref.read(chatsProvider);
      final chat = find == null ? null : chats.byId(find.chatId);
      if (chat == null) return;
      open(chat.kind, dayKey(chat.updatedAt));
      if (chats.pinned.contains(chat.id)) open(chat.kind, 'pinned');
    });
    final saved = ref.read(storageProvider).readFolds();
    return {for (final kind in ChatKind.values) kind: {...?saved[kind.name]}};
  }

  /// Folds or opens a group; [shown] are the groups the list has now (folds of groups that are gone are dropped).
  void toggle(ChatKind kind, String key, Iterable<String> shown) {
    final now = {...state[kind]!}.intersection({...shown});
    if (!now.remove(key)) now.add(key);
    _save(kind, now);
  }

  /// Opens a group (a search match in it was opened).
  void open(ChatKind kind, String key) {
    if (!state[kind]!.contains(key)) return;
    _save(kind, {...state[kind]!}..remove(key));
  }

  void _save(ChatKind kind, Set<String> folded) {
    state = {...state, kind: folded};
    ref.read(storageProvider).writeFolds({for (final e in state.entries) e.key.name: e.value.toList()});
  }
}

final foldsProvider = NotifierProvider<FoldsNotifier, Map<ChatKind, Set<String>>>(FoldsNotifier.new);

/// The fold key of the day [time] is in.
String dayKey(DateTime time) =>
    '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
