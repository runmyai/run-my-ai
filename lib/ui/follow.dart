import 'dart:math';

import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';

/// Keeps a conversation at the end of the reply being written while the user is at the bottom (the chat page,
/// lib/ui/pages/chat_page.dart). The rules:
///
/// - Following is on when a chat opens, while the user is at the very bottom, and after the "↓" button. A chat
///   that fits on the screen counts as at the bottom, so a reply that first spills past it is followed.
/// - Only the user turns it off, by scrolling up (wheel, touchpad, dragging the list or its scroll bar), even a
///   little. Nothing the app does turns it off: a reply ending, a chat opening.
/// - It comes back on when the user scrolls back down to the very bottom, or presses "↓" ([resume]).
/// - A message sent while following, or while the view shows the very end, is followed; one sent while scrolled
///   up is not: the page stays where it is ([sent]).
/// - Jumping to a search match turns it off ([stop]).
/// - The "↓" button shows ([below]) while it is off and there is text below the view.
///
/// While following, each new line moves the page up by it almost at once: fast at first, easing at the end, in
/// about a tenth of a second.
class ReplyFollower {
  ReplyFollower({required this.scroll, required TickerProvider vsync, this.held}) {
    _ticker = vsync.createTicker(_frame);
  }

  final ScrollController scroll;

  /// While this says so, following waits (the page is sliding somewhere itself).
  final bool Function()? held;

  late final Ticker _ticker;
  Duration _last = Duration.zero;

  /// When the end was last reached after the reply ended: following goes on a moment longer, as the reply's last
  /// words still come out.
  Duration? _quietSince;

  /// How quickly the page moves up to a new line (seconds; about three of these and it is there).
  static const _quick = 0.03;

  /// The most the page trails the end (a message sent, a very fast reply): about two lines.
  static const _behind = 48.0;

  bool _following = true;
  bool get following => _following;

  bool _replying = false;

  /// The page is moving itself (so the scroll is not the user's).
  bool _self = false;

  /// There is text below the view that is not being followed.
  final below = ValueNotifier(false);

  /// Within this of the end counts as at the end.
  static const _end = 2.0;

  void dispose() {
    _ticker.dispose();
    below.dispose();
  }

  /// The list's physics (give it to the list): while following, if the content shrinks under the view the list goes
  /// straight to its new end, instead of sliding back there over the next frames (which a message sent meanwhile
  /// would take for the user scrolling up).
  ScrollPhysics get physics => _FollowPhysics(this);

  /// The list's scroll bar (put it around the list): it shows when the user scrolls, not when the page moves itself
  /// (each new line while following, a slide, a jump), so it does not flash on and off with every line. Its place
  /// is kept up to date all the same, so it is right when it shows.
  Widget scrollbar(BuildContext context, Widget list) => ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: Scrollbar(
          controller: scroll,
          // The page's own moves are left out; the updates of its size and place that follow them (which do not
          // show the bar) are not.
          notificationPredicate: (n) => n.depth == 0 && !_self,
          child: list,
        ),
      );

  /// Moves the page; not the user's scroll.
  void jumpTo(double offset) {
    _self = true;
    try {
      scroll.jumpTo(offset);
    } finally {
      _self = false;
    }
  }

  /// The view shows the very end (or everything fits).
  bool get atEnd => !scroll.hasClients || scroll.position.maxScrollExtent - scroll.position.pixels <= _end;

  /// A chat opened: following.
  void reset() {
    _following = true;
    _update();
  }

  /// A search match was jumped to.
  void stop() {
    _following = false;
    _update();
  }

  /// The "↓" button.
  void resume() {
    _following = true;
    _update();
  }

  /// A message was sent. Called as it is sent, before the page has grown, so [atEnd] is where the user was.
  void sent() {
    if (atEnd) _following = true;
    _update();
  }

  /// Whether a reply is being written in the open chat.
  set replying(bool value) {
    if (value == _replying) return;
    _replying = value;
    _update();
  }

  /// Give it the list's notifications (a NotificationListener around the list). A move it did not make itself
  /// towards older messages that leaves the view above the end is the user's (wheel, touchpad, dragging the list or
  /// its scroll bar, a click in the scroll bar, keys); one that ends at the very end is the list putting itself
  /// back after its content shrank, which is not.
  bool handle(Notification n) {
    if (n is ScrollUpdateNotification && n.depth == 0 && !_self) {
      final m = n.metrics;
      final delta = n.scrollDelta ?? 0;
      if (delta < 0 && m.maxScrollExtent - m.pixels > _end) _following = false;
      // Back down to the very end: following again.
      if (delta > 0 && m.maxScrollExtent - m.pixels <= 8) _following = true;
    }
    if ((n is ScrollUpdateNotification || n is ScrollMetricsNotification) && (n as ViewportNotificationMixin).depth == 0) {
      _update();
    }
    return false;
  }

  /// The list's content may have changed (call after each build).
  void changed() => _update();

  void _update() {
    below.value = !_following && scroll.hasClients && scroll.position.maxScrollExtent - scroll.position.pixels > _end;
    if (_following && _replying && !_ticker.isActive) {
      _last = Duration.zero;
      _quietSince = null;
      _ticker.start();
    }
  }

  /// One frame of following: the page moves up towards the end (a new line, a message sent), most of the way at
  /// once and the rest easing in.
  void _frame(Duration elapsed) {
    if (!_following || !scroll.hasClients) return _ticker.stop();
    final dt = _last == Duration.zero ? 1 / 60 : min((elapsed - _last).inMicroseconds / 1e6, 0.05);
    _last = elapsed;
    if (held?.call() ?? false) return;
    final p = scroll.position;
    final gap = p.maxScrollExtent - p.pixels;
    if (gap > 0.5) {
      final to = max(p.pixels + gap * (1 - exp(-dt / _quick)), p.maxScrollExtent - _behind);
      jumpTo(p.maxScrollExtent - to < 0.5 ? p.maxScrollExtent : min(to, p.maxScrollExtent));
      _quietSince = null;
    } else {
      if (gap > 0) jumpTo(p.maxScrollExtent);
      if (!_replying) {
        _quietSince ??= elapsed;
        if (elapsed - _quietSince! > const Duration(seconds: 1)) _ticker.stop();
      }
    }
  }
}

/// See [ReplyFollower.physics].
class _FollowPhysics extends ScrollPhysics {
  const _FollowPhysics(this.follower, {super.parent});

  final ReplyFollower follower;

  @override
  _FollowPhysics applyTo(ScrollPhysics? ancestor) => _FollowPhysics(follower, parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    if (follower.following && newPosition.pixels > newPosition.maxScrollExtent) return newPosition.maxScrollExtent;
    return super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
  }
}
