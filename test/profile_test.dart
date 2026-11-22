// Engine profiles: what a command may hold, and each model's profiles.
// Run: flutter test test/profile_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/commands.dart';
import 'package:runmyai/engine/gguf.dart';
import 'package:runmyai/state/profiles.dart';
import 'package:runmyai/state/providers.dart';

const _file = ModelFile(id: 'm/f', quantization: 'q', sizeBytes: 1);

class _Backend implements Backend {
  @override
  Map<int, String> autoCommands(ModelFile file) => const {65536: 'A=1 -c 65536 --x', 4096: '-c 4096 --moe-stream model --moe-stream-ram-free 0.5GiB'};
  @override
  int maxContext(ModelFile file) => 262144;
  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) => const Stream.empty();
  @override
  Future<List<CatalogModel>> loadCatalog() async => const [];
  @override
  Stream<double> download(ModelFile file) => const Stream.empty();
  @override
  Future<void> deleteDownload(ModelFile file) async {}
}

void main() {
  group('commands', () {
    String? problem(String c, {List<int> taken = const []}) => commandProblem(c, maxContext: 262144, taken: taken);

    test('the context length is the -c flag', () {
      expect(contextOf('A=1 -c 8192 --x'), 8192);
      expect(contextOf('--ctx-size 4096'), 4096);
      expect(contextOf('--ctx-size=4096'), 4096);
      expect(contextOf('--x 1'), isNull);
      expect(contextOf('-c abc'), isNull);
    });

    test('a good command can be saved', () => expect(problem('A=1 -c 8192 --x 1'), isNull));

    test('it needs a context length in range', () {
      expect(problem('--x'), contains('context length'));
      expect(problem('-c 512'), contains('between'));
      expect(problem('-c 524288'), contains('between'));
    });

    test('what the app supplies is left out, however it is written', () {
      for (final c in ['-c 4096 -m x', '-c 4096 --model=x', '-c 4096 --host 0.0.0.0', '-c 4096 --port=1', '-c 4096 -hf a']) {
        expect(problem(c), contains('the app sets it'), reason: c);
      }
    });

    test('settings cannot load another program', () {
      expect(problem('LD_PRELOAD=/x.so -c 4096'), contains('cannot be set'));
      expect(problem('PATH=/x -c 4096'), contains('cannot be set'));
    });

    test('two commands of a profile cannot share a length', () {
      expect(problem('-c 4096', taken: [4096]), contains('already'));
    });
  });

  group('a model\'s own longest context', () {
    Uint8List gguf(int contextLength) {
      final out = BytesBuilder();
      void u32(int v) => out.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
      void u64(int v) => out.add((ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());
      void text(String s) {
        u64(s.length);
        out.add(s.codeUnits);
      }

      out.add('GGUF'.codeUnits);
      u32(3);
      u64(0);
      u64(3);
      text('general.architecture');
      u32(8);
      text('ling');
      text('some.list');
      u32(9);
      u32(4);
      u64(2);
      u32(1);
      u32(2);
      text('ling.context_length');
      u32(4);
      u32(contextLength);
      return out.toBytes();
    }

    test('it comes from the model, whatever its size', () {
      expect(contextLengthIn(gguf(262144)), 262144);
      expect(contextLengthIn(gguf(1048576)), 1048576);
      expect(contextLengthIn(gguf(10485760)), 10485760);
    });

    test('not a model file, or cut short: unknown', () {
      expect(contextLengthIn(Uint8List.fromList('nope'.codeUnits)), isNull);
      final whole = gguf(4096);
      expect(contextLengthIn(Uint8List.sublistView(whole, 0, 30)), isNull);
    });
  });

  group('profiles', () {
    late Directory dir;
    late ProviderContainer container;
    ProviderContainer open() => ProviderContainer(
      overrides: [storageProvider.overrideWithValue(Storage(dir)), backendProvider.overrideWithValue(_Backend())],
    );
    ProfilesNotifier profiles() => container.read(profilesProvider.notifier);

    setUp(() {
      dir = Directory.systemTemp.createTempSync('runmyai-profiles-');
      container = open();
    });
    tearDown(() {
      container.dispose();
      dir.deleteSync(recursive: true);
    });

    test('Auto is there from the start, smallest length first', () {
      final auto = profiles().active(_file);
      expect(auto.isAuto, isTrue);
      expect(auto.lengths, [4096, 65536]);
      final run = profiles().runFor(_file, 65536);
      expect((run.flags, run.memoryCapGiB), ('A=1 -c 65536 --x', null));
    });

    test('a new profile is a full copy of Auto and comes into use', () {
      profiles().create(_file);
      final mine = profiles().active(_file);
      expect((mine.isAuto, mine.name, mine.commands.length), (false, 'Profile 1', 2));
      profiles().create(_file);
      expect(profiles().active(_file).name, 'Profile 2');
    });

    test('its commands are used; the longest length below when one is missing', () {
      profiles().create(_file);
      final mine = profiles().active(_file);
      profiles().update(_file, mine.copyWith(commands: ['-c 8192 --mine']));
      final run = profiles().runFor(_file, 65536);
      expect((run.flags, run.contextLength), ('-c 8192 --mine', 8192));
    });

    test('saved, and still in use after a restart', () {
      profiles().create(_file);
      final id = profiles().active(_file).id;
      final again = open();
      addTearDown(again.dispose);
      expect(again.read(profilesProvider.notifier).active(_file).id, id);
    });

    test('deleting the profile in use goes back to Auto', () {
      profiles().create(_file);
      profiles().delete(_file, profiles().active(_file).id);
      expect(profiles().active(_file).isAuto, isTrue);
      expect(profiles().all(_file), hasLength(1));
    });

    test('Auto\'s streaming command leaves the engine its own RAM headroom', () {
      expect(profiles().runFor(_file, 4096).flags, '-c 4096 --moe-stream model');
      expect(profiles().runFor(_file, 4096).memoryCapGiB, isNull);
    });
  });
}
