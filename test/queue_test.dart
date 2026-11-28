// Messages waiting for their turn (Ctrl+Enter during a reply): the order they go out, holding, and what is saved.
// Run: flutter test test/queue_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runmyai/backend/backend.dart';
import 'package:runmyai/data/chat_store.dart';
import 'package:runmyai/data/models.dart';
import 'package:runmyai/data/storage.dart';
import 'package:runmyai/engine/engine_process.dart';
import 'package:runmyai/state/chats.dart';
import 'package:runmyai/state/library.dart';
import 'package:runmyai/state/providers.dart';
import 'package:runmyai/state/queue.dart';

/// Replies stay open until the test ends them.
class _Backend implements Backend {
  final asked = <String>[];
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
    asked.add(messages.last.text);
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
  const file = ModelFile(id: 'm/f', quantization: 'q', sizeBytes: 1);
  const model = CatalogModel(
    id: 'm',
    name: 'M',
    lab: 'L',
    madeBy: '',
    country: '',
    released: '',
    type: '',
    input: '',
    output: '',
    maxContext: '',
    parameters: '1B',
    activeParameters: '1B',
    files: [file],
  );
  late Directory dir;
  late ChatStore store;
  late _Backend backend;
  late ProviderContainer container;
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  ChatsNotifier chats() => container.read(chatsProvider.notifier);
  QueueNotifier queue() => container.read(queueProvider.notifier);
  ChatsState state() => container.read(chatsProvider);
  ChatQueue? waiting() => container.read(queueProvider)[state().openId];
  List<String> texts() => [for (final m in waiting()?.messages ?? const <QueuedMessage>[]) m.text];

  /// Ends the reply being written; the text arrives first.
  Future<void> finish([String text = 'reply']) async {
    final reply = backend.replies.last;
    reply.add(ReplyText(text));
    await reply.close();
    await settle();
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('runmyai-queue-');
    store = await ChatStore.open(dir);
    backend = _Backend();
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        chatStoreProvider.overrideWithValue(store),
        backendProvider.overrideWithValue(backend),
        pickedModelProvider.overrideWithValue((model: model, file: file)),
      ],
    );
    await settle();
  });

  tearDown(() async {
    container.dispose();
    await store.close();
    dir.deleteSync(recursive: true);
  });

  test('waiting messages go out one after another, each as its own message, in the chosen order', () async {
    chats().send('first', file);
    final id = state().openId!;
    queue()
      ..add(id, 'b')
      ..add(id, 'c')
      ..add(id, 'a');
    queue().move(id, 2, 0);
    expect(texts(), ['a', 'b', 'c']);
    final second = waiting()!.messages[1];
    queue().remove(id, second.id);
    expect(texts(), ['a', 'c']);

    await finish();
    expect(backend.asked, ['first', 'a']);
    expect(state().replyingId, id, reason: 'no gap: other chats stay blocked');
    await finish();
    expect(backend.asked, ['first', 'a', 'c']);
    await finish();
    expect(state().replyingId, isNull);
    expect(state().open!.messages.map((m) => m.text), ['first', 'reply', 'a', 'reply', 'c', 'reply']);
    expect(waiting(), isNull);
  });

  test('Stop puts the queue on hold; Send next starts it again and the rest follow', () async {
    chats().send('first', file);
    final id = state().openId!;
    queue()
      ..add(id, 'a')
      ..add(id, 'b');
    await settle();
    chats().stop();
    await settle();
    expect(backend.asked, ['first'], reason: 'nothing starts by itself');
    expect(waiting()!.hold, QueueHold.stopped);

    chats().sendQueued(file);
    expect(backend.asked, ['first', 'a']);
    expect(waiting()!.hold, isNull);
    await finish();
    expect(backend.asked, ['first', 'a', 'b']);
  });

  test('a new message sent while on hold goes first, and the queue stays on hold', () async {
    chats().send('first', file);
    final id = state().openId!;
    queue().add(id, 'a');
    chats().stop();
    await settle();

    chats().send('new', file);
    await finish();
    expect(backend.asked, ['first', 'new']);
    expect(waiting()!.hold, QueueHold.stopped);
    expect(texts(), ['a']);
  });

  test('an engine failure holds the queue; a successful Try again lets it carry on', () async {
    chats().send('first', file);
    final id = state().openId!;
    queue().add(id, 'a');
    backend.replies.last.addError(const EngineFailure('stopped'));
    await settle();
    expect(state().failure, isNotNull);
    expect(waiting()!.hold, QueueHold.failed);
    expect(backend.asked, ['first']);

    chats().retry();
    await settle();
    expect(backend.asked, ['first', 'first']);
    await finish();
    expect(backend.asked, ['first', 'first', 'a']);
  });

  test('Try again does not undo a Stop', () async {
    chats().send('first', file);
    final id = state().openId!;
    queue().add(id, 'a');
    chats().stop();
    await settle();
    chats().send('new', file);
    backend.replies.last.addError(const EngineFailure('stopped'));
    await settle();

    chats().retry();
    await settle();
    await finish();
    expect(backend.asked, ['first', 'new', 'new'], reason: 'still on hold');
    expect(waiting()!.hold, QueueHold.stopped);
  });

  test('the waiting messages of another chat go out with that chat off screen', () async {
    chats().send('first', file);
    final id = state().openId!;
    queue().add(id, 'a');
    chats().newChat();
    await finish();
    expect(backend.asked, ['first', 'a']);
    expect(state().openId, isNull, reason: 'the screen stays where the user went');
    expect(state().replyingId, id);
  });

  test('saved on every change, and on hold after a restart', () async {
    chats().send('first', file);
    final id = state().openId!;
    queue()
      ..add(id, 'a')
      ..add(id, 'b');
    expect(Storage(dir).readQueues()[id], ['a', 'b']);

    final again = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(Storage(dir)),
        chatStoreProvider.overrideWithValue(store),
        backendProvider.overrideWithValue(backend),
      ],
    );
    addTearDown(again.dispose);
    final restored = again.read(queueProvider)[id]!;
    expect(restored.messages.map((m) => m.text), ['a', 'b']);
    expect(restored.hold, QueueHold.stopped);
    await finish();
  });

  test('a deleted chat takes its waiting messages with it', () async {
    chats().send('first', file);
    final id = state().openId!;
    queue().add(id, 'a');
    chats().delete(id);
    await settle();
    expect(container.read(queueProvider), isEmpty);
    expect(Storage(dir).readQueues(), isEmpty);
  });
}
