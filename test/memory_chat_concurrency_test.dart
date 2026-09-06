import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_generation_service.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/memory/controllers/memory_book_write_queue.dart';
import 'package:glaze_flutter/features/memory/controllers/memory_draft_generation_controller.dart';
import 'package:glaze_flutter/features/memory/controllers/memory_settings_mapper.dart';
import 'package:glaze_flutter/features/memory/state/memory_active_drafts_provider.dart';

class _ControlledChatGenerationService extends ChatGenerationService {
  _ControlledChatGenerationService(super.ref);

  final started = Completer<ChatSession>();
  final result = Completer<ChatState>();
  int calls = 0;

  @override
  Future<ChatState> generate({
    required ChatSession session,
    ChatSession? saveSession,
    required String charId,
    required int genId,
    required ChatState currentState,
    required void Function(ChatState) onStateUpdate,
    required bool Function() isAborted,
    List<String>? previousSwipes,
    int previousSwipeId = 0,
    String? previousReasoning,
    String? previousGenTime,
    int? previousTokens,
    List<Map<String, dynamic>>? previousSwipesMeta,
    String? guidanceText,
    String? regenTargetId,
    String? continueTargetId,
    StudioTurnConfigSnapshot? studioTurnConfig,
  }) {
    calls++;
    if (!started.isCompleted) started.complete(session);
    return result.future;
  }

  @override
  Future<void> processImageTags({
    required ChatState currentState,
    required String charId,
    String? targetMessageId,
    CancelToken? cancelToken,
    bool Function()? isCurrentOperation,
    required void Function(ChatState) onStateUpdate,
  }) async {}
}

class _Harness {
  _Harness({
    required this.container,
    required this.chatService,
    required this.chatNotifier,
    required this.memoryController,
    required this.memoryStarted,
    required this.memoryResult,
    required this.memoryCalls,
    required this.charId,
    required this.sessionId,
  });

