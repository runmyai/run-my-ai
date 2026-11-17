import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../state/benchmark.dart';
import '../state/chats.dart';
import '../state/library.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'buttons.dart';

/// What to ask before the window closes; null when nothing is running and it may close at once.
String? closeQuestion({required bool replying, required bool benchmarking}) {
  if (benchmarking) return 'A benchmark is still running. Close anyway?';
  if (replying) return 'A reply is still running. Close anyway?';
  return null;
}

/// Closing the window while a reply or a benchmark is running asks first. The window's own close is held back
/// (setUpWindow); this closes it once the user agrees, or at once when nothing is running. The engine closes with
/// the app either way.
class CloseGuard extends ConsumerStatefulWidget {
  const CloseGuard({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<CloseGuard> createState() => _CloseGuardState();
}

class _CloseGuardState extends ConsumerState<CloseGuard> with WindowListener {
  var _asking = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() => unawaited(_close());

  Future<void> _close() async {
    if (_asking) return;
    final question = closeQuestion(
      replying: ref.read(chatsProvider).replyingId != null,
      benchmarking: ref.read(benchmarkProvider).running,
    );
    if (question != null) {
      _asking = true;
      final close = await showDialog<bool>(context: context, builder: (_) => _CloseBox(question: question));
      _asking = false;
      if (close != true || !mounted) return;
    }
    // The reply so far is kept, and every save is done before the window goes.
    if (ref.read(chatsProvider).replyingId != null) ref.read(chatsProvider.notifier).stop();
    await ref.read(chatStoreProvider).flush();
    // a download writes what it has and records how far each part got, so Resume fetches nothing twice
    if (ref.exists(libraryProvider)) {
      await ref.read(libraryProvider.notifier).pauseAll().timeout(const Duration(seconds: 3), onTimeout: () {});
    }
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// "Close anyway?" with Cancel (chosen when it opens, so Enter keeps the app open) and Close anyway.
class _CloseBox extends StatelessWidget {
  const _CloseBox({required this.question});

  final String question;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AlertDialog(
      backgroundColor: c.page,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      constraints: const BoxConstraints(maxWidth: 400),
      content: Text(question, style: TextStyle(fontSize: 15, height: 1.5, color: c.text)),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      actions: [
        AppButton(
          key: const Key('close-cancel'),
          label: 'Cancel',
          autofocus: true,
          ringAlways: true,
          onTap: () => Navigator.pop(context, false),
        ),
        AppButton(
          key: const Key('close-confirm'),
          label: 'Close anyway',
          danger: true,
          onTap: () => Navigator.pop(context, true),
        ),
      ],
    );
  }
}
