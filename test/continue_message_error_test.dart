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

class _ThrowingGenerationService extends ChatGenerationService {
  _ThrowingGenerationService(super.ref);

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
    throw StateError('continuation failed');
  }
}

void main() {
  test('continuation exception settles generation and allows retry', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    late _ThrowingGenerationService generationService;
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        chatGenerationServiceProvider.overrideWith((ref) {
          return generationService = _ThrowingGenerationService(ref);
        }),
      ],
    );
    addTearDown(() async {
      container.dispose();
      ChatSessionService.clearCache();
      await db.close();
    });

    const session = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [
        ChatMessage(
          id: 'm1',
          role: 'assistant',
          content: 'Existing reply',
          timestamp: 1,
        ),
      ],
    );
    await container
        .read(characterRepoProvider)
        .put(const Character(id: 'c1', name: 'Alice'));
    await container.read(chatRepoProvider).put(session);

    await container.read(chatProvider('c1').future);
    final notifier = container.read(chatProvider('c1').notifier);

    await notifier.continueMessage();

    var state = container.read(chatProvider('c1')).requireValue;
    expect(state.isGenerating, isFalse);
    expect(state.isGeneratingImage, isFalse);
    expect(state.isPostGenRunning, isFalse);
    expect(state.error, contains('continuation failed'));

    await notifier.continueMessage();

    state = container.read(chatProvider('c1')).requireValue;
    expect(generationService.calls, 2);
    expect(state.isGenerating, isFalse);
  });
}