  final ProviderContainer container;
  final _ControlledChatGenerationService chatService;
  final ChatNotifier chatNotifier;
  final MemoryDraftGenerationController memoryController;
  final Completer<void> memoryStarted;
  final Completer<MemoryDraft> memoryResult;
  final int Function() memoryCalls;
  final String charId;
  final String sessionId;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() condition,
    String stage,
  ) async {
    for (var i = 0; i < 300 && !condition(); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    if (!condition()) throw TestFailure('Timed out waiting for $stage');
  }

  Future<void> pumpUntilPersisted(
    WidgetTester tester,
    Future<bool> Function() condition,
    String stage,
  ) async {
    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (await condition()) return;
    }
    throw TestFailure('Timed out waiting for $stage');
  }

  const initialDraft = MemoryDraft(
    id: 'draft-1',
    messageIds: ['m1'],
    content: '',
  );
  var harnessSequence = 0;

  Future<WidgetRef> pumpRef(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, child) {
            captured = ref;
            return const SizedBox();
          },
        ),
      ),
    );
    return captured;
  }

  Future<_Harness> createHarness(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    ChatSessionService.clearCache();
    final fixtureId = ++harnessSequence;
    final charId = 'c$fixtureId';
    final sessionId = 's$fixtureId';
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    late _ControlledChatGenerationService chatService;
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        chatGenerationServiceProvider.overrideWith((ref) {
          return chatService = _ControlledChatGenerationService(ref);
        }),
      ],
    );
    addTearDown(() async {
      container.dispose();
      ChatSessionService.clearCache();
      await db.close();
    });

    final session = ChatSession(
      id: sessionId,
      characterId: charId,
      sessionIndex: 0,
      messages: [
        ChatMessage(id: 'm1', role: 'user', content: 'Hello', timestamp: 1),
      ],
    );
    final book = MemoryBook(
      id: 'memorybook_$sessionId',
      sessionId: sessionId,
      pendingDrafts: const [initialDraft],
    );
    await container
        .read(characterRepoProvider)
        .put(Character(id: charId, name: 'Alice'));
    await container.read(chatRepoProvider).put(session);
    await container.read(memoryBookRepoProvider).put(book);
    await container.read(chatProvider(charId).future);
    container.read(chatGenerationServiceProvider);

    final widgetRef = await pumpRef(tester, container);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    final memoryStarted = Completer<void>();
    final memoryResult = Completer<MemoryDraft>();
    var memoryCalls = 0;
    MemoryBook? currentBook = book;
    final repo = container.read(memoryBookRepoProvider);
    final writeQueue = MemoryBookWriteQueue(
      readLatest: () => currentBook,
      publish: (book) => currentBook = book,
      persist: repo.put,
    );
    final memoryController = MemoryDraftGenerationController(
      ref: widgetRef,
      charId: charId,
      sessionId: sessionId,
      settingsMapper: const MemorySettingsMapper(),
      bookGetter: () => currentBook,
      persistMutation: writeQueue.mutate,
      generate:
          ({
            required draft,
            required settings,
            required pipeline,
            required messages,
            required charId,
            required sessionId,
            required sessionVars,
            cancelToken,
          }) {
            memoryCalls++;
            if (!memoryStarted.isCompleted) memoryStarted.complete();
            return memoryResult.future;
          },
    );
    addTearDown(memoryController.dispose);

    return _Harness(
      container: container,
      chatService: chatService,
      chatNotifier: container.read(chatProvider(charId).notifier),
      memoryController: memoryController,
      memoryStarted: memoryStarted,
      memoryResult: memoryResult,
      memoryCalls: () => memoryCalls,
      charId: charId,
      sessionId: sessionId,
    );
  }

  Future<void> startMemory(_Harness harness) =>
      harness.memoryController.generateDraft(
        initialDraft.id,
        onStart: () {},
        onComplete: () {},
        onError: (error) => fail('memory generation failed: $error'),
      );

  testWidgets(
    'chat and manual memory overlap and persist only their own marker',
    (tester) async {
      final harness = await createHarness(tester);
      final existingMemoryLease = harness.container
          .read(memoryActiveDraftsProvider.notifier)
          .acquire(harness.sessionId);
      final chatFuture = harness.chatNotifier.regenerateLastAssistant();
      await pumpUntil(
        tester,
        () => harness.chatService.started.isCompleted,
        'chat generation start',
      );
      final chatSession = await harness.chatService.started.future;
      existingMemoryLease.release();
      final memoryFuture = startMemory(harness);
      await pumpUntil(
        tester,
        () => harness.memoryStarted.isCompleted,
        'memory generation start',
      );

      expect(
        harness.memoryController.isDraftGenerating(initialDraft.id),
        isTrue,
      );
      expect(
        harness.container
            .read(chatProvider(harness.charId))
            .requireValue
            .isGenerating,
        isTrue,
      );

      harness.memoryResult.complete(
        initialDraft.copyWith(
          content: 'MEMORY_MARKER',
          keys: ['memory-key'],
          generatedAt: 3,
          updatedAt: 3,
        ),
      );
      var memoryDone = false;
      unawaited(memoryFuture.whenComplete(() => memoryDone = true));
      await pumpUntil(tester, () => memoryDone, 'memory generation completion');
      await memoryFuture;

      final memoryCompletedBook = await harness.container
          .read(memoryBookRepoProvider)
          .getBySessionId(harness.sessionId);
      expect(
        memoryCompletedBook!.pendingDrafts.single.content,
        'MEMORY_MARKER',
      );

      harness.chatService.result.complete(
        ChatState(
          session: chatSession.copyWith(
            messages: [
              ...chatSession.messages,
              const ChatMessage(
                id: 'chat-result',
                role: 'assistant',
                content: 'CHAT_MARKER',
                timestamp: 2,
                isError: true,
              ),
            ],
          ),
          isGenerating: false,
        ),
      );
      await pumpUntilPersisted(tester, () async {
        final session = await harness.container
            .read(chatRepoProvider)
            .getById(harness.sessionId);
        return session?.messages.lastOrNull?.content == 'CHAT_MARKER';
      }, 'chat result persistence');
      await chatFuture;

      final persistedChat = await harness.container
          .read(chatRepoProvider)
          .getById(harness.sessionId);
      final persistedBook = await harness.container
          .read(memoryBookRepoProvider)
          .getBySessionId(harness.sessionId);
      expect(persistedChat!.messages.last.content, 'CHAT_MARKER');
      expect(
        persistedChat.messages.map((message) => message.content),
        isNot(contains('MEMORY_MARKER')),
      );
      expect(persistedBook!.pendingDrafts.single.content, 'MEMORY_MARKER');
      expect(persistedBook.pendingDrafts.single.keys, ['memory-key']);
      expect(
        persistedBook.pendingDrafts.single.content,
        isNot(contains('CHAT_MARKER')),
      );
    },
  );

  testWidgets('same draft cannot start twice while its request is active', (
    tester,
  ) async {
    final harness = await createHarness(tester);
    final first = startMemory(harness);
    await pumpUntil(
      tester,
      () => harness.memoryStarted.isCompleted,
      'memory generation start',
    );
    final second = startMemory(harness);

    await second;
    expect(harness.memoryCalls(), 1);
    expect(harness.memoryController.isDraftGenerating(initialDraft.id), isTrue);

    harness.memoryResult.complete(
      initialDraft.copyWith(content: 'ONLY_RESULT', updatedAt: 6),
    );
    var memoryDone = false;
    unawaited(first.whenComplete(() => memoryDone = true));
    await pumpUntil(tester, () => memoryDone, 'memory generation completion');
    await first;

    final persistedBook = await harness.container
        .read(memoryBookRepoProvider)
        .getBySessionId(harness.sessionId);
    expect(persistedBook!.pendingDrafts.single.content, 'ONLY_RESULT');
  });
}
