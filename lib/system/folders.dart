import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../benchmark/hardware.dart';
import '../state/providers.dart';

/// The name of the app's main folder, on the drive it is put on.
const mainFolderName = 'Run My AI';

/// Room a copy or a download leaves free on its drive, besides the files themselves.
const spareBytes = 500 * 1000 * 1000;

String _join(String folder, String name) =>
    folder.endsWith(Platform.pathSeparator) ? '$folder$name' : '$folder${Platform.pathSeparator}$name';

/// Where the app keeps its files: the main folder (chosen once, at the first start) and the folders in it, each of
/// which can be moved in Settings.
class FolderSet {
  const FolderSet({
    required this.main,
    required this.models,
    required this.chats,
    required this.cache,
    this.readFrom = const [],
  });

  /// The main folder ("Run My AI").
  final String main;

  /// Where downloaded models go.
  final String models;

  /// More folders models are read from, used where they are (never changed by the app).
  final List<String> readFrom;

  /// The chats, one file each.
  final String chats;

  /// The engine's saved chat states (a cache: the engine removes the oldest when it is full).
  final String cache;

  /// The engine the app downloads and updates.
  String get engine => _join(main, 'engine');

  /// Every folder models are found in: the downloads folder first.
  List<String> get modelFolders => [models, ...readFrom];

  /// The folder that holds every one of [names] (a model's files, which are used together), or null.
  String? folderWith(List<String> names) =>
      modelFolders.where((dir) => names.every((n) => File(_join(dir, n)).existsSync())).firstOrNull;

  FolderSet copyWith({String? models, List<String>? readFrom, String? chats, String? cache}) => FolderSet(
    main: main,
    models: models ?? this.models,
    readFrom: readFrom ?? this.readFrom,
    chats: chats ?? this.chats,
    cache: cache ?? this.cache,
  );

  Map<String, Object?> toJson() => {
    'main': main,
    'models': models,
    'readFrom': readFrom,
    'chats': chats,
    'cache': cache,
  };

  static FolderSet? _fromJson(Object? json) {
    if (json is! Map) return null;
    final main = json['main'], models = json['models'], chats = json['chats'], cache = json['cache'];
    if (main is! String || models is! String || chats is! String || cache is! String) return null;
    return FolderSet(
      main: main,
      models: models,
      chats: chats,
      cache: cache,
      readFrom: [
        for (final f in json['readFrom'] as List? ?? const [])
          if (f is String) f,
      ],
    );
  }

  /// The folders saved in [dataDir] (folders.json), or, the first time, new ones in the main folder chosen for this
  /// computer ([chooseMain], by default [defaultMainFolder]), saved at once so the choice never changes by itself.
  /// Models and saved chat states of an earlier version stay where they are: that models folder is read from, and
  /// that states folder stays the cache. Nothing is created on the disk here but folders.json.
  static FolderSet load(Directory dataDir, {String Function()? chooseMain}) {
    final file = File(_join(dataDir.path, 'folders.json'));
    try {
      if (file.existsSync()) {
        final saved = _fromJson(jsonDecode(file.readAsStringSync()));
        if (saved != null) return saved;
      }
    } on FormatException {
      // A damaged file: chosen again.
    } on FileSystemException {
      // Unreadable: chosen again.
    }
    final main = (chooseMain ?? defaultMainFolder)();
    final oldModels = _join(dataDir.path, 'models'), oldStates = _join(dataDir.path, 'states');
    final set = FolderSet(
      main: main,
      models: _join(main, 'models'),
      chats: _join(main, 'chats'),
      cache: Directory(oldStates).existsSync() ? oldStates : _join(main, 'cache'),
      readFrom: [if (Directory(oldModels).existsSync()) oldModels],
    );
    set.save(dataDir);
    return set;
  }

  /// Writes folders.json through a temporary file, so a crash never leaves half of it.
  void save(Directory dataDir) {
    dataDir.createSync(recursive: true);
    final file = File(_join(dataDir.path, 'folders.json'));
    final tmp = File('${file.path}.tmp')..writeAsStringSync(jsonEncode(toJson()), flush: true);
    tmp.renameSync(file.path);
  }
}

/// The app's folders, saved in its data folder; Settings changes them.
class FoldersNotifier extends Notifier<FolderSet> {
  @override
  FolderSet build() => FolderSet.load(ref.read(storageProvider).dir);

