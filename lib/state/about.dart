import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/backend.dart';
import '../backend/engine_backend.dart';
import '../engine/engine_version.dart';
import '../system/folders.dart';
import 'prefs.dart';
import 'providers.dart';

/// The app's version: the one in pubspec.yaml, without the build number (a test keeps the two equal).
const appVersion = '0.2.0';

/// The engine's version for the About page: what the program in the engine folder says when asked, else what the
/// running engine reports; null when neither is known.
final engineVersionProvider = FutureProvider.autoDispose<String?>((ref) async {
  final folder = EngineBackend.engineFolder(ref.read(prefsProvider).engineFolder, ref.read(foldersProvider));
  final asked = await readEngineVersion(folder);
  if (asked != null) return asked;
  final backend = ref.read(backendProvider);
  return backend is EngineControl ? (backend as EngineControl).reportedVersion() : null;
});
