import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/controllers/chat_draft_controller.dart';
import 'package:glaze_flutter/features/chat/state/chat_session_write_queue.dart';

class _DelayedDraftRepo extends ChatRepo {
  final Completer<void> started = Completer<void>();
  final Completer<ChatSession?> completion = Completer<ChatSession?>();

  _DelayedDraftRepo(super.db);

  @override
  Future<ChatSession?> updateDraftIfMessageCount({
    required String sessionId,
    required String draft,
    required int expectedMessageCount,
  }) {
    if (!started.isCompleted) started.complete();
    return completion.future;
  }
}

void main() {
  late AppDatabase db;
  late _DelayedDraftRepo repo;
  late ProviderContainer container;

  const message = ChatMessage(
    id: 'm1',
    role: 'assistant',
    content: 'hello',
    timestamp: 1,
  );
  const sessionA = ChatSession(
    id: 'a',
    characterId: 'c1',
    sessionIndex: 0,
    messages: [message],
  );
  const sessionB = ChatSession(
    id: 'b',
    characterId: 'c1',
    sessionIndex: 1,
    messages: [message],
  );

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = _DelayedDraftRepo(db);
    container = ProviderContainer(
      overrides: [chatRepoProvider.overrideWithValue(repo)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test(
    'delayed draft completion cannot switch the active session back',
    () async {
      AsyncValue<ChatState> state = const AsyncData(
        ChatState(session: sessionA),
      );
      final controller = ChatDraftController(
        ref: container.read(Provider((ref) => ref)),
        setState: (next) => state = next,
        getState: () => state,
        writes: ChatSessionWriteQueue(),
      );

      final pending = controller.saveDraft('draft A');
      await repo.started.future;
      state = const AsyncData(ChatState(session: sessionB));
      repo.completion.complete(sessionA.copyWith(draft: 'draft A'));
      await pending;

      expect(state.value!.session!.id, 'b');
    },
  );

  test('delayed draft completion cannot remove a newer message', () async {
    AsyncValue<ChatState> state = const AsyncData(ChatState(session: sessionA));
    final controller = ChatDraftController(
      ref: container.read(Provider((ref) => ref)),
      setState: (next) => state = next,
      getState: () => state,
      writes: ChatSessionWriteQueue(),
    );

    final pending = controller.saveDraft('draft A');
    await repo.started.future;
    state = AsyncData(
      ChatState(
        session: sessionA.copyWith(
          messages: [
            message,
            const ChatMessage(
              id: 'u1',
              role: 'user',
              content: 'new',
              timestamp: 2,
            ),
          ],
        ),
      ),
    );
    repo.completion.complete(sessionA.copyWith(draft: 'draft A'));
    await pending;

    expect(state.value!.messages.map((item) => item.id), ['m1', 'u1']);
  });

  group('the durable row, not the in-memory copy', () {
    late AppDatabase liveDb;
    late ChatRepo liveRepo;
    late ProviderContainer liveContainer;
    late ChatSessionWriteQueue writes;

    setUp(() {
      liveDb = AppDatabase.forTesting(NativeDatabase.memory());
      liveRepo = ChatRepo(liveDb);
      writes = ChatSessionWriteQueue();
      liveContainer = ProviderContainer(
        overrides: [chatRepoProvider.overrideWithValue(liveRepo)],
      );
    });

    tearDown(() async {
      liveContainer.dispose();
      await liveDb.close();
    });

    ChatDraftController controllerFor(
      AsyncValue<ChatState> Function() getState, {
      void Function(AsyncValue<ChatState>)? setState,
    }) => ChatDraftController(
      ref: liveContainer.read(Provider((ref) => ref)),
      setState: setState ?? (_) {},
      getState: getState,
      writes: writes,
    );

    test('an empty draft clears a row the send left holding text', () async {
      await liveRepo.put(sessionA.copyWith(id: 'live', draft: 'hello'));
      // What a send publishes: the state copy says the draft is gone, while
      // the column still holds the text. `ChatState` is not evidence about
      // the row, so the clear has to go through anyway.
      AsyncValue<ChatState> state = AsyncData(
        ChatState(session: sessionA.copyWith(id: 'live', draft: '')),
      );

      await controllerFor(() => state).saveDraft('');

      expect((await liveRepo.getById('live'))?.draft, '');
    });

    test('a draft typed during a send commits against the appended row', () async {
      await liveRepo.put(sessionA.copyWith(id: 'live'));
      final appendStarted = Completer<void>();
      final releaseAppend = Completer<void>();
      AsyncValue<ChatState> state = AsyncData(
        ChatState(session: sessionA.copyWith(id: 'live')),
      );

      // Stands in for the send's durable append: already on the queue, and
      // slow, the way encoding a long chat is slow.
      final append = writes.run(() async {
        appendStarted.complete();
        await releaseAppend.future;
        await liveRepo.mutateMessages(
          sessionId: 'live',
          mutate: (messages) => [
            ...messages,
            const ChatMessage(id: 'u1', role: 'user', content: 'sent'),
          ],
          updatedAt: 2,
        );
      });
      await appendStarted.future;

      // The composer is empty again, so the user starts the next message while
      // the send is still being written. The optimistic paint already counts
      // the sent message.
      state = AsyncData(
        ChatState(
          session: sessionA.copyWith(
            id: 'live',
            messages: [
              message,
              const ChatMessage(id: 'u1', role: 'user', content: 'sent'),
            ],
          ),
        ),
      );
      final saved = controllerFor(() => state).saveDraft('the next one');
      releaseAppend.complete();
      await append;
      await saved;

      expect((await liveRepo.getById('live'))?.draft, 'the next one');
    });
  });
}
