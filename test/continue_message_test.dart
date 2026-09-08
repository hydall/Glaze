import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_generation_service.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';

/// Generation stub that hands control back to the test while the run is
/// "streaming", so it can observe the state a continuation exposes to the
/// WebView layer.
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
    StudioTurnConfigSnapshot? studioTurnConfig,
  }) async {
    calls++;
    return _onGenerate(session);
  }
}

void main() {
  // The completion path pings the notification service (haptics → platform
  // channel), which needs a binding to no-op instead of throwing.
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ProviderContainer container;
  late _HookGenerationService generationService;

  Future<ChatNotifier> setUpChat(
    List<ChatMessage> messages,
    Future<ChatState> Function(ChatSession session) onGenerate,
  ) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        chatGenerationServiceProvider.overrideWith((ref) {
          return generationService = _HookGenerationService(ref, onGenerate);
        }),
      ],
    );
    addTearDown(() async {
      container.dispose();
      ChatSessionService.clearCache();
      await db.close();
    });

    final session = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      messages: messages,
    );
    await container
        .read(characterRepoProvider)
        .put(const Character(id: 'c1', name: 'Alice'));
    await container.read(chatRepoProvider).put(session);
    await container.read(chatProvider('c1').future);
    return container.read(chatProvider('c1').notifier);
  }

  test('continuation marks the message it extends while streaming', () async {
    String? targetDuringGeneration;
    final notifier = await setUpChat(
      const [
        ChatMessage(id: 'm1', role: 'user', content: 'Hi', timestamp: 1),
        ChatMessage(
          id: 'm2',
          role: 'assistant',
          content: 'First',
          timestamp: 2,
        ),
      ],
      (session) async {
        targetDuringGeneration = container
            .read(chatProvider('c1'))
            .requireValue
            .continuationTargetId;
        return ChatState(
          session: session.copyWith(
            messages: [
              ...session.messages,
              const ChatMessage(
                id: 'gen',
                role: 'assistant',
                content: 'Second',
                timestamp: 3,
              ),
            ],
          ),
          isGenerating: false,
        );
      },
    );

    await notifier.continueMessage();

    // The bubble being extended is flagged for the whole streaming window …
    expect(targetDuringGeneration, 'm2');
    final state = container.read(chatProvider('c1')).requireValue;
    // … and released once the merged message lands, so the settled chat has no
    // separate assistant block for the continuation.
    expect(state.continuationTargetId, isNull);
    expect(state.messages.map((m) => m.id), ['m1', 'm2']);
    expect(state.messages.last.content, 'First\n\nSecond');
    expect(state.isGenerating, isFalse);
  });

  test('continue on a trailing user message generates a reply', () async {
    final notifier = await setUpChat(const [
      ChatMessage(id: 'm1', role: 'user', content: 'Hi', timestamp: 1),
    ], (session) async => throw StateError('generation failed'));

    await notifier.continueMessage();

    // There is nothing to extend, so the request must still reach the
    // generation pipeline instead of being dropped silently.
    expect(generationService.calls, 1);
    final state = container.read(chatProvider('c1')).requireValue;
    expect(state.continuationTargetId, isNull);
    expect(state.isGenerating, isFalse);
  });

  test('aborting a continuation merges the partial text in place', () async {
    late ChatNotifier notifier;
    notifier = await setUpChat(
      const [
        ChatMessage(
          id: 'm1',
          role: 'assistant',
          content: 'First',
          timestamp: 1,
        ),
      ],
      (session) async {
        container.read(streamingStateProvider('c1').notifier).state =
            const StreamingState(text: 'Half a sen');
        await notifier.abortGeneration();
        return ChatState(session: session, isGenerating: false);
      },
    );

    await notifier.continueMessage();
    final state = container.read(chatProvider('c1')).requireValue;
    expect(state.messages, hasLength(1));
    expect(state.messages.single.id, 'm1');
    expect(state.messages.single.content, 'First\n\nHalf a sen');
    expect(state.continuationTargetId, isNull);
    expect(state.isGenerating, isFalse);
  });
}