  void set(FolderSet folders) {
    folders.save(ref.read(storageProvider).dir);
    state = folders;
  }
}

final foldersProvider = NotifierProvider<FoldersNotifier, FolderSet>(FoldersNotifier.new);

// ---- Choosing the drive -----------------------------------------------------------------------------------------

/// One mounted filesystem, as /proc/mounts lists it.
typedef Mount = ({String device, String path, String type, bool readOnly});

/// The filesystems in [text] (/proc/mounts). Spaces and other characters in names come escaped (\040).
List<Mount> parseMounts(String text) => [
  for (final line in const LineSplitter().convert(text))
    if (line.split(' ') case [final device, final path, final type, final options, ...])
      (device: _unescape(device), path: _unescape(path), type: type, readOnly: options.split(',').contains('ro')),
];

String _unescape(String s) =>
    s.replaceAllMapped(RegExp(r'\\([0-7]{3})'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)));

/// The free bytes of each filesystem in [text] (the output of `df -PB1`), by where it is mounted.
Map<String, int> parseDf(String text) => {
  for (final line in const LineSplitter().convert(text))
    if (RegExp(r'^\S+\s+\d+\s+\d+\s+(\d+)\s+\d+%\s+(.+)$').firstMatch(line) case final m?) m[2]!: int.parse(m[1]!),
};

/// Filesystems the main folder never goes on: FAT (no file over 4 GB), network, discs and images.
const _skippedTypes = {
  'vfat', 'msdos', 'fat', 'umsdos', 'iso9660', 'udf', 'squashfs', 'erofs', //
  'nfs', 'nfs4', 'cifs', 'smb3', 'smbfs', '9p', 'ceph', 'glusterfs', 'afs',
};

/// The whole disk a block device [name] is on: a partition's disk, or the first disk under an encrypted or LVM
/// volume.
String _disk(String name, FileSource sys, [int depth = 0]) {
  final under = sys.list('/sys/block/$name/slaves');
  if (under.isNotEmpty && depth < 8) return _disk(under.first, sys, depth + 1);
  if (sys.read('/sys/class/block/$name/partition') != null) {
    for (final disk in sys.list('/sys/block')) {
      if (sys.list('/sys/block/$disk').contains(name)) return disk;
    }
  }
  return name;
}

/// The block device's name in /sys for a device path: /dev/nvme0n1p3 -> nvme0n1p3, /dev/mapper/x -> its dm-N.
String _blockName(String device, FileSource sys) {
  final name = device.split('/').last;
  if (!device.startsWith('/dev/mapper/')) return name;
  for (final b in sys.list('/sys/block')) {
    if (b.startsWith('dm-') && sys.read('/sys/block/$b/dm/name')?.trim() == name) return b;
  }
  return name;
}

/// What a folder's drive is, for how fast models run from it: only an SSD is fast; a hard disk or a USB drive is very
/// slow for a model that is read while it answers.
enum DriveKind { ssd, hardDisk, usb, unknown }

/// The kind of the whole disk [disk] (a name in /sys/block): USB and removable drives first, then spinning or not.
DriveKind _diskKind(String disk, FileSource sys) {
  if (sys.read('/sys/block/$disk/removable')?.trim() == '1') return DriveKind.usb;
  final number = sys.read('/sys/block/$disk/dev')?.trim();
  if (number != null && (sys.read('/run/udev/data/b$number') ?? '').contains('E:ID_BUS=usb')) return DriveKind.usb;
  return switch (sys.read('/sys/block/$disk/queue/rotational')?.trim()) {
    '0' => DriveKind.ssd,
    '1' => DriveKind.hardDisk,
    _ => DriveKind.unknown,
  };
}

/// Not drives: loop, RAM, zram, disc and floppy devices.
final _notDrives = RegExp(r'^/dev/(loop|zram|ram|sr|fd)');

/// The mount that holds [path]: the one with the longest mount point.
Mount? _mountHolding(List<Mount> mounts, String path) => mounts
    .where((m) => m.path == '/' || path == m.path || path.startsWith('${m.path}/'))
    .fold<Mount?>(null, (best, m) => best == null || m.path.length > best.path.length ? m : best);

