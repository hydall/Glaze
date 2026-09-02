import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/converters/prompt_post_processing.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_generation_service.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';

/// Generation stub: records whether a run was requested at all, and hands the
/// test control while it is "streaming".
class _HookGenerationService extends ChatGenerationService {
  _HookGenerationService(super.ref, this._onGenerate);

  final Future<ChatState> Function(ChatSession session) _onGenerate;
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
  }) async {
    calls++;
    return _onGenerate(session);
  }
}

void main() {
  // The send path pings the notification service (haptics → platform channel),
  // which needs a binding to no-op instead of throwing.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('queued user messages', () {
    late AppDatabase db;
    late ProviderContainer container;
    late _HookGenerationService generationService;

    Future<ChatNotifier> setUpChat(
      List<ChatMessage> messages, {
      Future<ChatState> Function(ChatSession session)? onGenerate,
    }) async {
      SharedPreferences.setMockInitialValues({});
      db = AppDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [
          appDbProvider.overrideWithValue(db),
          chatGenerationServiceProvider.overrideWith((ref) {
            return generationService = _HookGenerationService(
              ref,
              // Every generating test here asserts *whether* a run was
              // requested, never its output, so the default stub fails the
              // run instead of faking a reply: the send path settles the
              // state and leaves the messages exactly as written.
              onGenerate ??
                  (session) async => throw StateError('generation stub'),
            );
          }),
        ],
      );
      addTearDown(() async {
        container.dispose();
        ChatSessionService.clearCache();
        await db.close();
      });

      // The generation service is created lazily, and a queued send never asks
      // for one — read it up front so `calls` is observable at 0.
      container.read(chatGenerationServiceProvider);

      final session = ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        messages: messages,
        draft: 'typed text',
      );
      await container
          .read(characterRepoProvider)
          .put(const Character(id: 'c1', name: 'Alice'));
      await container.read(chatRepoProvider).put(session);
      await container.read(chatProvider('c1').future);
      return container.read(chatProvider('c1').notifier);
    }

    test('appends the turn and asks for no reply', () async {
      final notifier = await setUpChat(const [
        ChatMessage(id: 'm1', role: 'assistant', content: 'Hi', timestamp: 1),
      ]);

      final accepted = await notifier.tryAppendMessage('First');

      expect(accepted, isTrue);
      expect(generationService.calls, 0);
      final state = container.read(chatProvider('c1')).requireValue;
      expect(state.messages.map((m) => m.role), ['assistant', 'user']);
      expect(state.messages.last.content, 'First');
      expect(state.isGenerating, isFalse);
      // Nothing is on its way, so the trailing user message keeps the
      // Regenerate button that asks for the reply later.
      expect(state.isSendPending, isFalse);
      final persisted = await container.read(chatRepoProvider).getById('s1');
      expect(persisted!.messages.map((m) => m.id), [
        'm1',
        state.messages.last.id,
      ]);
      expect(persisted.draft, '');
    });

    test('several turns in a row stay separate user messages', () async {
      final notifier = await setUpChat(const [
        ChatMessage(id: 'm1', role: 'assistant', content: 'Hi', timestamp: 1),
      ]);

      expect(await notifier.tryAppendMessage('First'), isTrue);
      expect(await notifier.tryAppendMessage('Second'), isTrue);
      expect(await notifier.tryAppendMessage('Third'), isTrue);

      expect(generationService.calls, 0);
      final persisted = await container.read(chatRepoProvider).getById('s1');
      expect(persisted!.messages.map((m) => m.role), [
        'assistant',
        'user',
        'user',
        'user',
      ]);
      expect(persisted.messages.map((m) => m.content), [
        'Hi',
        'First',
        'Second',
        'Third',
      ]);
    });

    test('a queued turn sent mid-stream cancels the run first', () async {
      // The stub parks the run: `generate()` stays pending, so the chat is
      // genuinely mid-generation while the test writes the next turn.
      final reachedGeneration = Completer<ChatSession>();
      final releaseGeneration = Completer<ChatState>();
      final notifier = await setUpChat(
        const [
          ChatMessage(id: 'm1', role: 'assistant', content: 'Hi', timestamp: 1),
        ],
        onGenerate: (session) {
          if (!reachedGeneration.isCompleted)
            reachedGeneration.complete(session);
          return releaseGeneration.future;
        },
      );

      final send = notifier.sendMessage('First');
      final generatingSession = await reachedGeneration.future;
      expect(
        container.read(chatProvider('c1')).requireValue.isGenerating,
        isTrue,
      );

      final accepted = await notifier.tryAppendMessage('Second');

      expect(accepted, isTrue);
      // One run only: the queued turn stopped it instead of starting another.
      expect(generationService.calls, 1);
      final state = container.read(chatProvider('c1')).requireValue;
      expect(state.isGenerating, isFalse);
      expect(state.messages.map((m) => m.content), ['Hi', 'First', 'Second']);
      expect(state.messages.last.role, 'user');

      // Let the cancelled run unwind; it is stale, so it writes nothing.
      releaseGeneration.complete(
        ChatState(session: generatingSession, isGenerating: false),
      );
      await send;
      expect(
        container
            .read(chatProvider('c1'))
            .requireValue
            .messages
            .map((m) => m.content),
        ['Hi', 'First', 'Second'],
      );
    });

    test('the reply is generated once an ordinary send follows', () async {
      final notifier = await setUpChat(const [
        ChatMessage(id: 'm1', role: 'assistant', content: 'Hi', timestamp: 1),
      ]);

      await notifier.tryAppendMessage('First');
      await notifier.sendMessage('Second');

      expect(generationService.calls, 1);
      final state = container.read(chatProvider('c1')).requireValue;
      expect(state.messages.map((m) => m.content), ['Hi', 'First', 'Second']);
    });

    test('regenerate answers a run of queued turns', () async {
      final notifier = await setUpChat(const [
        ChatMessage(id: 'm1', role: 'assistant', content: 'Hi', timestamp: 1),
      ]);

      await notifier.tryAppendMessage('First');
      await notifier.tryAppendMessage('Second');
      await notifier.regenerateLastAssistant();

      expect(generationService.calls, 1);
    });
  });

  group('queued turns in the prompt', () {
    const macroCtx = MacroContext(
      charName: 'Alice',
      charId: 'c1',
      sessionId: 's1',
    );

    List<Map<String, dynamic>> apiMessages() => buildApiMessages(
      HistoryAssembler(macroCtx).assemble(const [
        ChatMessage(id: 'm1', role: 'assistant', content: 'Hi', timestamp: 1),
        ChatMessage(id: 'm2', role: 'user', content: 'First', timestamp: 2),
        ChatMessage(id: 'm3', role: 'user', content: 'Second', timestamp: 3),
      ]),
    );

    test('reach the prompt as separate user turns', () {
      expect(apiMessages().map((m) => m['role']), [
        'assistant',
        'user',
        'user',
      ]);
    });

    test('the post-processing mode decides how they go out', () {
      // `none` — exactly as written.
      expect(
        postProcessPrompt(
          apiMessages(),
          PromptPostProcessing.none,
        ).map((m) => m['content']).toList(),
        ['Hi', 'First', 'Second'],
      );
      // The merge family squashes the run into one turn.
      final merged = postProcessPrompt(
        apiMessages(),
        PromptPostProcessing.merge,
      );
      expect(merged.map((m) => m['role']), ['assistant', 'user']);
      expect(merged.last['content'], 'First\n\nSecond');
    });
  });
}
