// The app's folders: the drive the main folder goes on, the saved folders, and moving a folder.
// Run: flutter test test/folders_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/benchmark/hardware.dart';
import 'package:runmyai/system/folders.dart';

/// Made-up /sys and udev files: a file's text, or a folder's names.
class _Sys implements FileSource {
  _Sys(this.files, this.folders);

  final Map<String, String> files;
  final Map<String, List<String>> folders;

  @override
  String? read(String path) => files[path];

  @override
  List<String> list(String folder) => folders[folder] ?? const [];
}

/// An NVMe SSD with four partitions (one is an encrypted volume, dm-0), a spinning disk (sdb) and a USB stick that
/// says it is not removable (sda; only udev knows it is on USB).
final _sys = _Sys(
  {
    for (final p in ['nvme0n1p1', 'nvme0n1p2', 'nvme0n1p3', 'nvme0n1p4', 'sda1', 'sdb1', 'sdc1', 'sdd1'])
      '/sys/class/block/$p/partition': '1',
    '/sys/block/nvme0n1/removable': '0',
    '/sys/block/nvme0n1/queue/rotational': '0',
    '/sys/block/nvme0n1/dev': '259:0',
    '/sys/block/sda/removable': '0',
    '/sys/block/sda/queue/rotational': '0',
    '/sys/block/sda/dev': '8:0',
    '/run/udev/data/b8:0': 'S:disk/by-id/usb-Stick\nE:ID_BUS=usb\nE:ID_TYPE=disk\n',
    '/sys/block/sdb/removable': '0',
    '/sys/block/sdb/queue/rotational': '1',
    '/sys/block/sdb/dev': '8:16',
    '/sys/block/sdc/removable': '1',
    '/sys/block/sdc/queue/rotational': '0',
    '/sys/block/sdd/removable': '0',
    '/sys/block/dm-0/dm/name': 'luks-1234',
  },
  {
    '/sys/block': ['nvme0n1', 'sda', 'sdb', 'sdc', 'sdd', 'dm-0'],
    '/sys/block/sdc': ['sdc1', 'queue'],
    '/sys/block/sdd': ['sdd1', 'queue'],
    '/sys/block/nvme0n1': ['nvme0n1p1', 'nvme0n1p2', 'nvme0n1p3', 'nvme0n1p4', 'queue', 'removable'],
    '/sys/block/sda': ['sda1', 'queue'],
    '/sys/block/sdb': ['sdb1', 'queue'],
    '/sys/block/dm-0/slaves': ['nvme0n1p3'],
  },
);

const _mounts = '''
sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
tmpfs /tmp tmpfs rw,nosuid,nodev 0 0
/dev/nvme0n1p2 / btrfs rw,relatime,ssd,subvol=/root 0 0
/dev/nvme0n1p2 /home btrfs rw,relatime,ssd,subvol=/home 0 0
/dev/nvme0n1p1 /boot/efi vfat rw,relatime 0 0
/dev/nvme0n1p4 /run/media/u/My\\040Data ntfs3 rw,noatime,uid=1000 0 0
/dev/mapper/luks-1234 /mnt/secret ext4 rw,relatime 0 0
/dev/sda1 /run/media/u/Stick exfat rw,nosuid 0 0
/dev/sdb1 /mnt/hdd ext4 rw,relatime 0 0
/dev/sdc1 /run/media/u/Card ext4 rw 0 0
/dev/sdd1 /run/media/u/Mystery ext4 rw 0 0
/dev/nvme0n1p3 /run/media/u/OldOS ntfs3 ro,noatime 0 0
server:/export /mnt/nfs nfs4 rw,relatime 0 0
/dev/loop0 /var/lib/snapd/snap/core squashfs ro 0 0
''';

String _choose({required Map<String, int> free, Set<String> writable = const {}, String mounts = _mounts}) =>
    chooseMainFolderLinux(mounts: mounts, home: '/home/u', free: free, sys: _sys, writable: writable.contains);