/// The kind of the drive that holds [path] on Linux, from [mounts] (/proc/mounts) and [sys] (/sys and udev's
/// records); unknown for a network or memory filesystem, or when /sys does not say.
DriveKind driveKindLinux({required String mounts, required String path, required FileSource sys}) {
  final m = _mountHolding(parseMounts(mounts), path);
  if (m == null || !m.device.startsWith('/dev/') || _notDrives.hasMatch(m.device)) return DriveKind.unknown;
  return _diskKind(_disk(_blockName(m.device, sys), sys), sys);
}

/// Where the main folder goes on Linux: on the internal drive with the most free space, SSDs before spinning disks.
/// Left out: FAT, network, pseudo and read-only filesystems, removable and USB drives, and drives the user cannot
/// write to. On the drive that holds [home] the folder is in [home] (a user cannot write that drive's top); on
/// another drive it is at the drive's top. [mounts]: /proc/mounts; [free]: free bytes by mount point ([parseDf]);
/// [sys]: /sys and udev's records; [writable]: whether the user can write a folder.
String chooseMainFolderLinux({
  required String mounts,
  required String home,
  required Map<String, int> free,
  required FileSource sys,
  required bool Function(String folder) writable,
}) {
  final all = parseMounts(mounts);
  final homeMount = _mountHolding(all, home);
  final drives = <String, ({String folder, int free, bool ssd})>{};
  for (final m in all) {
    if (!m.device.startsWith('/dev/') || m.readOnly || _skippedTypes.contains(m.type)) continue;
    if (_notDrives.hasMatch(m.device)) continue;
    final kind = _diskKind(_disk(_blockName(m.device, sys), sys), sys);
    if (kind == DriveKind.usb) continue;
    final ssd = kind == DriveKind.ssd;
    final onHome = m.device == homeMount?.device;
    if (drives.containsKey(m.device) && !onHome) continue;
    if (onHome) {
      drives[m.device] = (folder: _join(home, mainFolderName), free: free[homeMount!.path] ?? 0, ssd: ssd);
    } else if (writable(m.path)) {
      drives[m.device] = (folder: _join(m.path, mainFolderName), free: free[m.path] ?? 0, ssd: ssd);
    }
  }
  final best = drives.values.fold<({String folder, int free, bool ssd})?>(
    null,
    (best, d) => best == null || (d.ssd && !best.ssd) || (d.ssd == best.ssd && d.free > best.free) ? d : best,
  );
  return best?.folder ?? _join(home, mainFolderName);
}

/// One Windows drive: its letter ("D:"), filesystem, free bytes and kind.
typedef WindowsDrive = ({String letter, String fileSystem, int free, DriveKind kind});

/// The kind of a Windows disk from what PowerShell's Get-PhysicalDisk says, `MediaType/BusType` (for example
/// `SSD/NVMe` or `HDD/SATA`); unknown when it says neither.
DriveKind parseWindowsKind(String text) {
  final parts = text.trim().split('/');
  if (parts.length != 2) return DriveKind.unknown;
  final (media, bus) = (parts[0].toLowerCase(), parts[1].toLowerCase());
  if (bus == 'usb') return DriveKind.usb;
  if (media == 'ssd' || bus == 'nvme') return DriveKind.ssd;
  return media == 'hdd' ? DriveKind.hardDisk : DriveKind.unknown;
}

/// PowerShell: the physical disk behind the drive letter in `$l`, as `MediaType/BusType`; empty when it fails.
const _psKindOfLetter =
    r"try { $d = Get-Partition -DriveLetter $l -ErrorAction Stop | Get-Disk | Get-PhysicalDisk; $d.MediaType + '/' + $d.BusType } catch { '' }";

/// Where the main folder goes on Windows: `<drive>:\Run My AI` on the fixed NTFS drive with the most free space,
/// SSDs before hard disks; USB drives are left out.
String chooseMainFolderWindows(List<WindowsDrive> drives) {
  final ntfs = drives.where((d) => d.fileSystem.toUpperCase() == 'NTFS' && d.kind != DriveKind.usb);
  final best = ntfs.fold<WindowsDrive?>(
    null,
    (best, d) =>
        best == null ||
            (d.kind == DriveKind.ssd && best.kind != DriveKind.ssd) ||
            ((d.kind == DriveKind.ssd) == (best.kind == DriveKind.ssd) && d.free > best.free)
        ? d
        : best,
  );
  return '${best?.letter ?? 'C:'}\\$mainFolderName';
}

