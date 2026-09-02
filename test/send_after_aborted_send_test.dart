import 'dart:async';

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

/// Generation stub that parks the run, so the test can abort a genuinely
/// in-flight generation and send again while the chat ends on a user message.
class _ParkedGenerationService extends ChatGenerationService {
  _ParkedGenerationService(super.ref, this._onGenerate);

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

  test('a send after an aborted send is not dropped', () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final reachedGeneration = Completer<ChatSession>();
    final releaseGeneration = Completer<ChatState>();
    late _ParkedGenerationService generationService;
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        chatGenerationServiceProvider.overrideWith((ref) {
          return generationService = _ParkedGenerationService(ref, (session) {
            if (reachedGeneration.isCompleted) {
              // The second send only has to reach the pipeline; failing it
              // settles the run without writing a reply the test would then
              // have to account for.
              throw StateError('generation stub');
            }
            reachedGeneration.complete(session);
            return releaseGeneration.future;
          });
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
        ChatMessage(id: 'm1', role: 'assistant', content: 'Hi', timestamp: 1),
      ],
    );
    await container
        .read(characterRepoProvider)
        .put(const Character(id: 'c1', name: 'Alice'));
    await container.read(chatRepoProvider).put(session);
    await container.read(chatProvider('c1').future);
    final notifier = container.read(chatProvider('c1').notifier);

    final first = notifier.sendMessage('First');
    final parkedSession = await reachedGeneration.future;
    // Stop before anything streamed: the chat is left ending on the user
    // message, with the assistant it accepted now two turns back.
    await notifier.abortGeneration();
    expect(
      container.read(chatProvider('c1')).requireValue.messages.last.role,
      'user',
    );

    await notifier.sendMessage('Second');

    // The append targets the trailing message, not the older assistant, so the
    // guarded write lands instead of being refused and silently discarded.
    final persisted = await container.read(chatRepoProvider).getById('s1');
    expect(persisted!.messages.map((m) => m.content), [
      'Hi',
      'First',
      'Second',
    ]);
    expect(generationService.calls, 2);

    // Let the aborted run unwind; it is stale, so it writes nothing.
    releaseGeneration.complete(
      ChatState(session: parkedSession, isGenerating: false),
    );
    await first;
    expect(
      container
          .read(chatProvider('c1'))
          .requireValue
          .messages
          .map((m) => m.content),
      ['Hi', 'First', 'Second'],
    );
  });
}
