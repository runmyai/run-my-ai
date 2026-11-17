import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// What the Store remembers: the downloaded files and the picked one.
class LibraryData {
  const LibraryData({this.downloaded = const {}, this.picked, this.contextLength});

  final Set<String> downloaded;
  final String? picked;

  /// The context length last picked; null: none yet.
  final int? contextLength;
}

/// The user's display choices.
class PrefsData {
  const PrefsData({
    this.theme = 'system',
    this.sidebarHidden = false,
    this.textScale = 1,
    this.bell = true,
    this.soundName,
    this.soundFile,
    this.thinking = false,
    this.engineFolder,
    this.speedHighlighted = false,
    this.stateLimitGiB = defaultStateLimitGiB,
  });

  static const defaultStateLimitGiB = 10.0;

  /// 'system', 'light' or 'dark'.
  final String theme;
  final bool sidebarHidden;

  /// How big the text is (Ctrl+= / Ctrl+-): 1 is normal.
  final double textScale;

  /// A sound plays when a reply finishes (the bell in the top row).
  final bool bell;

  /// The user's own sound for it: the name of the file they chose, and its copy in the data folder (a path
  /// relative to it); null: the sound the app comes with.
  final String? soundName;
  final String? soundFile;

  /// A model that can choose thinks before it answers.
  final bool thinking;

  /// The folder the engine is in; null: where it is by default.
  final String? engineFolder;

  /// The speed under a reply stands out (blue and bold) instead of looking like normal text.
  final bool speedHighlighted;

  /// The most the chats' saved states may take on the disk.
  final double stateLimitGiB;
}

/// Where the window was when it was last moved or resized: its normal size and place (also kept
/// while maximized, so un-maximizing brings it back) and whether it was maximized.
class WindowData {
  const WindowData({required this.width, required this.height, this.x, this.y, this.maximized = false});

  final double width;
  final double height;

  /// Null where the app cannot choose its own place (Linux on Wayland).
  final double? x;
  final double? y;
  final bool maximized;

  WindowData withMaximized(bool maximized) =>
      WindowData(width: width, height: height, x: x, y: y, maximized: maximized);
}

/// The app's saved data, as small JSON files in the app's data folder:
///   settings.json      theme, whether the sidebar is hidden, the text size, the bell and its sound
///   sounds/            the user's own reply-finished sound (a copy of the file they chose)
///   drafts.json        the unsent text in each chat's message box (and in each section's new chat)
///   window.json        the window's size, place and maximized state
///   library.json       downloaded model files and the picked one
///   folds.json         the chat list's folded groups, by section
/// The chats are in chats.db, next to them (lib/data/chat_db.dart).
class Storage {
  Storage(this.dir) {
    dir.createSync(recursive: true);
  }

  final Directory dir;

  /// The system's data folder for the app, or RUNMYAI_DATA_DIR when set (tests).
  static Future<Storage> open() async {
    final custom = Platform.environment['RUNMYAI_DATA_DIR'];
    return Storage(custom != null ? Directory(custom) : await getApplicationSupportDirectory());
  }

  String _path(String name) => '${dir.path}${Platform.pathSeparator}$name';

  PrefsData readPrefs() {
    final json = _readJson(File(_path('settings.json')));
    if (json == null) return const PrefsData();
    return PrefsData(
      theme: json['theme'] as String? ?? 'system',
      sidebarHidden: json['sidebarHidden'] as bool? ?? false,
      textScale: (json['textScale'] as num?)?.toDouble() ?? 1,
      bell: json['bell'] as bool? ?? true,
      soundName: json['soundName'] as String?,
      soundFile: json['soundFile'] as String?,
      thinking: json['thinking'] as bool? ?? false,
      engineFolder: json['engineFolder'] as String?,
      speedHighlighted: json['speedHighlighted'] as bool? ?? false,
      stateLimitGiB: (json['stateLimitGiB'] as num?)?.toDouble() ?? PrefsData.defaultStateLimitGiB,
    );
  }

