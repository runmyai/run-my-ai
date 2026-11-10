import 'dart:convert';
import 'dart:io';

/// The part of a chat's saved state files' names that comes from the chat's id, as the engine makes it.
String chatStateHash(String chatId) {
  var hash = 1469598103934665603;
  for (final byte in utf8.encode(chatId)) {
    hash ^= byte;
    hash *= 1099511628211; // Wraps around at 64 bits, as in the engine.
  }
  String part(int v) => v.toRadixString(16).padLeft(8, '0');
  return part(hash >>> 32) + part(hash & 0xFFFFFFFF);
}

/// Deletes the chat's saved state and snapshots from [folder]: for when no engine is running to do it.
void deleteChatStates(String folder, String chatId) {
  final directory = Directory(folder);
  if (!directory.existsSync()) return;
  final hash = chatStateHash(chatId);
  for (final entry in directory.listSync().whereType<File>()) {
    final name = entry.uri.pathSegments.last;
    if (name == 'chat-$hash.state' || (name.startsWith('snap-$hash-') && name.endsWith('.state'))) {
      try {
        entry.deleteSync();
      } on FileSystemException {
        // Already gone, or in use: the engine's size limit takes care of what is left.
      }
    }
  }
}
