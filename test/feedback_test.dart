// Feedback and shared benchmark results: the database's value encoding, the documents' shapes against its rules, the
// engine log's cleaning, and that nothing is sent when sharing is off. Nothing reaches the real database.
// Run: flutter test test/feedback_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/benchmark/benchmark.dart';
import 'package:runmyai/benchmark/hardware.dart';
import 'package:runmyai/benchmark/memory_layout.dart';
import 'package:runmyai/benchmark/series.dart';
import 'package:runmyai/benchmark/share.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/state/feedback.dart';
import 'package:runmyai/state/prefs.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/system/firebase.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/settings/feedback_section.dart';

/// Records what would be sent, and answers with [status].
class _Post {
  _Post([this.status = 200]);

  final int status;
  final bodies = <Map<String, Object?>>[];
  final urls = <Uri>[];

  Future<(int, String)> call(Uri url, String body) async {
    urls.add(url);
    bodies.add((jsonDecode(body) as Map).cast<String, Object?>());
    return (status, '{}');
  }

  /// The one write of the last request.
  Map<String, Object?> get write => ((bodies.last['writes']! as List).single as Map).cast<String, Object?>();

  /// Its fields, as Firestore's typed values.
  Map<String, Object?> get fields => ((write['update']! as Map)['fields']! as Map).cast<String, Object?>();
}

/// An engine with some output.
class _Engine implements Backend, EngineControl {
  _Engine(this.logLines);

