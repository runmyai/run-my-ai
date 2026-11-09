import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/storage.dart';
import 'chats.dart';
import 'providers.dart';

/// The draft key of a chat: its id, or for a section's new chat "new:chat" / "new:code".
String draftKey(String? chatId, ChatKind kind) => chatId ?? 'new:${kind.name}';

/// The unsent text in each chat's message box (and in each section's new chat), by [draftKey]. Saved to
/// drafts.json half a second after the typing stops (and when the app closes); a deleted chat's draft goes with it.
class DraftsNotifier extends Notifier<Map<String, String>> {
  Timer? _save;
  late Storage _storage;

  /// The drafts as last changed (what a save writes).
  Map<String, String> _latest = const {};

  @override
  Map<String, String> build() {
    // A chat deleted: its draft too.
    ref.listen(chatsProvider.select((s) => s.chats), (_, chats) {
      final ids = {for (final c in chats) c.id};
      final gone = [for (final k in state.keys) if (!k.startsWith('new:') && !ids.contains(k)) k];
      if (gone.isEmpty) return;
      _changed({...state}..removeWhere((k, _) => gone.contains(k)));
    });
    ref.onDispose(() {
      if (_save?.isActive ?? false) _write();
      _save?.cancel();
    });
    _storage = ref.read(storageProvider);
    return _latest = _storage.readDrafts();
  }

  /// Sets the draft of [key] (empty: none).
  void set(String key, String text) {
    if ((state[key] ?? '') == text) return;
    _changed(text.isEmpty ? ({...state}..remove(key)) : {...state, key: text});
  }

  void _changed(Map<String, String> drafts) {
    state = _latest = drafts;
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 500), _write);
  }

  void _write() => _storage.writeDrafts(_latest);
}

final draftsProvider = NotifierProvider<DraftsNotifier, Map<String, String>>(DraftsNotifier.new);
