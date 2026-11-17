// The busy check: other programs' CPU and disk use while the autotuner runs, its own share taken out.
// Run: flutter test test/busy_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/system/busy.dart';

BusySample _at(double seconds, {required int total, required int idle, int own = 0, int? disk, int? ownRead}) =>
    (at: Duration(milliseconds: (seconds * 1000).round()), total: total, idle: idle, own: own, disk: disk, ownRead: ownRead);

void main() {
  test('the counters are read from /proc', () {
    expect(
      cpuTimes('cpu  100 5 50 1000 20 10 15 0 30 0\ncpu0 1 2 3 4 5 6 7 8 9 10\n'),
      (total: 1200, idle: 1020),
    );
    // A program name with spaces and brackets.
    expect(processCpu('4242 (auto tuner (x)) R 1 4242 4242 0 -1 4194304 100 0 0 0 1403 57 0 0 20 0 13 0'), 1460);
    const disks = ' 259       0 nvme0n1 712 71 1000 52 381 35 200 79 0 27\n 259       1 nvme0n1p1 10 0 8 1 4 0 4 0 0 4\n';
    expect(diskBytes(disks, 'nvme0n1'), (1000 + 200) * 512);
    expect(diskBytes(disks, 'sda'), isNull);
    expect(readBytes('rchar: 10\nwchar: 0\nread_bytes: 5109055488\nwrite_bytes: 0\n'), 5109055488);
    const mounts = '22 1 259:3 / / rw - btrfs /dev/nvme0n1p3 rw\n'
        '182 53 259:4 / /run/media/me/My\\040Disk rw shared:188 - ntfs3 /dev/nvme0n1p4 rw,uid=1000\n';
    expect(mountSource(mounts, '/run/media/me/My Disk/Run My AI/models/a.gguf'), '/dev/nvme0n1p4');
    expect(mountSource(mounts, '/home/me/a.gguf'), '/dev/nvme0n1p3');
    expect(mountSource(mounts, '/run/media/me/My Diskette/a.gguf'), '/dev/nvme0n1p3');
  });

  test('a quiet PC: the autotuner alone uses the CPU and reads the drive', () {
    // 4 s of 24 threads = 9600 ticks; the autotuner used 1400 of them, others 200; it read 4 GB, others 40 MB.
    final r = busyBetween(
      _at(0, total: 0, idle: 0, disk: 0, ownRead: 0),
      _at(4, total: 9600, idle: 8000, own: 1400, disk: 4040000000, ownRead: 4000000000),
    );
    expect(r.cpu, closeTo(200 / 9600, 1e-9));
    expect(r.diskBytesPerSecond, closeTo(10e6, 1));
    expect(r.busy, isFalse);
  });

  test('other programs using more than 10 % of the CPU make it busy', () {
    final r = busyBetween(
      _at(0, total: 1000, idle: 500, own: 100),
      _at(4, total: 10600, idle: 7700, own: 1500),
    );
    // 9600 ticks, 2400 used, 1400 of them the autotuner's: 1000 others' = 10.4 %.
    expect(r.cpu, closeTo(1000 / 9600, 1e-9));
    expect(r.diskBytesPerSecond, isNull);
    expect(r.busy, isTrue);
  });

  test('other programs moving more than 50 MB/s on the drive make it busy', () {
    final r = busyBetween(
      _at(1, total: 0, idle: 0, disk: 1000, ownRead: 0),
      _at(3, total: 4800, idle: 4700, disk: 1000 + 3000000000 + 120000000, ownRead: 3000000000),
    );
    expect(r.diskBytesPerSecond, closeTo(60e6, 1));
    expect(r.busy, isTrue);
  });

  test('without the autotuner\'s own read count all the drive\'s bytes count as others\'', () {
    final r = busyBetween(
      _at(0, total: 0, idle: 0, disk: 0),
      _at(2, total: 4800, idle: 4700, disk: 80000000),
    );
    expect(r.diskBytesPerSecond, closeTo(40e6, 1));
    expect(r.busy, isFalse);
  });
}
