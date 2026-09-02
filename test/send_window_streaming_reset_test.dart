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

/// Generation stub that settles the run immediately, so the test only has to
/// look at the state the send published on its way there.
class _StubGenerationService extends ChatGenerationService {
  _StubGenerationService(super.ref);

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
  }) async => ChatState(session: session, isGenerating: false);
}

void main() {
  // The send path pings the notification service (haptics → platform channel),
  // which needs a binding to no-op instead of throwing.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a send empties the streaming state before it paints its bubble', () async {
    // The typing bubble is painted from the streaming state, and the WebView
    // puts it up on the send window — a whole durable append before the
    // pipeline's own reset. Anything the finished run left behind is the reply
    // the user just read, shown again under the message they just sent until
    // the first new token replaces it.
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        chatGenerationServiceProvider.overrideWith(
          (ref) => _StubGenerationService(ref),
        ),
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
        ChatMessage(id: 'm1', role: 'assistant', content: 'Hi', timestamp: 1),
      ],
    );
    await container
        .read(characterRepoProvider)
        .put(const Character(id: 'c1', name: 'Alice'));
    await container.read(chatRepoProvider).put(session);
    await container.read(chatProvider('c1').future);
    final notifier = container.read(chatProvider('c1').notifier);

    // What a finished run leaves behind: the last delta it published.
    container.read(streamingStateProvider('c1').notifier).state =
        const StreamingState(text: 'the reply they already read');

    String? streamingTextInSendWindow;
    final subscription = container.listen<AsyncValue<ChatState>>(
      chatProvider('c1'),
      (previous, next) {
        if (streamingTextInSendWindow == null &&
            next.value?.isSendPending == true) {
          streamingTextInSendWindow = container
              .read(streamingStateProvider('c1'))
              .text;
        }
      },
    );
    addTearDown(subscription.close);

    await notifier.sendMessage('Next');

    expect(
      streamingTextInSendWindow,
      isNotNull,
      reason: 'the send never painted its send window',
    );
    expect(streamingTextInSendWindow, isEmpty);
  });
}