  void writePrefs(PrefsData data) => _writeJson(File(_path('settings.json')), {
    'theme': data.theme,
    'sidebarHidden': data.sidebarHidden,
    'textScale': data.textScale,
    'bell': data.bell,
    'soundName': data.soundName,
    'soundFile': data.soundFile,
    'thinking': data.thinking,
    'engineFolder': data.engineFolder,
    'speedHighlighted': data.speedHighlighted,
    'stateLimitGiB': data.stateLimitGiB,
  });

  WindowData? readWindow() {
    final json = _readJson(File(_path('window.json')));
    final width = json?['width'];
    final height = json?['height'];
    if (json == null || width is! num || height is! num) return null;
    return WindowData(
      width: width.toDouble(),
      height: height.toDouble(),
      x: (json['x'] as num?)?.toDouble(),
      y: (json['y'] as num?)?.toDouble(),
      maximized: json['maximized'] as bool? ?? false,
    );
  }

  void writeWindow(WindowData data) => _writeJson(File(_path('window.json')), {
    'width': data.width,
    'height': data.height,
    'x': data.x,
    'y': data.y,
    'maximized': data.maximized,
  });

  LibraryData readLibrary() {
    final json = _readJson(File(_path('library.json')));
    if (json == null) return const LibraryData();
    return LibraryData(
      downloaded: {for (final id in json['downloaded'] as List? ?? const []) id as String},
      picked: json['picked'] as String?,
      contextLength: json['contextLength'] as int?,
    );
  }

  void writeLibrary(LibraryData data) =>
      _writeJson(File(_path('library.json')), {
        'downloaded': data.downloaded.toList(),
        'picked': data.picked,
        'contextLength': data.contextLength,
      });

  /// The folded groups of the chat list, by section ("chat", "code"): "pinned" or a day ("2026-10-30").
  Map<String, List<String>> readFolds() {
    final json = _readJson(File(_path('folds.json'))) ?? const {};
    return {
      for (final e in json.entries)
        if (e.value is List)
          e.key: [
            for (final v in e.value! as List)
              if (v is String) v,
          ],
    };
  }

  void writeFolds(Map<String, List<String>> folds) => _writeJson(File(_path('folds.json')), folds);

  /// The drafts, by chat id ("new:chat" / "new:code" for each section's new chat).
  Map<String, String> readDrafts() {
    final json = _readJson(File(_path('drafts.json'))) ?? const {};
    return {
      for (final e in json.entries)
        if (e.value is String) e.key: e.value! as String,
    };
  }

  void writeDrafts(Map<String, String> drafts) => _writeJson(File(_path('drafts.json')), drafts);

  /// Each model's engine profiles, as written by [writeProfiles].
  Map<String, Object?> readProfiles() => _readJson(File(_path('profiles.json'))) ?? const {};

  void writeProfiles(Map<String, Object?> profiles) => _writeJson(File(_path('profiles.json')), profiles);

  /// What the Benchmark tab was last set to, as written by [writeBenchmarkSetup]; null: never set.
  Map<String, Object?>? readBenchmarkSetup() => _readJson(File(_path('benchmark.json')));

  void writeBenchmarkSetup(Map<String, Object?> setup) => _writeJson(File(_path('benchmark.json')), setup);

  /// What Serve was last set to ({port, apiKey}), as written by [writeServeSetup]; null: never set.
  Map<String, Object?>? readServeSetup() => _readJson(File(_path('serve.json')));

  void writeServeSetup(Map<String, Object?> setup) => _writeJson(File(_path('serve.json')), setup);

  /// The messages waiting to be sent, by chat.
  Map<String, List<String>> readQueues() {
    final json = _readJson(File(_path('queues.json'))) ?? const {};
    return {
      for (final e in json.entries)
        if (e.value is List) e.key: (e.value! as List).whereType<String>().toList(),
    };
  }

  void writeQueues(Map<String, List<String>> queues) => _writeJson(File(_path('queues.json')), queues);

  Map<String, Object?>? _readJson(File f) {
    if (!f.existsSync()) return null;
    try {
      return (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();
    } on FormatException {
      return null;
    }
  }

  /// Writes a temporary file first and renames it, so a crash never leaves a half-written file.
  void _writeJson(File f, Object json) {
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(json), flush: true);
    tmp.renameSync(f.path);
  }
}
