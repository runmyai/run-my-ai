import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend/backend.dart';
import 'backend/engine_backend.dart';
import 'data/chat_store.dart';
import 'data/storage.dart';
import 'dev/screenshot.dart';
import 'state/prefs.dart';
import 'state/providers.dart';
import 'state/section.dart';
import 'system/appearance.dart';
import 'system/chime.dart';
import 'theme.dart';
import 'ui/close_guard.dart';
import 'ui/shell.dart';
import 'ui/title_bar.dart';
import 'ui/welcome.dart';
import 'window/app_window.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await Storage.open();
  final (chatStore, _) = await (ChatStore.open(storage.dir, folder: storage.chatsDir), setUpWindow(storage)).wait;
  final section = Section.values.where((s) => s.name == forcedSection).firstOrNull;
  final themeMode = switch (forcedTheme) {
    'light' || 'silklight' || 'dusk' => ThemeMode.light,
    'dark' || 'dark2' || 'dark3' => ThemeMode.dark,
    _ => null,
  };
  runApp(
    appWith(storage: storage, chatStore: chatStore, backend: EngineBackend(storage), section: section, themeMode: themeMode),
  );
  scheduleScreenshot();
}

/// The app with its data folder, chats database and backend (main() and the tests choose them).
/// [themeMode] forces a theme (developer screenshots); otherwise the user's saved choice is used. [chime]: the
/// reply-finished sound (the tests count it instead of playing it).
Widget appWith({
  required Storage storage,
  required ChatStore chatStore,
  required Backend backend,
  Section? section,
  ThemeMode? themeMode,
  Chime Function(Ref ref)? chime,
}) {
  return ProviderScope(
    overrides: [
      storageProvider.overrideWithValue(storage),
      chatStoreProvider.overrideWithValue(chatStore),
      backendProvider.overrideWithValue(backend),
      if (section != null) sectionProvider.overrideWith(() => SectionNotifier(section)),
      if (chime != null) chimeProvider.overrideWith(chime),
    ],
    child: RunMyAiApp(themeMode: themeMode),
  );
}

class RunMyAiApp extends ConsumerWidget {
  const RunMyAiApp({super.key, this.themeMode});

  final ThemeMode? themeMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RepaintBoundary(
      key: screenshotKey,
      child: MaterialApp(
        title: 'Run My AI',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(
          Brightness.light,
          lightColors: switch (forcedTheme ?? ref.watch(prefsProvider.select((p) => p.lightStyle))) {
            'silklight' => AppColors.silkLight,
            'dusk' => AppColors.dusk,
            _ => AppColors.light,
          },
        ),
        darkTheme: buildTheme(
          Brightness.dark,
          darkColors: switch (forcedTheme ?? ref.watch(prefsProvider.select((p) => p.darkStyle))) {
            'dark2' => AppColors.dark2,
            'dark' => AppColors.dark,
            _ => AppColors.dark3,
          },
        ),
        themeMode: themeMode ?? _mode(ref.watch(prefsProvider.select((p) => p.theme)), ref.watch(systemLightProvider)),
        builder: (context, child) {
          // The user's text size (Ctrl+= / Ctrl+-), on top of the system's.
          final scale = ref.watch(prefsProvider.select((p) => p.textScale));
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(textScaler: TextScaler.linear(media.textScaler.scale(16) / 16 * scale)),
            child: WindowShape(child: child!),
          );
        },
        home: const CloseGuard(child: FirstRunGate(child: Shell())),
      ),
    );
  }
}

/// The theme picked; until one is, light only when the computer is explicitly set to light (else Run My AI Dark).
ThemeMode _mode(ThemeMode picked, bool systemLight) =>
    picked != ThemeMode.system ? picked : (systemLight ? ThemeMode.light : ThemeMode.dark);
