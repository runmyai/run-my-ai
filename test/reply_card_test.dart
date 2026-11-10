// The card under a reply: the stats worked out from the engine's numbers, what is left out, how they are saved with the
// message (and what an older database keeps), and the card itself.
// Run: flutter test test/reply_card_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/data/chat_db.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/reply_stats.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/chat_stream.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/theme.dart';
import 'package:runmyai/ui/reply_card.dart';

const _timings = {
  'prompt_n': 100,
  'cache_n': 20,
  'prompt_ms': 50.0,
  'predicted_n': 40,
  'predicted_ms': 1000.0,
  'moe_stream': {
    'hit_rate_percent': 90.0,
    'reply': {'stall_ms_per_token': 5.25, 'hit_rate_percent': 96.4},
  },
};

class _Backend implements Backend {
  Map<String, Object?> timings = _timings;
  final replies = <StreamController<ReplyEvent>>[];

  @override
  Stream<ReplyEvent> reply({
    required String chatId,
    required ModelFile model,
    required List<ChatMessage> messages,
    required EngineRun run,
    bool thinking = false,
    int? maxTokens,
  }) {
    final reply = StreamController<ReplyEvent>();
    replies.add(reply);
    return reply.stream;
  }

  @override
  Map<int, String> autoCommands(ModelFile file) => const {defaultContextLength: '-c $defaultContextLength'};
  @override
  int maxContext(ModelFile file) => defaultContextLength;
  @override
  Future<List<CatalogModel>> loadCatalog() async => const [];
  @override
  Stream<double> download(ModelFile file) => const Stream.empty();
  @override
  Future<void> deleteDownload(ModelFile file) async {}
}