void main() {
  test('/proc/mounts lines are read, with escaped spaces', () {
    final mounts = parseMounts(_mounts);
    expect(mounts.firstWhere((m) => m.device == '/dev/nvme0n1p4').path, '/run/media/u/My Data');
    expect(mounts.firstWhere((m) => m.device == '/dev/nvme0n1p3').readOnly, isTrue);
    expect(mounts.firstWhere((m) => m.path == '/').readOnly, isFalse);
  });

  test('df output gives the free bytes by mount point', () {
    const df =
        'Filesystem          1-blocks         Used    Available Capacity Mounted on\n'
        '/dev/nvme0n1p10 168577466368 140908638208  17528475648      89% /\n'
        '/dev/nvme0n1p4  504674381824 401046122496 103628259328      80% /run/media/u/My Data\n';
    expect(parseDf(df), {'/': 17528475648, '/run/media/u/My Data': 103628259328});
  });

  test('the internal SSD drive with the most free space wins; FAT, USB, read-only, network and loop drives never', () {
    final free = {
      '/home': 50e9.toInt(),
      '/run/media/u/My Data': 200e9.toInt(),
      '/mnt/secret': 100e9.toInt(),
      '/boot/efi': 900e9.toInt(),
      '/run/media/u/Stick': 900e9.toInt(),
      '/run/media/u/OldOS': 900e9.toInt(),
      '/mnt/nfs': 900e9.toInt(),
      '/mnt/hdd': 800e9.toInt(),
    };
    final all = {'/run/media/u/My Data', '/mnt/secret', '/boot/efi', '/run/media/u/Stick', '/mnt/hdd', '/mnt/nfs'};
    expect(_choose(free: free, writable: all), '/run/media/u/My Data/Run My AI');
    // An SSD before a spinning disk with more room; the encrypted volume is on the SSD.
    expect(_choose(free: {...free, '/run/media/u/My Data': 1}, writable: all), '/mnt/secret/Run My AI');
    // A drive the user cannot write to is left out.
    expect(_choose(free: free, writable: {'/mnt/secret'}), '/mnt/secret/Run My AI');
    // On the system drive the folder is in the home folder.
    expect(_choose(free: {...free, '/home': 300e9.toInt()}, writable: all), '/home/u/Run My AI');
    // Only spinning disks left besides the system SSD: the SSD.
    expect(_choose(free: free, writable: {'/mnt/hdd'}), '/home/u/Run My AI');
  });

  test('an SSD drive beats a system drive on a spinning disk; the home folder when nothing else fits', () {
    const hddOnly = '/dev/sdb1 / ext4 rw 0 0\n/dev/nvme0n1p4 /data ntfs3 rw 0 0\n';
    expect(_choose(mounts: hddOnly, free: {'/': 9, '/data': 5}, writable: {'/data'}), '/data/Run My AI');
    expect(_choose(mounts: hddOnly, free: {'/': 9, '/data': 5}), '/home/u/Run My AI');
    expect(_choose(mounts: '', free: const {}), '/home/u/Run My AI');
  });

  test('Windows: the fixed NTFS drive with the most free space, an SSD before a hard disk, never USB', () {
    WindowsDrive drive(String letter, String fs, int free, DriveKind kind) =>
        (letter: letter, fileSystem: fs, free: free, kind: kind);
    expect(
      chooseMainFolderWindows([
        drive('C:', 'NTFS', 100, DriveKind.unknown),
        drive('D:', 'NTFS', 300, DriveKind.unknown),
        drive('E:', 'FAT32', 900, DriveKind.ssd),
        drive('F:', 'exFAT', 800, DriveKind.ssd),
      ]),
      r'D:\Run My AI',
    );
    final hdd = drive('D:', 'NTFS', 4000, DriveKind.hardDisk), ssd = drive('C:', 'NTFS', 100, DriveKind.ssd);
    expect(chooseMainFolderWindows([hdd, ssd]), r'C:\Run My AI');
    expect(chooseMainFolderWindows([ssd, hdd]), r'C:\Run My AI');
    expect(chooseMainFolderWindows([ssd, drive('E:', 'NTFS', 900, DriveKind.ssd), hdd]), r'E:\Run My AI');
    expect(chooseMainFolderWindows([hdd, drive('E:', 'NTFS', 9000, DriveKind.usb)]), r'D:\Run My AI');
    expect(chooseMainFolderWindows([drive('E:', 'FAT32', 9, DriveKind.ssd)]), r'C:\Run My AI');
  });

  test('Windows: Get-PhysicalDisk\'s answer gives the kind', () {
    expect(parseWindowsKind('SSD/NVMe\r\n'), DriveKind.ssd);
    expect(parseWindowsKind('SSD/SATA'), DriveKind.ssd);
    expect(parseWindowsKind('Unspecified/NVMe'), DriveKind.ssd);
    expect(parseWindowsKind('HDD/SATA'), DriveKind.hardDisk);
    expect(parseWindowsKind('SSD/USB'), DriveKind.usb);
    expect(parseWindowsKind('Unspecified/SATA'), DriveKind.unknown);
    expect(parseWindowsKind(''), DriveKind.unknown);
  });

  test('Linux: the kind of the drive that holds a folder', () {
    DriveKind kind(String path) => driveKindLinux(mounts: _mounts, path: path, sys: _sys);
    expect(kind('/home/u/models'), DriveKind.ssd);
    expect(kind('/run/media/u/My Data/Run My AI/models'), DriveKind.ssd);
    expect(kind('/mnt/secret/x'), DriveKind.ssd); // an encrypted volume on the SSD
    expect(kind('/mnt/hdd/models'), DriveKind.hardDisk);
    expect(kind('/run/media/u/Stick/models'), DriveKind.usb); // not removable, but udev says USB
    expect(kind('/run/media/u/Card'), DriveKind.usb); // removable
    expect(kind('/run/media/u/Mystery'), DriveKind.unknown); // /sys does not say
    expect(kind('/mnt/nfs/models'), DriveKind.unknown);
    expect(kind('/var/lib/snapd/snap/core/x'), DriveKind.unknown);
    expect(driveKindLinux(mounts: '', path: '/x', sys: _sys), DriveKind.unknown);
  });

  group('saved folders', () {
    late Directory data;
    setUp(() => data = Directory.systemTemp.createTempSync('runmyai-folders-'));
    tearDown(() => data.deleteSync(recursive: true));

    test('chosen once and saved; models and states of an earlier version stay in use', () {
      Directory('${data.path}/models').createSync();
      Directory('${data.path}/states').createSync();
      final first = FolderSet.load(data, chooseMain: () => '/drive/Run My AI');
      expect(first.main, '/drive/Run My AI');
      expect(first.models, '/drive/Run My AI/models');
      expect(first.chats, '/drive/Run My AI/chats');
      expect(first.engine, '/drive/Run My AI/engine');
      expect(first.cache, '${data.path}/states');
      expect(first.readFrom, ['${data.path}/models']);
      expect(Directory('/drive').existsSync(), isFalse);
      // Saved: another choice does not change it.
      final again = FolderSet.load(data, chooseMain: () => '/other/Run My AI');
      expect(again.toJson(), first.toJson());
    });

    test('a fresh install puts everything in the main folder', () {
      final set = FolderSet.load(data, chooseMain: () => '/drive/Run My AI');
      expect(set.cache, '/drive/Run My AI/cache');
      expect(set.readFrom, isEmpty);
    });

    test('a model is found in the downloads folder first, then the folders read from, only with all its files', () {
      for (final d in ['dl', 'mine']) {
        Directory('${data.path}/$d').createSync();
      }
      final set = FolderSet(
        main: data.path,
        models: '${data.path}/dl',
        chats: '',
        cache: '',
        readFrom: ['${data.path}/mine'],
      );
      File('${data.path}/mine/a.gguf').writeAsStringSync('x');
      File('${data.path}/mine/a.json').writeAsStringSync('x');
      File('${data.path}/dl/a.gguf').writeAsStringSync('x');
      expect(set.folderWith(['a.gguf', 'a.json']), '${data.path}/mine');
      File('${data.path}/dl/a.json').writeAsStringSync('x');
      expect(set.folderWith(['a.gguf', 'a.json']), '${data.path}/dl');
      expect(set.folderWith(['b.gguf']), isNull);
    });
  });

  group('moving a folder', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('runmyai-move-'));
    tearDown(() => root.deleteSync(recursive: true));

    void fill(String dir) {
      File('$dir/a.gguf')
        ..createSync(recursive: true)
        ..writeAsStringSync('a' * 1000);
      File('$dir/sub/b.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('b');
      Link('$dir/link').createSync('a.gguf');
    }

    test('every file goes, sub-folders and links included, and the old folder is removed', () async {
      fill('${root.path}/old');
      final seen = <int>[];
      await moveFolder('${root.path}/old', '${root.path}/new', progress: (done, total) => seen.add(total));
      expect(File('${root.path}/new/a.gguf').readAsStringSync(), 'a' * 1000);
      expect(File('${root.path}/new/sub/b.json').readAsStringSync(), 'b');
      expect(Link('${root.path}/new/link').targetSync(), 'a.gguf');
      expect(Directory('${root.path}/old').existsSync(), isFalse);
      expect(seen.last, 1001);
    });

    test('a name already in the new folder stops the move before anything moves', () async {
      fill('${root.path}/old');
      File('${root.path}/new/sub/b.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('mine');
      await expectLater(moveFolder('${root.path}/old', '${root.path}/new'), throwsA(isA<FolderMoveFailure>()));
      expect(File('${root.path}/old/a.gguf').existsSync(), isTrue);
      expect(File('${root.path}/new/a.gguf').existsSync(), isFalse);
      expect(File('${root.path}/new/sub/b.json').readAsStringSync(), 'mine');
    });

    test('not into itself', () async {
      fill('${root.path}/old');
      await expectLater(moveFolder('${root.path}/old', '${root.path}/old/in'), throwsA(isA<FolderMoveFailure>()));
      await expectLater(moveFolder('${root.path}/old', root.path), throwsA(isA<FolderMoveFailure>()));
      expect(File('${root.path}/old/a.gguf').existsSync(), isTrue);
    });

    // Across drives: from the temporary folder to one under the project's .dart_tool, when they are on different
    // filesystems (skipped where they are not).
    Future<Directory?> otherDrive() async {
      final there = Directory('${Directory.current.path}/.dart_tool/runmyai-move-test')..createSync(recursive: true);
      final probe = File('${root.path}/probe')..writeAsStringSync('');
      try {
        probe.renameSync('${there.path}/probe');
        File('${there.path}/probe').deleteSync();
        there.deleteSync(recursive: true);
        return null;
      } on FileSystemException {
        addTearDown(() => there.deleteSync(recursive: true));
        return there;
      }
    }

    test('across drives each file is copied, then the originals are deleted', () async {
      final there = await otherDrive();
      if (there == null) return markTestSkipped('the temporary folder and the project are on one filesystem');
      fill('${root.path}/old');
      await moveFolder('${root.path}/old', '${there.path}/new', free: (_) async => 1 << 40);
      expect(File('${there.path}/new/a.gguf').readAsStringSync(), 'a' * 1000);
      expect(Link('${there.path}/new/link').targetSync(), 'a.gguf');
      expect(Directory('${root.path}/old').existsSync(), isFalse);
    });

    test('across drives without room nothing moves', () async {
      final there = await otherDrive();
      if (there == null) return markTestSkipped('the temporary folder and the project are on one filesystem');
      fill('${root.path}/old');
      await expectLater(
        moveFolder('${root.path}/old', '${there.path}/new', free: (_) async => 10),
        throwsA(isA<FolderMoveFailure>().having((e) => e.message, 'message', contains('Not enough free space'))),
      );
      expect(File('${root.path}/old/a.gguf').readAsStringSync(), 'a' * 1000);
      expect(File('${root.path}/old/sub/b.json').existsSync(), isTrue);
      expect(File('${there.path}/new/a.gguf').existsSync(), isFalse);
    });
  });
}
