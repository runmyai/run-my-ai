/// The tokens-a-second number of a reply being written: the tokens of the last [window], worked out every [every], so
/// a wait shows as a dip at once. A new high shows at once and stays for [hold] unless a higher one comes, so a peak
/// can be read; after that it follows the speed again.
class LiveSpeed {
  static const window = Duration(milliseconds: 500);
  static const every = Duration(milliseconds: 100);
  static const hold = Duration(milliseconds: 750);

  /// The tokens written so far as they arrived (when, how many).
  final _arrived = <(Duration, int)>[];

  double? _shown;
  var _heldUntil = Duration.zero;

  /// By [now], [written] tokens of the reply are done.
  void add(Duration now, int written) {
    if (written > 0 && (_arrived.isEmpty || written > _arrived.last.$2)) _arrived.add((now, written));
  }

  /// The number to show at [now]; null: leave what is shown.
  double? tick(Duration now) {
    if (_arrived.length < 2) return null;
    final from = _arrived.lastWhere((a) => a.$1 <= now - window, orElse: () => _arrived.first);
    final seconds = (now - from.$1).inMicroseconds / 1e6;
    if (seconds <= 0) return null;
    final rate = (_arrived.last.$2 - from.$2) / seconds;
    if (_shown == null || rate > _shown!) {
      _heldUntil = now + hold;
    } else if (now < _heldUntil) {
      return null;
    }
    return _shown = rate;
  }
}
