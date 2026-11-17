import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// Which first-start screens and hints the user has been through. Each is shown until it is done, and never again.
class FirstRun {
  const FirstRun({this.welcomeShown = false, this.storeHintClosed = false, this.firstMessageSent = false});

  /// The welcome screen was closed with "Get started".
  final bool welcomeShown;

  /// The bubble that points at the Store was closed, or the Store was opened.
  final bool storeHintClosed;

  /// A message was sent once: from then on the chat's texts are the usual ones.
  final bool firstMessageSent;
}

/// The first-start flags, saved to first_run.json on every change.
class FirstRunNotifier extends Notifier<FirstRun> {
  @override
  FirstRun build() {
    final saved = ref.read(storageProvider).readFirstRun();
    return FirstRun(
      welcomeShown: saved['welcomeShown'] == true,
      storeHintClosed: saved['storeHintClosed'] == true,
      firstMessageSent: saved['firstMessageSent'] == true,
    );
  }

  void welcomeDone() => _save(welcomeShown: true);

  void closeStoreHint() => _save(storeHintClosed: true);

  void firstMessageDone() => _save(firstMessageSent: true);

  /// Sets the given flags (a flag already set changes nothing, and nothing is written).
  void _save({bool? welcomeShown, bool? storeHintClosed, bool? firstMessageSent}) {
    final next = FirstRun(
      welcomeShown: welcomeShown ?? state.welcomeShown,
      storeHintClosed: storeHintClosed ?? state.storeHintClosed,
      firstMessageSent: firstMessageSent ?? state.firstMessageSent,
    );
    if (next.welcomeShown == state.welcomeShown &&
        next.storeHintClosed == state.storeHintClosed &&
        next.firstMessageSent == state.firstMessageSent) {
      return;
    }
    state = next;
    ref.read(storageProvider).writeFirstRun({
      'welcomeShown': next.welcomeShown,
      'storeHintClosed': next.storeHintClosed,
      'firstMessageSent': next.firstMessageSent,
    });
  }
}

final firstRunProvider = NotifierProvider<FirstRunNotifier, FirstRun>(FirstRunNotifier.new);
