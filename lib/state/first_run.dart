import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/engine_backend.dart';
import '../engine/engine_download.dart';
import '../system/folders.dart';
import 'prefs.dart';
import 'providers.dart';

/// Whether the app still has to get its engine: the real engine is used ([backend]), the user has not chosen their
/// own engine folder ([own]), and there is no engine in the app's engine folder or next to the app.
bool engineMissingFor(Object backend, String? own, FolderSet Function() folders) {
  if (backend is! EngineBackend || own != null) return false;
  final folder = EngineBackend.engineFolder(own, folders());
  return !File('$folder${Platform.pathSeparator}$engineProgram').existsSync();
}

/// Which first-start screens and hints the user has been through. Each is shown until it is done, and never again.
class FirstRun {
  const FirstRun({
    this.welcomeShown = false,
    this.storeHintClosed = false,
    this.firstMessageSent = false,
    this.setupOpen = false,
  });

  /// The welcome screen was closed with "Get started".
  final bool welcomeShown;

  /// The bubble that points at the Store was closed, or the Store was opened.
  final bool storeHintClosed;

  /// A message was sent once: from then on the chat's texts are the usual ones.
  final bool firstMessageSent;

  /// The welcome screen or the engine step is still to come or open, so the main window is not showing yet. Not
  /// saved: it starts true at every start that still needs one of them.
  final bool setupOpen;

  /// The bubble at the Store shows once the first start is through (the engine installed, the main window showing).
  bool get showStoreHint => welcomeShown && !setupOpen && !storeHintClosed;
}

/// The first-start flags, saved to first_run.json on every change.
class FirstRunNotifier extends Notifier<FirstRun> {
  @override
  FirstRun build() {
    final saved = ref.read(storageProvider).readFirstRun();
    final welcomeShown = saved['welcomeShown'] == true;
    return FirstRun(
      welcomeShown: welcomeShown,
      storeHintClosed: saved['storeHintClosed'] == true,
      firstMessageSent: saved['firstMessageSent'] == true,
      setupOpen:
          !welcomeShown ||
          engineMissingFor(
            ref.read(backendProvider),
            ref.read(prefsProvider).engineFolder,
            () => ref.read(foldersProvider),
          ),
    );
  }

  void welcomeDone() => _save(welcomeShown: true);

  /// The engine step is over (or was not needed): the main window shows.
  void setupDone() {
    if (!state.setupOpen) return;
    state = FirstRun(
      welcomeShown: state.welcomeShown,
      storeHintClosed: state.storeHintClosed,
      firstMessageSent: state.firstMessageSent,
    );
  }

  void closeStoreHint() => _save(storeHintClosed: true);

  void firstMessageDone() => _save(firstMessageSent: true);

  /// Sets the given flags (a flag already set changes nothing, and nothing is written).
  void _save({bool? welcomeShown, bool? storeHintClosed, bool? firstMessageSent}) {
    final next = FirstRun(
      welcomeShown: welcomeShown ?? state.welcomeShown,
      storeHintClosed: storeHintClosed ?? state.storeHintClosed,
      firstMessageSent: firstMessageSent ?? state.firstMessageSent,
      setupOpen: state.setupOpen,
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