/// The main folder for this computer (see [chooseMainFolderLinux] and [chooseMainFolderWindows]).
String defaultMainFolder() {
  final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? Directory.current.path;
  try {
    if (Platform.isWindows) return chooseMainFolderWindows(_windowsDrives());
    if (!Platform.isLinux) return _join(home, mainFolderName);
    final mounts = File('/proc/mounts').readAsStringSync();
    final local = [
      for (final m in parseMounts(mounts))
        if (m.device.startsWith('/dev/')) m.path,
    ];
    // -l: local filesystems only, so a network drive that does not answer cannot hold the app up
    final df = Process.runSync('df', ['-PB1', '-l', '--', ...local]);
    return chooseMainFolderLinux(
      mounts: mounts,
      home: home,
      free: parseDf(df.stdout as String),
      sys: const DiskFiles(),
      writable: (folder) => Process.runSync('test', ['-w', folder]).exitCode == 0,
    );
  } on Exception {
    return _join(home, mainFolderName);
  }
}

/// The fixed drives (Windows' type 3) with their filesystem, free bytes and kind.
List<WindowsDrive> _windowsDrives() {
  final r = Process.runSync('powershell', [
    '-NoProfile',
    '-Command',
    [
      r"Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $l = $_.DeviceID.Substring(0,1); ",
      r"$_.DeviceID + '|' + $_.FileSystem + '|' + $_.FreeSpace + '|' + $( ",
      _psKindOfLetter,
      r" ) }",
    ].join(),
  ]);
  return [
    for (final line in const LineSplitter().convert(r.stdout as String))
      if (line.trim().split('|') case [final letter, final fs, final free, final kind] when int.tryParse(free) != null)
        (letter: letter, fileSystem: fs, free: int.parse(free), kind: parseWindowsKind(kind)),
  ];
}

/// The kind of the drive that holds [path] (which may not exist yet); unknown when the system cannot say. On Windows
/// it asks PowerShell for the physical disk behind the drive letter, for at most 8 seconds.
Future<DriveKind> driveKindOf(String path) async {
  try {
    if (Platform.isWindows) {
      final letter = RegExp(r'^([A-Za-z]):').firstMatch(path)?[1];
      if (letter == null) return DriveKind.unknown;
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "\$l = '$letter'; $_psKindOfLetter",
      ]).timeout(const Duration(seconds: 8));
      return parseWindowsKind(r.stdout as String);
    }
    if (!Platform.isLinux) return DriveKind.unknown;
    var dir = Directory(path);
    while (!dir.existsSync() && dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    return driveKindLinux(
      mounts: File('/proc/mounts').readAsStringSync(),
      path: dir.resolveSymbolicLinksSync(),
      sys: const DiskFiles(),
    );
  } on Exception {
    return DriveKind.unknown;
  }
}

/// Free bytes on the drive that holds [path] (or its nearest folder that exists); null when it cannot be read.
Future<int?> freeBytes(String path) async {
  var dir = Directory(path);
  while (!dir.existsSync() && dir.parent.path != dir.path) {
    dir = dir.parent;
  }
  try {
    if (Platform.isWindows) {
      final quoted = dir.path.replaceAll("'", "''");
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "[System.IO.DriveInfo]::new('$quoted').AvailableFreeSpace",
      ]);
      return int.tryParse((r.stdout as String).trim());
    }
    final r = await Process.run('df', ['-PB1', '--', dir.path]);
    return parseDf(r.stdout as String).values.firstOrNull;
  } on ProcessException {
    return null;
  }
}

// ---- Moving a folder --------------------------------------------------------------------------------------------

