import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/chat_message_service.dart';
import 'package:glaze_flutter/features/chat/services/saved_message_writer.dart';

void main() {
  group('AgentSwipe', () {
    test('toJson/fromJson roundtrip preserves all fields', () {
      final swipe = AgentSwipe(
        content: 'hello',
        kind: 'cleaned',
        reasoning: 'thought',
        genTime: '1.5s',
        tokens: 42,
        studioOutputs: [
          {'id': 'out1', 'content': 'brief'},
        ],
        parentSwipeId: 0,
      );
      final json = swipe.toJson();
      final restored = AgentSwipe.fromJson(json);
      expect(restored.content, 'hello');
      expect(restored.kind, 'cleaned');
      expect(restored.reasoning, 'thought');
      expect(restored.genTime, '1.5s');
      expect(restored.tokens, 42);
      expect(restored.parentSwipeId, 0);
      expect(restored.studioOutputs.length, 1);
      expect(restored.studioOutputs[0]['id'], 'out1');
    });

    test('fromJson defaults kind to final when missing', () {
      final restored = AgentSwipe.fromJson({'content': 'text'});
      expect(restored.kind, 'final');
      expect(restored.content, 'text');
    });

    test('fromJson defaults studioOutputs to empty list when missing', () {
      final restored = AgentSwipe.fromJson({'content': 'text'});
      expect(restored.studioOutputs, isEmpty);
    });

    test('copyWith creates a modified copy', () {
      const original = AgentSwipe(content: 'a', kind: 'final');
      final modified = original.copyWith(content: 'b', kind: 'cleaned');
      expect(modified.content, 'b');
      expect(modified.kind, 'cleaned');
      expect(modified.reasoning, isNull);
    });
  });

  group('ChatMessage agentSwipes serialization', () {
    test('toJson includes agentSwipes and agentSwipeId', () {
      final msg = ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: 'active',
        swipes: ['active', 'old'],
        swipeId: 1,
        agentSwipes: [
          const AgentSwipe(content: 'final', kind: 'final'),
          const AgentSwipe(content: 'cleaned', kind: 'cleaned'),
        ],
        agentSwipeId: 1,
      );
      final json = msg.toJson();
      expect(json['agentSwipes'], isA<List<dynamic>>());
      expect((json['agentSwipes'] as List<dynamic>).length, 2);
      expect(json['agentSwipeId'], 1);
    });

    test('fromJson restores agentSwipes with correct kinds', () {
      final json = {
        'id': 'm1',
        'role': 'assistant',
        'content': 'active',
        'swipes': ['a', 'b'],
        'swipeId': 1,
        'agentSwipes': [
          {'content': 'final', 'kind': 'final'},
          {'content': 'cleaned', 'kind': 'cleaned'},
        ],
        'agentSwipeId': 1,
      };
      final msg = ChatMessage.fromJson(json);
      expect(msg.agentSwipes.length, 2);
      expect(msg.agentSwipes[0].kind, 'final');
      expect(msg.agentSwipes[1].kind, 'cleaned');
      expect(msg.agentSwipeId, 1);
    });

    test('fromJson defaults agentSwipes to empty when absent', () {
      final json = {
        'id': 'm1',
        'role': 'assistant',
        'content': 'text',
        'swipes': ['text'],
        'swipeId': 0,
      };
      final msg = ChatMessage.fromJson(json);
      expect(msg.agentSwipes, isEmpty);
      expect(msg.agentSwipeId, 0);
    });
  });

  group('SavedMessageWriter nested swipes', () {
    const writer = SavedMessageWriter();

    ChatSession makeSessionWithMessage(ChatMessage msg) {
      return ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        messages: [msg],
      );
    }

    test('new generation seeds agentSwipes with a single final', () {
      final session = makeSessionWithMessage(
        ChatMessage(id: 'u1', role: 'user', content: 'hello'),
      );
      final state = writer.writeAssistant(
        text: 'response',
        reasoning: null,
        currentSession: session,
        isAborted: () => false,
      );
      final assistant = state.session!.messages.last;
      expect(assistant.agentSwipes.length, 1);
      expect(assistant.agentSwipes[0].kind, 'final');
      expect(assistant.agentSwipes[0].content, 'response');
      expect(assistant.agentSwipeId, 0);
    });

    test('full regen resets agentSwipes to a single final', () {
      final existing = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'old',
        swipes: ['old'],
        swipeId: 0,
        agentSwipes: [
          const AgentSwipe(content: 'old', kind: 'final'),
          const AgentSwipe(content: 'cleaned', kind: 'cleaned'),
        ],
        agentSwipeId: 1,
      );
      final session = makeSessionWithMessage(existing);
      final state = writer.writeAssistant(
        text: 'new response',
        reasoning: null,
        currentSession: session,
        isAborted: () => false,
        previousSwipes: ['old'],
        previousSwipeId: 0,
        regenTargetId: 'a1',
      );
      final updated = state.session!.messages.first;
      expect(updated.agentSwipes.length, 1);
      expect(updated.agentSwipes[0].kind, 'final');
      expect(updated.agentSwipes[0].content, 'new response');
      expect(updated.agentSwipeId, 0);
      // Full regen adds to swipes (green).
      expect(updated.swipes.length, 2);
      expect(updated.swipeId, 1);
    });
  });

  group('SavedMessageWriter per-swipe error markers', () {
    const writer = SavedMessageWriter();

    ChatSession makeSessionWithMessage(ChatMessage msg) {
      return ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        messages: [msg],
      );
    }

    test('writeError marks the lone swipe meta with isError', () {
      final session = makeSessionWithMessage(
        ChatMessage(id: 'u1', role: 'user', content: 'hello'),
      );
      final state = writer.writeError(
        errorText: 'boom',
        currentSession: session,
      );
      final errMsg = state.session!.messages.last;
      expect(errMsg.isError, isTrue);
      expect(errMsg.swipes, ['boom']);
      expect(errMsg.swipeId, 0);
      expect(errMsg.swipesMeta.length, 1);
      expect(errMsg.swipesMeta[0]['isError'], isTrue);
    });

    test('writeRegenError appends an error swipe whose meta marks isError only '
        'on the error index', () {
      final existing = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'good',
        swipes: ['good'],
        swipeId: 0,
        swipesMeta: [
          <String, dynamic>{'genTime': '1.0s'},
        ],
      );
      final session = makeSessionWithMessage(existing);
      final state = writer.writeRegenError(
        errorText: 'boom',
        saveSession: session,
        regenTargetId: 'a1',
      );
      final updated = state.session!.messages.first;

      // Error swipe is appended and becomes active.
      expect(updated.swipes, ['good', 'boom']);
      expect(updated.swipeId, 1);
      expect(updated.isError, isTrue);

      // Meta stays aligned 1:1 with swipes; only the error index is marked.
      expect(updated.swipesMeta.length, 2);
      expect(updated.swipesMeta[0]['isError'], isNot(true));
      expect(updated.swipesMeta[0]['genTime'], '1.0s');
      expect(updated.swipesMeta[1]['isError'], isTrue);
    });

    test(
      'writeRegenError keeps meta aligned when the original had no meta',
      () {
        final existing = ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: 'good',
          swipes: ['good'],
          swipeId: 0,
          genTime: '2.0s',
        );
        final session = makeSessionWithMessage(existing);
        final state = writer.writeRegenError(
          errorText: 'boom',
          saveSession: session,
          regenTargetId: 'a1',
        );
        final updated = state.session!.messages.first;
        expect(updated.swipes.length, 2);
        expect(updated.swipesMeta.length, 2);
        // Prior swipe keeps its badge meta and is NOT flagged as an error.
        expect(updated.swipesMeta[0]['isError'], isNot(true));
        expect(updated.swipesMeta[0]['genTime'], '2.0s');
        // Only the appended error swipe carries the marker.
        expect(updated.swipesMeta[1]['isError'], isTrue);
      },
    );
  });

  group('swipe deletion', () {
    test('green deletion restores the shifted variation and nested state', () {
      final message = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'middle cleaned',
        swipes: const ['first', 'middle', 'last'],
        swipeId: 1,
        swipesMeta: [
          <String, dynamic>{
            'reasoning': 'first reasoning',
            'agentSwipes': [
              const AgentSwipe(
                content: 'first cleaned',
                kind: 'cleaned',
              ).toJson(),
            ],
          },
          <String, dynamic>{},
          <String, dynamic>{
            'isError': true,
            'agentSwipeId': 1,
            'agentSwipes': [
              const AgentSwipe(content: 'last final').toJson(),
              const AgentSwipe(
                content: 'last cleaned',
                kind: 'cleaned',
                reasoning: 'last reasoning',
                tokens: 17,
              ).toJson(),
            ],
          },
        ],
        agentSwipes: const [
          AgentSwipe(content: 'middle', kind: 'final'),
          AgentSwipe(content: 'middle cleaned', kind: 'cleaned'),
        ],
        agentSwipeId: 1,
      );

      final result = ChatMessageService.removeActiveSwipe(message)!;

      expect(result.swipes, ['first', 'last']);
      expect(result.swipesMeta, hasLength(2));
      expect(result.swipeId, 1);
      expect(result.agentSwipes, hasLength(2));
      expect(result.agentSwipeId, 1);
      expect(result.content, 'last cleaned');
      expect(result.reasoning, 'last reasoning');
      expect(result.tokens, 17);
      expect(result.isError, isTrue);
    });

    test('green deletion rejects the sole variation', () {
      const message = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'only',
        swipes: ['only'],
      );
      expect(ChatMessageService.removeActiveSwipe(message), isNull);
    });

    test('blue deletion reindexes parents and replaces deleted final', () {
      final message = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'final 2',
        swipes: const ['final 2'],
        swipesMeta: const [<String, dynamic>{}],
        agentSwipes: const [
          AgentSwipe(content: 'final 1', kind: 'final'),
          AgentSwipe(content: 'final 2', kind: 'final'),
          AgentSwipe(content: 'cleaned', kind: 'cleaned', parentSwipeId: 1),
        ],
        agentSwipeId: 1,
      );

      final result = ChatMessageService.removeActiveAgentSwipe(message)!;

      expect(result.agentSwipes, hasLength(2));
      expect(result.agentSwipeId, 1);
      expect(result.content, 'cleaned');
      expect(result.swipes, ['final 1']);
      expect(result.agentSwipes[1].parentSwipeId, 0);
      expect(result.swipesMeta[0]['agentSwipeId'], 1);
    });

    test('blue deletion rejects the sole variation', () {
      const message = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'only',
        agentSwipes: [AgentSwipe(content: 'only')],
      );
      expect(ChatMessageService.removeActiveAgentSwipe(message), isNull);
    });
  });
}
