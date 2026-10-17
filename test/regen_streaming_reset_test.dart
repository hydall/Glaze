import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_generation_service.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';

/// Streams a reply into the provider the WebView listens to, then settles the
/// regenerate with [_reply] written over the target — the shape the real
/// service hands back.
class _RegenGenerationService extends ChatGenerationService {
  _RegenGenerationService(super.ref, this._ref);

  final Ref _ref;

  static const _reply = 'Second take';

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
    String guidanceType = 'GENERATION',
    String? regenTargetId,
    String? continueTargetId,
    StudioTurnConfigSnapshot? studioTurnConfig,
  }) async {
    _ref.read(streamingStateProvider(charId).notifier).state =
        const StreamingState(text: _reply);
    final base = saveSession!;
    return ChatState(
      session: base.copyWith(
        messages: [
          for (final m in base.messages)
            m.id == regenTargetId
                ? m.copyWith(
                    content: _reply,
                    swipes: [m.content, _reply],
                    swipeId: 1,
                    tokens: 3,
                  )
                : m,
        ],
      ),
      regenTargetId: regenTargetId,
    );
  }
}

void main() {
  // The completion path pings the notification service (haptics → platform
  // channel), which needs a binding to no-op instead of throwing.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a finished regenerate empties the streaming state', () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        chatGenerationServiceProvider.overrideWith(
          (ref) => _RegenGenerationService(ref, ref),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      ChatSessionService.clearCache();
      await db.close();
    });

    await container
        .read(characterRepoProvider)
        .put(const Character(id: 'c1', name: 'Alice'));
    await container
        .read(chatRepoProvider)
        .put(
          const ChatSession(
            id: 's1',
            characterId: 'c1',
            sessionIndex: 0,
            messages: [
              ChatMessage(id: 'm1', role: 'user', content: 'Hi', timestamp: 1),
              ChatMessage(
                id: 'm2',
                role: 'assistant',
                content: 'First take',
                timestamp: 2,
                tokens: 2,
              ),
            ],
          ),
        );
    await container.read(chatProvider('c1').future);

    await container.read(chatProvider('c1').notifier).regenerateLastAssistant();

    final state = container.read(chatProvider('c1')).requireValue;
    expect(state.isGenerating, isFalse);
    expect(state.messages.last.content, 'Second take');
    // A send and a continue both clear it once their reply lands; a
    // regenerate must too, or the finished reply still reads as streaming.
    expect(container.read(streamingStateProvider('c1')).text, isEmpty);
  });
}
