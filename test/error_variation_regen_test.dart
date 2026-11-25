// A regenerate over an error variation replaces it, error state never leaks
// from one variation to another, and an error variation always shows its own
// text — never the sub-swipes of the variation it failed over.
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
import 'package:glaze_flutter/features/chat/chat_message_service.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/services/saved_message_writer.dart';
import 'package:glaze_flutter/features/chat/services/variation_error_state.dart';

final _messageServiceProvider = Provider(ChatMessageService.new);

const _writer = SavedMessageWriter();

ChatSession _session(ChatMessage message) => ChatSession(
  id: 's1',
  characterId: 'c1',
  sessionIndex: 0,
  messages: [message],
);

/// A reply whose first variation was cleaned (two blue sub-swipes) and whose
/// second variation is an error.
ChatMessage _healthyThenError() => ChatMessage(
  id: 'a1',
  role: 'assistant',
  content: 'boom',
  isError: true,
  swipes: const ['raw good', 'boom'],
  swipeId: 1,
  swipesMeta: [
    {
      'agentSwipes': [
        const AgentSwipe(content: 'raw good').toJson(),
        const AgentSwipe(content: 'clean good', kind: 'cleaned').toJson(),
      ],
      'agentSwipeId': 1,
    },
    {'isError': true},
  ],
);

/// Settles a regenerate the way the real stream service does: through
/// [SavedMessageWriter] with whatever base the notifier handed over. Records
/// that base and the bubble the notifier painted when the run started.
class _RecordingGenerationService extends ChatGenerationService {
  _RecordingGenerationService(super.ref, this._ref, {this.fail = false});

  final Ref _ref;
  final bool fail;
  List<String>? previousSwipes;
  ChatMessage? pendingBubble;

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
    this.previousSwipes = previousSwipes;
    pendingBubble = _ref.read(chatProvider(charId)).value?.messages.last;
    if (fail) {
      return _writer.writeRegenError(
        errorText: 'boom again',
        saveSession: saveSession!,
        regenTargetId: regenTargetId!,
      );
    }
    return _writer.writeAssistant(
      text: 'fresh',
      reasoning: null,
      currentSession: saveSession!,
      isAborted: () => false,
      previousSwipes: previousSwipes,
      previousSwipeId: previousSwipeId,
      previousSwipesMeta: previousSwipesMeta,
      regenTargetId: regenTargetId,
    );
  }
}