/// Why a folder could not be moved, for the user.
class FolderMoveFailure implements Exception {
  const FolderMoveFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Moves everything in [from] into [to] (made if needed), keeping sub-folders, then removes [from]'s emptied
/// folders. On the same drive each file is renamed; across drives each is copied, and the originals are deleted only
/// once every copy is done. When something fails, renamed files go back and copies are deleted, so no file is lost,
/// and a [FolderMoveFailure] is thrown. [progress]: bytes moved, of all. [free]: free bytes on a drive (tests).
Future<void> moveFolder(
  String from,
  String to, {
  void Function(int done, int total)? progress,
  Future<int?> Function(String path) free = freeBytes,
}) async {
  final a = Directory(from).absolute.path, b = Directory(to).absolute.path;
  if (a == b) return;
  final sep = Platform.pathSeparator;
  if (b.startsWith('$a$sep') || a.startsWith('$b$sep')) {
    throw const FolderMoveFailure('The new folder cannot be inside the old one, or the old one inside it.');
  }
  Directory(b).createSync(recursive: true);
  if (!Directory(a).existsSync()) return;

  final entries = [
    for (final e in Directory(a).listSync(recursive: true, followLinks: false))
      if (e is! Directory) e,
  ];
  String target(FileSystemEntity e) => '$b${e.path.substring(a.length)}';
  for (final e in entries) {
    if (FileSystemEntity.typeSync(target(e), followLinks: false) != FileSystemEntityType.notFound) {
      throw FolderMoveFailure('The new folder already has a file named ${e.path.substring(a.length + 1)}.');
    }
  }
  int size(FileSystemEntity e) => e is File ? e.lengthSync() : 0;
  final total = entries.fold<int>(0, (sum, e) => sum + size(e));
  var done = 0;
  progress?.call(0, total);

  final renamed = <(String, String)>[], copied = <(FileSystemEntity, String)>[];
  var copying = false;
  try {
    for (final e in entries) {
      final dest = target(e), bytes = size(e);
      Directory(File(dest).parent.path).createSync(recursive: true);
      if (!copying) {
        try {
          e.renameSync(dest);
          renamed.add((e.path, dest));
          done += bytes;
          progress?.call(done, total);
          continue;
        } on FileSystemException {
          // Another drive (or the first file could not be renamed): copied instead, after a space check.
          if (renamed.isNotEmpty) rethrow;
          copying = true;
          final room = await free(b);
          if (room != null && room < total + spareBytes) {
            throw FolderMoveFailure(
              'Not enough free space there: ${_gb(total + spareBytes - room)} more is needed (${_gb(total)} of files, '
              'and 0.5 GB to spare).',
            );
          }
        }
      }
      await _copy(e, dest, (bytes) => progress?.call(done + bytes, total));
      copied.add((e, dest));
      done += bytes;
      progress?.call(done, total);
    }
  } on Exception catch (error) {
    for (final (src, dest) in renamed.reversed) {
      FileSystemEntity.typeSync(dest, followLinks: false) == FileSystemEntityType.link
          ? Link(dest).renameSync(src)
          : File(dest).renameSync(src);
    }
    for (final (_, dest) in copied) {
      _delete(dest);
    }
    if (error is FolderMoveFailure) rethrow;
    throw FolderMoveFailure(
      'The folder could not be moved: ${error is FileSystemException ? error.message : error}. '
      'Nothing was lost; every file is still in the old folder.',
    );
  }
  for (final (src, _) in copied) {
    _delete(src.path);
  }
  _removeEmpty(Directory(a));
}

String _gb(int bytes) => '${(bytes / 1e9).toStringAsFixed(1)} GB';

void _delete(String path) {
  try {
    FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.link
        ? Link(path).deleteSync()
        : File(path).deleteSync();
  } on FileSystemException {
    // Already gone.
  }
}

/// Copies a file (through a temporary name, so a half copy never looks like a whole one) or recreates a link,
/// telling [copiedBytes] how far it is.
Future<void> _copy(FileSystemEntity e, String dest, void Function(int copiedBytes) copiedBytes) async {
  if (e is Link) {
    Link(dest).createSync(e.targetSync());
    return;
  }
  final tmp = File('$dest.moving');
  // File.copy keeps the file's permissions (the engine's programs stay runnable); its progress is read on the side.
  final watch = Timer.periodic(const Duration(milliseconds: 300), (_) {
    try {
      copiedBytes(tmp.lengthSync());
    } on FileSystemException {
      // Not there yet.
    }
  });
  try {
    await (e as File).copy(tmp.path);
    tmp.renameSync(dest);
  } on Exception {
    _delete(tmp.path);
    rethrow;
  } finally {
    watch.cancel();
  }
}

/// Removes [dir] and the folders in it once they are empty; a folder with anything left in it stays.
void _removeEmpty(Directory dir) {
  try {
    for (final e in dir.listSync(followLinks: false)) {
      if (e is Directory) _removeEmpty(e);
    }
    if (dir.listSync().isEmpty) dir.deleteSync();
  } on FileSystemException {
    // Left as it is.
  }
}