void main() {
  group('the numbers of a reply', () {
    test('from the engine\'s timings, with the first word counted from the end of the prompt', () {
      final s = ReplyStats.fromTimings(_timings, wordMillis: const [25, 10], modelName: 'M', profileName: 'Auto', contextLength: 65536);
      expect(s.wordsPerSecond, 40);
      expect(s.promptTokensPerSecond, 2000);
      expect(s.firstWordMillis, 75);
      expect((s.promptTokens, s.replyTokens), (120, 40), reason: 'what was read now and what was kept from before');
      expect(s.totalMillis, 1050);
      expect(s.ssdWaitPerWord, 5.25);
      expect(s.hitRate, 96.4);
      expect((s.modelName, s.profileName, s.contextLength), ('M', 'Auto', 65536));
    });

    test('a number the engine did not give is left out', () {
      final s = ReplyStats.fromTimings(const {'predicted_n': 10, 'predicted_ms': 500.0});
      expect(s.wordsPerSecond, 20);
      expect((s.promptTokensPerSecond, s.hitRate, s.ssdWaitPerWord, s.firstWordMillis), (null, null, null, null));
      expect(replyFacts(s).map((f) => f.$1), ['Generation speed', 'Tokens', 'Time']);
      expect(ReplyStats.fromTimings(const {}).isEmpty, isTrue);
      expect(replyFacts(const ReplyStats()), isEmpty);
      expect(replyBasis(const ReplyStats()), isEmpty);
    });

    test('a prompt read entirely from before has no prompt speed', () {
      final s = ReplyStats.fromTimings(const {'prompt_n': 0, 'cache_n': 50, 'prompt_ms': 1.0, 'predicted_n': 4, 'predicted_ms': 100.0});
      expect(s.promptTokensPerSecond, isNull);
      expect(s.promptTokens, 50);
    });

    test('the lines of the card, and what wrote the reply', () {
      final s = ReplyStats.fromTimings(_timings, wordMillis: const [30], modelName: 'Ling', profileName: 'Auto', contextLength: 65536);
      expect(replyFacts(s), [
        ('Generation speed', '40.0 tokens/s'),
        ('Prompt processing', '2000 tokens/s'),
        ('TTFT', '0.08 s'),
        ('Tokens', 'in 120  ·  out 40'),
        ('Time', '1.1 s'),
        ('SSD wait', '5.3 ms/token'),
        ('Found in RAM', '96 %'),
      ]);
      expect(replyBasis(s), 'Ling  ·  Auto  ·  65k');
    });

    test('it comes back from JSON, an empty value staying empty', () {
      final s = ReplyStats.fromTimings(_timings, modelName: 'M');
      final again = ReplyStats.fromJson(s.toJson());
      expect((again.wordsPerSecond, again.hitRate, again.modelName, again.profileName), (40.0, 96.4, 'M', null));
      expect(s.toJson().containsKey('profileName'), isFalse);
    });
  });

  group('the engine\'s stream', () {
    test('the time of each word is the running total taken apart', () {
      final reader = ChatStreamReader();
      for (final line in [
        'data: {"choices":[{"delta":{"content":"a"}}],"timings":{"predicted_n":1,"predicted_ms":30.0}}',
        'data: {"choices":[{"delta":{"content":"b"}}],"timings":{"predicted_n":2,"predicted_ms":45.0}}',
        'data: {"choices":[{"delta":{"content":"cd"}}],"timings":{"predicted_n":4,"predicted_ms":95.0}}',
        'data: {"choices":[{"delta":{},"finish_reason":"length"}],"timings":{"predicted_n":4,"predicted_ms":95.0}}',
      ]) {
        reader.read(line);
      }
      expect(reader.wordMillis, [30, 15, 25, 25]);
      expect((reader.finished, reader.finishReason), (true, 'length'));
    });

    test('prompt progress comes as an event, before any word', () {
      final reader = ChatStreamReader();
      final events = reader.read('data: {"choices":[],"prompt_progress":{"total":100,"cache":20,"processed":60,"time_ms":400}}');
      final progress = events.single as ReplyProgress;
      expect((progress.processed, progress.total, progress.cached, progress.millis), (60, 100, 20, 400));
    });
  });

  group('saved with the message', () {
    late Directory dir;
    late ChatStore store;
    late _Backend backend;
    late ProviderContainer container;
    const file = ModelFile(id: 'm/f', quantization: 'q', sizeBytes: 1);
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('runmyai-card-');
      store = await ChatStore.open(dir);
      backend = _Backend();
      container = ProviderContainer(
        overrides: [
          storageProvider.overrideWithValue(Storage(dir)),
          chatStoreProvider.overrideWithValue(store),
          backendProvider.overrideWithValue(backend),
        ],
      );
      await settle();
    });

    tearDown(() async {
      container.dispose();
      await store.close();
      dir.deleteSync(recursive: true);
    });

    test('a reply that ends by itself keeps its stats, in the chat and in the database', () async {
      container.read(chatsProvider.notifier).send('hi', file);
      final id = container.read(chatsProvider).openId!;
      final reply = backend.replies.single;
      reply
        ..add(const ReplyText('hello'))
        ..add(const ReplyDone(_timings, wordMillis: [25, 10]));
      await reply.close();
      await settle();
      final shown = container.read(chatsProvider).open!.messages.last;
      expect(shown.stats!.wordsPerSecond, 40);
      expect(shown.stats!.contextLength, defaultContextLength);
      expect(shown.stats!.profileName, 'Auto');
      await store.flush();
      final saved = (await store.messages(id)).last;
      expect(saved.stats!.ssdWaitPerWord, 5.25);
      expect(saved.stats!.firstWordMillis, 75);
      expect((await store.messages(id)).first.stats, isNull, reason: 'a sent message has none');
    });

    test('a reply that was stopped has none', () async {
      container.read(chatsProvider.notifier).send('hi', file);
      final id = container.read(chatsProvider).openId!;
      backend.replies.single.add(const ReplyText('hel'));
      await settle();
      container.read(chatsProvider.notifier).stop();
      await settle();
      expect((await store.messages(id)).last.stats, isNull);
    });
  });

  group('the database', () {
    test('a reply saved again as it grows keeps its stats; a database from before them keeps every message', () {
      final dir = Directory.systemTemp.createTempSync('runmyai-card-db-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/chats.db';
      final db = ChatDb.open(path);
      final now = DateTime(2026);
      db.createChat(ChatInfo(id: 'c', title: 't', createdAt: now, updatedAt: now));
      db.addMessage('c', 0, const ChatMessage(Role.user, 'q'));
      db.addMessage('c', 1, const ChatMessage(Role.assistant, 'a', stats: ReplyStats(wordsPerSecond: 12.5, modelName: 'M')));
      db.addMessage('c', 1, const ChatMessage(Role.assistant, 'a longer'));
      expect(db.path('c').messages.last.stats!.wordsPerSecond, 12.5);
      expect(db.path('c').messages.last.text, 'a longer');
      db.close();

      // An older app's database: without the column.
      final raw = sqlite3.open(path);
      raw.execute('ALTER TABLE messages DROP COLUMN stats');
      raw.execute('PRAGMA user_version = 12');
      raw.close();
      final again = ChatDb.open(path);
      addTearDown(again.close);
      final messages = again.path('c').messages;
      expect(messages.map((m) => m.text), ['q', 'a longer']);
      expect(messages.last.stats, isNull);
      again.addMessage('c', 1, const ChatMessage(Role.assistant, 'a longer', stats: ReplyStats(wordsPerSecond: 3)));
      expect(again.path('c').messages.last.stats!.wordsPerSecond, 3);
    });
  });

  testWidgets('the card shows the numbers it has, and hides the rest', (tester) async {
    final stats = ReplyStats.fromTimings(const {'predicted_n': 40, 'predicted_ms': 1000.0}, modelName: 'Ling 3.0 Flash', contextLength: 65536);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: Center(child: ReplyStatsCard(stats: stats))),
      ),
    );
    expect(find.text('Generation speed'), findsOneWidget);
    expect(find.text('40.0 tokens/s'), findsOneWidget);
    expect(find.text('Prompt processing'), findsNothing);
    expect(find.text('SSD wait'), findsNothing);
    expect(find.byKey(const Key('reply-card-basis')), findsOneWidget);
    expect(find.text('Ling 3.0 Flash  ·  65k'), findsOneWidget);
  });
}