  @override
  final List<String> logLines;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _home = '/home/someone';
const _file = ModelFile(id: 'ling-3.0-flash/MXFP4_MOE', quantization: 'MXFP4', sizeBytes: 70147512048);

BenchmarkResult _result() {
  final series = RunSeries();
  for (var i = 0; i < 120; i++) {
    series.add(i * 0.5, {'cpu.load': 20.0 + i % 7, 'gpu.0.power': 80, 'gpu.0.vramTotal': 12});
  }
  final tokens = [for (var i = 0; i < 900; i++) 20.0 + (i % 13) / 3];
  return BenchmarkResult(
    at: DateTime.utc(2026, 11, 17, 10),
    modelName: 'Ling 3.0 Flash',
    contextLength: 65536,
    profileName: 'Automatic',
    flags: '-c 65536 -t 8 --moe-stream model --moe-stream-correction {models}/ling.correction '
        '--moe-stream-vram-experts-file "$_home/Run My AI/models/ling.vram-experts.json" -ctk q8_0',
    memoryCapGiB: 1.5,
    promptLabel: 'Reply speed',
    replyLength: 2000,
    warmups: const ['Hello bro, how are you?', 'Tell me about yourself.'],
    loadMillis: 21000,
    firstTokenMillis: 310,
    promptTokens: 40,
    promptMillis: 200,
    replyTokens: 900,
    replyMillis: 19800,
    tokenGaps: tokens,
    engineStats: const {
      'reply': {'stall_ms_per_token': 2.5, 'hit_rate_percent': 97.1},
    },
    log: const ['srv  load_model: loading model "$_home/Run My AI/models/ling.gguf"'],
    disturbed: const [],
    promptText: 'write a long random story of 1500 words.',
    replyText: 'Once upon a time there was a secret dragon',
    stopReason: 'stop',
    tokenMillis: tokens,
    totalMillis: 20110,
    timeParts: const {'SSD wait': 2.5, 'CPU': 9.1},
    layers: const [
      {'hits': 100, 'misses': 3, 'stall_ms': 1.2},
    ],
    turns: [
      TurnRecord(
        warmup: true,
        firstTokenMillis: 400,
        promptTokens: 20,
        promptMillis: 100,
        replyTokens: 60,
        replyMillis: 1200,
        totalMillis: 1400,
        tokenGaps: tokens.take(60).toList(),
        tokenMillis: tokens.take(60).toList(),
      ),
      TurnRecord(
        warmup: false,
        firstTokenMillis: 310,
        promptTokens: 40,
        promptMillis: 200,
        replyTokens: 900,
        replyMillis: 19800,
        totalMillis: 20110,
        tokenMillis: tokens,
      ),
    ],
    series: series,
    memory: const MemoryLayout(ramSlots: 191, streamedLayers: 41, freeRamGiB: 22.5),
    environment: RunEnvironment(
      engineVersion: '0.8.0-dev (build 12270, commit 1d839794e)',
      appVersion: '0.1.0',
      modelFileBytes: 69847777696,
      modelFileModified: DateTime.utc(2026, 11, 1),
      hardware: const HardwareInfo(cpu: 'AMD Ryzen AI 9 HX 370', threads: 24, gpus: ['RTX 5070 Ti'], ramGiB: 30.6, os: 'Fedora 44, kernel 7.2'),
      onBattery: false,
      addedFlags: const ['--moe-stream-timing 1'],
    ),
  );
}

/// Every text anywhere in [value].
Iterable<String> _texts(Object? value) sync* {
  if (value is String) yield value;
  if (value is Map) {
    yield* value.keys.map((k) => '$k');
    for (final v in value.values) {
      yield* _texts(v);
    }
  }
  if (value is List) {
    for (final v in value) {
      yield* _texts(v);
    }
  }
}

void main() {
  group('Firestore values', () {
    test('each Dart value becomes its typed value', () {
      expect(firestoreValue(null), {'nullValue': null});
      expect(firestoreValue(true), {'booleanValue': true});
      expect(firestoreValue(42), {'integerValue': '42'});
      expect(firestoreValue(1.5), {'doubleValue': 1.5});
      expect(firestoreValue(double.nan), {'nullValue': null});
      expect(firestoreValue('a'), {'stringValue': 'a'});
      expect(firestoreValue([1, 'b']), {
        'arrayValue': {
          'values': [
            {'integerValue': '1'},
            {'stringValue': 'b'},
          ],
        },
      });
      expect(firestoreValue({'x': 2.0}), {
        'mapValue': {
          'fields': {
            'x': {'doubleValue': 2.0},
          },
        },
      });
      expect(() => firestoreValue(DateTime(2026)), throwsArgumentError);
    });

    test('a document is created with the server time and only when new', () async {
      final post = _Post();
      final name = await Firestore(post: post.call).create('feedback', {'kind': 'idea'});
      expect(name, matches(RegExp(r'^feedback/[A-Za-z0-9]{20}$')));
      expect(post.urls.single.toString(), startsWith('https://firestore.googleapis.com/v1/projects/run-my-ai-5876c/'));
      expect(post.urls.single.path, endsWith('/documents:commit'));
      expect(post.urls.single.queryParameters['key'], firebaseApiKey);
      expect((post.write['update']! as Map)['name'], endsWith('/documents/$name'));
      expect(post.write['updateTransforms'], [
        {'fieldPath': 'createdAt', 'setToServerValue': 'REQUEST_TIME'},
      ]);
      expect(post.write['currentDocument'], {'exists': false});
    });

    test('a refusal is a failure', () async {
      expect(Firestore(post: _Post(403).call).create('feedback', {}), throwsA(isA<FirestoreFailure>()));
    });
  });

  group('feedback', () {
    test('the document has only the fields the rules allow, of their types, within their limits', () {
      final doc = feedbackDocument(
        kind: FeedbackKind.bug,
        message: ' ${'m' * 6000} ',
        email: ' me@example.com ',
        log: 'l' * 250000,
        appVersion: '0.1.0',
        os: 'o' * 150,
      );
      expect(doc.keys.toSet().difference({'kind', 'message', 'email', 'log', 'appVersion', 'os'}), isEmpty);
      expect(doc['kind'], 'bug');
      expect((doc['message']! as String).length, 5000);
      expect(doc['email'], 'me@example.com');
      expect((doc['log']! as String).length, 200000);
      expect((doc['os']! as String).length, 100);
      expect(doc.values.every((v) => v is String), isTrue);
      expect({for (final k in FeedbackKind.values) k.id}, {'idea', 'bug', 'love'});

      final bare = feedbackDocument(kind: FeedbackKind.love, message: 'hi', email: '  ');
      expect(bare.keys, unorderedEquals(['kind', 'message']));
    });

    test('a long message is cut by whole characters', () {
      expect(cutText('😀' * 6000, 5000).runes.length, 5000);
    });

    test('the log keeps the engine\'s own lines and drops every line that could hold chat text', () {
      final log = cleanEngineLog([
        '0.02.213.409 I srv  llama_server: initializing ...',
        '0.02.215.821 I srv    load_model: loading model \'$_home/Run My AI/models/ling.gguf\'',
        'llama_moe_stream: 14.20 GiB of pools = 191 slots per layer x 41 layers',
        'ggml_cuda_init: found 1 CUDA devices:',
        '  Device 0: NVIDIA GeForce RTX 5070 Ti Laptop GPU, compute capability 12.0',
        '1.10.000.001 E srv    send_error: task id = 3, error: Failed to parse input at pos 0: my secret plan',
        'and the rest of my secret plan on a second line',
        'note: a line of it that looks like a name',
        '1.20.000.001 W srv  operator(): got exception: [json.exception.parse_error] last read: \'{"messages":[{"content":"hi',
        '1.30.000.001 W slot update_slots: id  0 | task 4 | old: ... the dragon | flew',
        '1.30.000.002 W slot update_slots: id  0 | task 4 | new: ... the dragon | ran',
        '1.40.000.001 I srv  log_server_r: request: {"messages":[{"role":"user","content":"hello"}]}',
        'a reply text line on its own',
        '1.50.000.001 I slot print_timing: id  0 | task 5 | prompt eval time = 200 ms',
        'CUDA error: out of memory',
      ], home: _home, user: 'someone');
      expect(log, contains('initializing'));
      expect(log, contains("loading model '~/Run My AI/models/ling.gguf'"));
      expect(log, contains('191 slots per layer'));
      expect(log, contains('Device 0: NVIDIA'));
      expect(log, contains('prompt eval time'));
      expect(log, contains('CUDA error: out of memory'));
      for (final secret in ['secret', 'dragon', 'hello', 'messages', 'reply text', 'note:', _home]) {
        expect(log, isNot(contains(secret)), reason: secret);
      }
    });

    test('the log keeps its last part within the limit', () {
      final lines = [for (var i = 0; i < 1000; i++) 'llama_moe_stream: line $i ${'x' * 80}'];
      final log = cleanEngineLog(lines, max: 10000);
      expect(log.length, lessThanOrEqualTo(10000));
      expect(log, endsWith(lines.last));
      expect(log, isNot(contains('line 0 ')));
      expect(cleanEngineLog(lines).length, lessThanOrEqualTo(feedbackLogMax));
    });

    group('sending', () {
      late _Post post;
      late ProviderContainer container;

      setUp(() {
        post = _Post();
        container = ProviderContainer(
          overrides: [
            firestoreProvider.overrideWithValue(Firestore(post: post.call)),
            backendProvider.overrideWithValue(
              _Engine(['llama_moe_stream: 191 slots per layer', '1.0.0.1 E srv  send_error: task id = 1, error: my words']),
            ),
            systemNameProvider.overrideWithValue(() => 'Fedora 44, kernel 7.2'),
          ],
        );
        container.listen(feedbackProvider, (_, _) {});
      });
      tearDown(() => container.dispose());

      test('a bug ticks the log by default; it goes cleaned, with the versions', () async {
        final form = container.read(feedbackProvider.notifier);
        expect(container.read(feedbackProvider).attachLog, isFalse);
        form.setKind(FeedbackKind.bug);
        expect(container.read(feedbackProvider).attachLog, isTrue);
        await form.send('It stopped', 'me@example.com');
        expect(container.read(feedbackProvider).phase, FeedbackPhase.sent);
        expect(post.fields.keys, unorderedEquals(['kind', 'message', 'email', 'log', 'appVersion', 'os']));
        expect(post.fields['kind'], {'stringValue': 'bug'});
        expect(post.fields['log'], {'stringValue': 'llama_moe_stream: 191 slots per layer'});
        expect(post.fields['os'], {'stringValue': 'Fedora 44, kernel 7.2'});
      });

      test('other kinds leave the log out unless ticked; a failure says so', () async {
        final form = container.read(feedbackProvider.notifier);
        form.setKind(FeedbackKind.love);
        expect(container.read(feedbackProvider).attachLog, isFalse);
        await form.send('Great', '');
        expect(post.fields.keys, unorderedEquals(['kind', 'message', 'appVersion', 'os']));

        container.dispose();
        container = ProviderContainer(
          overrides: [
            firestoreProvider.overrideWithValue(Firestore(post: _Post(500).call)),
            backendProvider.overrideWithValue(_Engine(const [])),
            systemNameProvider.overrideWithValue(() => 'x'),
          ],
        );
        container.listen(feedbackProvider, (_, _) {});
        await container.read(feedbackProvider.notifier).send('Great', '');
        expect(container.read(feedbackProvider).phase, FeedbackPhase.failed);
      });

      test('an empty message is not sent', () async {
        await container.read(feedbackProvider.notifier).send('   ', '');
        expect(post.bodies, isEmpty);
      });
    });

    testWidgets('the form sends and thanks', (tester) async {
      final post = _Post();
      final scope = ProviderContainer(
        overrides: [
          firestoreProvider.overrideWithValue(Firestore(post: post.call)),
          backendProvider.overrideWithValue(_Engine(const [])),
          systemNameProvider.overrideWithValue(() => 'x'),
        ],
      );
      addTearDown(scope.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: scope,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const Scaffold(body: Center(child: FeedbackSection())),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('feedback-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('feedback-kind-bug')));
      await tester.pump();
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
      await tester.enterText(find.byKey(const Key('feedback-message')), 'It crashed');
      await tester.pump();
      await tester.tap(find.byKey(const Key('feedback-send')));
      await tester.pumpAndSettle();
      expect(find.text('Thank you'), findsOneWidget);
      expect(post.fields['message'], {'stringValue': 'It crashed'});
    });
  });

  group('benchmark results', () {
    test('the document has only the allowed top-level fields; the rest is in data, with no chat text and no folders', () {
      final doc = benchmarkDocument(
        result: _result(),
        installId: 'abc',
        file: _file,
        kvCache: 'q8_0',
        machine: {'kernel': '7.2.7', 'drive': {'filesystem': 'ntfs3', 'type': 'NVMe SSD'}},
        tuned: (fileName: 'ling.gguf', result: {'threads': 10, 'io_threads': 12, 'gpus': [{'name': 'CUDA0', 'mib': 12000}]}),
        layout: const {'ram_slots_per_layer': 191},
        folders: const [_home],
      );
      expect(doc.keys.toSet().difference({'v', 'installId', 'appVersion', 'engineVersion', 'data'}), isEmpty);
      expect(doc['v'], isA<int>());
      expect(doc['installId'], 'abc');
      expect((doc['appVersion']! as String).length, lessThanOrEqualTo(40));
      expect((doc['engineVersion']! as String).length, lessThanOrEqualTo(80));
      expect(doc['data'], isA<Map<String, Object?>>());

      final texts = _texts(doc).join('\n');
      for (final never in [_home, 'someone', 'secret dragon', 'write a long random story', 'Hello bro', 'Run My AI/']) {
        expect(texts, isNot(contains(never)), reason: never);
      }
      final data = doc['data']! as Map;
      final settings = data['settings'] as Map;
      expect(settings['flags'], contains('--moe-stream-correction ling.correction'));
      expect(settings['flags'], contains('--moe-stream-vram-experts-file ling.vram-experts.json'));
      expect(settings['flagsUsed'], contains('--moe-stream-io-threads 12'));
      expect(settings['flagsUsed'], contains('-t 10'));
      expect(data['autotuner'], isNotNull);
      expect((data['machine'] as Map)['drive'], {'filesystem': 'ntfs3', 'type': 'NVMe SSD'});
      final results = data['results'] as Map;
      expect((results['tokenStats'] as Map).keys, containsAll(['p50', 'p90', 'p99']));
      expect(results['tokensPerSecond'], closeTo(900 / 19.8, 0.01));
      // Long number lists go as one text; short ones stay lists.
      expect(results['tokenMillis'], isA<String>());
      expect((results['tokenMillis'] as String).split(','), hasLength(900));
      expect(results['layers'], isA<List<Object?>>());
      expect(((results['turns'] as List).first as Map)['tokenGaps'], isNull, reason: 'the engine\'s times are kept');
      expect(results['engineLayout'], {'ram_slots_per_layer': 191});
      // Every value is one Firestore can hold, and the whole stays well under its limit.
      expect(() => firestoreFields(doc), returnsNormally);
      expect(utf8.encode(jsonEncode(doc)).length, lessThan(benchmarkDocMaxBytes));
    });

    test('folders are cut to file names', () {
      expect(withoutFolders('/a/b/c.gguf'), 'c.gguf');
      expect(withoutFolders(r'C:\Users\x\m.gguf'), 'm.gguf');
      expect(withoutFolders('{models}/q.correction'), 'q.correction');
      expect(withoutFolders('--file=/a/b.json'), '--file=b.json');
      expect(withoutFolders(r'blk\.\d+=CPU'), r'blk\.\d+=CPU');
      expect(withoutFolders('CUDA0=3-5'), 'CUDA0=3-5');
      expect(scrubbed({'x': 'loading $_home/Run/f.gguf at 5 tokens/s'}, const [_home]), {'x': 'loading Run/f.gguf at 5 tokens/s'});
    });

    test('the autotuner\'s result is found by the model file\'s size', () {
      final json = jsonEncode({
        'version': 2,
        'models': {
          'other.gguf:5:1:2': {'threads': 4},
          'ling.gguf:69847777696:1:2': {'threads': 10},
        },
      });
      final t = tunedFor(json, 69847777696)!;
      expect((t.fileName, t.result['threads']), ('ling.gguf', 10));
      expect(tunedFor(json, 7), isNull);
      expect(tunedFor('not json', 5), isNull);
    });

    test('the drive\'s mount, the system and the cores are read from their files', () {
      const mountinfo =
          '22 1 259:3 / / rw,relatime shared:1 - btrfs /dev/nvme0n1p3 rw\n'
          '40 22 259:5 / /run/media/me/Shared\\040Drive rw shared:2 - ntfs3 /dev/nvme0n1p5 rw\n';
      expect(mountOf(mountinfo, '/run/media/me/Shared Drive/x/models'), (filesystem: 'ntfs3', device: '/dev/nvme0n1p5'));
      expect(mountOf(mountinfo, '/home/me/Run My AI/models'), (filesystem: 'btrfs', device: '/dev/nvme0n1p3'));
      expect(parseOsRelease('NAME="Fedora Linux"\nVERSION_ID=44\nHOME_URL="x"\n'), {'NAME': 'Fedora Linux', 'VERSION_ID': '44'});
      expect(
        physicalCores('physical id\t: 0\ncore id\t: 0\n\nphysical id\t: 0\ncore id\t: 0\n\nphysical id\t: 0\ncore id\t: 1\n'),
        2,
      );
      // On this machine, whatever it is, reading never fails.
      expect(readMachine(Directory.systemTemp.path), containsPair('system', Platform.operatingSystem));
    });

    group('sharing', () {
      late Directory dir;
      late _Post post;

      setUp(() {
        dir = Directory.systemTemp.createTempSync('runmyai-share-');
        post = _Post();
      });
      tearDown(() => dir.deleteSync(recursive: true));

      ProviderContainer open() => ProviderContainer(
        overrides: [
          storageProvider.overrideWithValue(Storage(dir)),
          firestoreProvider.overrideWithValue(Firestore(post: post.call)),
        ],
      );

      test('off: nothing is sent', () async {
        final container = open();
        addTearDown(container.dispose);
        container.read(prefsProvider.notifier).setShareBenchmarks(false);
        final sharer = container.read(benchmarkSharerProvider);
        await sharer.share(_result(), file: _file, kvCache: 'q8_0');
        expect(post.bodies, isEmpty);
        expect(sharer.lastSent, isNull);
      });

      test('on: one document to `benchmarks`, with this install\'s lasting id', () async {
        final container = open();
        addTearDown(container.dispose);
        final sharer = container.read(benchmarkSharerProvider);
        await sharer.share(_result(), file: _file, kvCache: 'q8_0');
        await sharer.share(_result(), file: _file, kvCache: 'q8_0');
        expect(post.bodies, hasLength(2));
        expect((post.write['update']! as Map)['name'], contains('/documents/benchmarks/'));
        expect(post.fields.keys.toSet().difference({'v', 'installId', 'appVersion', 'engineVersion', 'data'}), isEmpty);
        final id = (post.fields['installId']! as Map)['stringValue'];
        expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
        expect(((post.bodies.first['writes']! as List).single as Map)['update'], isNotNull);
        expect(File('${dir.path}/install-id').readAsStringSync(), id);
        expect(jsonEncode(post.bodies.last), isNot(contains(dir.path)));
      });

      test('a failed send is only logged', () async {
        final container = ProviderContainer(
          overrides: [
            storageProvider.overrideWithValue(Storage(dir)),
            firestoreProvider.overrideWithValue(Firestore(post: _Post(503).call)),
          ],
        );
        addTearDown(container.dispose);
        await container.read(benchmarkSharerProvider).share(_result(), file: _file, kvCache: 'q8_0');
      });
    });
  });
}
