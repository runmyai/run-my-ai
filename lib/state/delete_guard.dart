import 'package:flutter_riverpod/flutter_riverpod.dart';

/// When deleting a chat asks first. The first two deletes ask; when the second comes within [window] of the first,
/// the next deletes do not ask, as long as each comes within [window] of the one before. After [window] with no
/// delete, every delete asks again. Kept in memory only, so after the app restarts the first delete asks.
class DeleteGuard {
  DeleteGuard({this.window = const Duration(minutes: 2), DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final Duration window;
  final DateTime Function() _clock;

  DateTime? _last;
  bool _quick = false;

  bool _recent(DateTime now) => _last != null && now.difference(_last!) <= window;

  /// Whether the next delete shows the confirm box.
  bool get asks => !(_quick && _recent(_clock()));

  /// Call after a chat was really deleted (not when the box was cancelled).
  void deleted() {
    final now = _clock();
    _quick = _recent(now);
    _last = now;
  }
}

final deleteGuardProvider = Provider<DeleteGuard>((ref) => DeleteGuard());