Future<(ProviderContainer, _RecordingGenerationService)> _boot(
  ChatMessage reply, {
  bool fail = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  late _RecordingGenerationService service;
  final container = ProviderContainer(
    overrides: [
      appDbProvider.overrideWithValue(db),
      chatGenerationServiceProvider.overrideWith((ref) {
        return service = _RecordingGenerationService(ref, ref, fail: fail);
      }),
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
        ChatSession(
          id: 's1',
          characterId: 'c1',
          sessionIndex: 0,
          messages: [
            const ChatMessage(
              id: 'u1',
              role: 'user',
              content: 'Hi',
              timestamp: 1,
            ),
            reply.copyWith(timestamp: 2),
          ],
        ),
      );
  await container.read(chatProvider('c1').future);
  container.read(chatGenerationServiceProvider);
  return (container, service);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('regenBaseOf', () {
    test('leaves out an active error variation, meta aligned', () {
      final base = regenBaseOf(_healthyThenError());
      expect(base.droppedActiveError, isTrue);
      expect(base.swipes, ['raw good']);
      expect(base.swipesMeta, hasLength(1));
      expect(base.swipesMeta.single['isError'], isNot(true));
    });

    test('keeps a healthy active variation with its live sub-swipes', () {
      const message = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'clean',
        swipes: ['old', 'raw'],
        swipeId: 1,
        genTime: '2s',
        agentSwipes: [
          AgentSwipe(content: 'raw'),
          AgentSwipe(content: 'clean', kind: 'cleaned'),
        ],
        agentSwipeId: 1,
      );
      final base = regenBaseOf(message);
      expect(base.activeIndex, 1);
      expect(base.swipes, ['old', 'raw']);
      expect(base.swipesMeta, hasLength(2));
      expect(base.swipesMeta[1]['genTime'], '2s');
      expect(base.swipesMeta[1]['agentSwipes'], hasLength(2));
      expect(base.swipesMeta[1]['agentSwipeId'], 1);
    });

    test('a lone error variation leaves nothing to build on', () {
      const message = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'boom',
        isError: true,
        swipes: ['boom'],
        swipesMeta: [
          {'isError': true},
        ],
      );
      final base = regenBaseOf(message);
      expect(base.swipes, isEmpty);
      expect(base.swipesMeta, isEmpty);
    });

    test('a legacy error with no per-swipe marker still counts', () {
      const message = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'boom',
        isError: true,
        swipes: ['good', 'boom'],
        swipeId: 1,
      );
      expect(regenBaseOf(message).swipes, ['good']);
    });
  });

  group('writeRegenError', () {
    test('a failed regen over an error replaces it', () {
      final state = _writer.writeRegenError(
        errorText: 'boom again',
        saveSession: _session(_healthyThenError()),
        regenTargetId: 'a1',
      );
      final updated = state.session!.messages.single;
      expect(updated.swipes, ['raw good', 'boom again']);
      expect(updated.swipeId, 1);
      expect(updated.isError, isTrue);
      expect(updated.swipesMeta[0]['isError'], isNot(true));
      expect(updated.swipesMeta[1]['isError'], isTrue);
    });

    test('the error variation does not inherit the previous sub-swipes', () {
      const healthy = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'clean',
        swipes: ['raw'],
        agentSwipes: [
          AgentSwipe(content: 'raw'),
          AgentSwipe(content: 'clean', kind: 'cleaned'),
        ],
        agentSwipeId: 1,
      );
      final state = _writer.writeRegenError(
        errorText: 'boom',
        saveSession: _session(healthy),
        regenTargetId: 'a1',
      );
      final updated = state.session!.messages.single;
      expect(updated.agentSwipes, isEmpty);
      // ...they stay with the variation they belong to.
      expect(updated.swipesMeta[0]['agentSwipes'], hasLength(2));
      expect(updated.swipesMeta[0]['agentSwipeId'], 1);
    });
  });

  group('switching variations', () {
    test('error → healthy → error keeps each variation as it was', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final service = container.read(_messageServiceProvider);
      // Freshly failed over a cleaned reply.
      final failed = _writer
          .writeRegenError(
            errorText: 'boom',
            saveSession: _session(
              const ChatMessage(
                id: 'a1',
                role: 'assistant',
                content: 'clean',
                swipes: ['raw'],
                agentSwipes: [
                  AgentSwipe(content: 'raw'),
                  AgentSwipe(content: 'clean', kind: 'cleaned'),
                ],
                agentSwipeId: 1,
              ),
            ),
            regenTargetId: 'a1',
          )
          .session!;

      final healthy = service.setSwipe(failed, 0, 0).messages.single;
      expect(healthy.isError, isFalse);
      expect(healthy.content, 'clean');
      expect(healthy.agentSwipes, hasLength(2));

      final back = service
          .setSwipe(service.setSwipe(failed, 0, 0), 0, 1)
          .messages
          .single;
      expect(back.isError, isTrue);
      expect(back.content, 'boom');
      expect(back.agentSwipes.map((s) => s.content), ['boom']);

      final again = service
          .setSwipe(
            service.setSwipe(service.setSwipe(failed, 0, 0), 0, 1),
            0,
            0,
          )
          .messages
          .single;
      expect(again.isError, isFalse);
      expect(again.content, 'clean');
    });

    test(
      'an error swipe saved with leftover sub-swipes shows its own text',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final service = container.read(_messageServiceProvider);
        // What chats written before the fix carry: the error swipe's meta holds
        // the sub-swipes of the healthy reply it failed over.
        final corrupted = ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: 'good',
          swipes: const ['good', 'boom'],
          swipeId: 0,
          swipesMeta: [
            {},
            {
              'isError': true,
              'agentSwipes': [
                const AgentSwipe(content: 'good').toJson(),
                const AgentSwipe(
                  content: 'good, cleaned',
                  kind: 'cleaned',
                ).toJson(),
              ],
              'agentSwipeId': 1,
            },
          ],
        );
        final error = service.setSwipe(_session(corrupted), 0, 1);
        final shown = error.messages.single;
        expect(shown.isError, isTrue);
        expect(shown.content, 'boom');
        expect(shown.agentSwipes, hasLength(1));

        // Leaving it does not write the leftovers back.
        final left = service.setSwipe(error, 0, 0).messages.single;
        expect(left.isError, isFalse);
        expect(left.content, 'good');
        expect(left.swipesMeta[1].containsKey('agentSwipes'), isFalse);
      },
    );
  });

  group('regenerateLastAssistant over an error', () {
    test('the new reply takes the error variation\'s place', () async {
      final (container, service) = await _boot(_healthyThenError());

      await container
          .read(chatProvider('c1').notifier)
          .regenerateLastAssistant();

      expect(service.previousSwipes, ['raw good']);
      // The counter does not grow while it streams: 2/2, not 3/3.
      expect(service.pendingBubble!.swipes, hasLength(2));
      expect(service.pendingBubble!.isError, isFalse);

      final reply = container
          .read(chatProvider('c1'))
          .requireValue
          .messages
          .last;
      expect(reply.swipes, ['raw good', 'fresh']);
      expect(reply.swipeId, 1);
      expect(reply.isError, isFalse);
      expect(reply.swipesMeta.map((m) => m['isError'] == true), [false, false]);
      // The healthy variation kept its cleaned pass.
      expect(reply.swipesMeta[0]['agentSwipes'], hasLength(2));
    });

    test('a regen that fails again does not stack errors', () async {
      final (container, _) = await _boot(_healthyThenError(), fail: true);

      await container
          .read(chatProvider('c1').notifier)
          .regenerateLastAssistant();

      final reply = container
          .read(chatProvider('c1'))
          .requireValue
          .messages
          .last;
      expect(reply.swipes, ['raw good', 'boom again']);
      expect(reply.isError, isTrue);
    });

    test('a regen over a healthy reply still adds a variation', () async {
      final (container, service) = await _boot(
        const ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: 'good',
          swipes: ['good'],
        ),
      );

      await container
          .read(chatProvider('c1').notifier)
          .regenerateLastAssistant();

      expect(service.previousSwipes, ['good']);
      final reply = container
          .read(chatProvider('c1'))
          .requireValue
          .messages
          .last;
      expect(reply.swipes, ['good', 'fresh']);
    });
  });
}
