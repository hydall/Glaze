import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/image_recovery_service.dart';

/// The fix-up every chat open runs over every message: what it repairs, and
/// that a chat with nothing to repair comes back untouched — by structural
/// comparison, since encoding each message to JSON twice to compare took a
/// second of the UI isolate on a long chat.
void main() {
  ChatSession session(List<ChatMessage> messages) => ChatSession(
    id: 's',
    characterId: 'c',
    sessionIndex: 0,
    messages: messages,
  );

  test('a chat with nothing stuck is returned as it is', () {
    final clean = session([
      const ChatMessage(id: 'u', role: 'user', content: 'Hello'),
      ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'Hi there',
        swipes: const ['Hi there', 'Hello!'],
        swipeId: 0,
        swipesMeta: [
          {
            'tokens': 3,
            'agentSwipes': [
              const AgentSwipe(content: 'Hi there', kind: 'final').toJson(),
            ],
            'agentSwipeId': 0,
            'triggeredMemories': [
              {'id': 'm1', 'name': 'A fact'},
            ],
          },
          {'tokens': 2},
        ],
        agentSwipes: const [AgentSwipe(content: 'Hi there', kind: 'final')],
        agentSwipeId: 0,
      ),
    ]);

    final fixed = ImageRecoveryService.fixupSwipesWithImageResults(clean);

    expect(identical(fixed, clean), isTrue);
  });

  test('a finished image block is not taken for a stuck one', () {
    const done =
        'Look: <img data-iig-instruction=\'{"prompt":"cat"}\' src="cat.png">';
    final finished = session([
      ChatMessage(
        id: 'a',
        role: 'assistant',
        content: done,
        swipes: const [done],
        swipeId: 0,
        swipesMeta: [
          {
            'agentSwipes': [
              const AgentSwipe(content: done, kind: 'final').toJson(),
            ],
            'agentSwipeId': 0,
          },
        ],
        agentSwipes: const [AgentSwipe(content: done, kind: 'final')],
        agentSwipeId: 0,
      ),
    ]);

    final fixed = ImageRecoveryService.fixupSwipesWithImageResults(finished);

    expect(identical(fixed, finished), isTrue);
  });

  test('the active swipe is brought in line with the content', () {
    final drifted = session([
      const ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'Edited',
        swipes: ['Original', 'Other'],
        swipeId: 0,
      ),
    ]);

    final fixed = ImageRecoveryService.fixupSwipesWithImageResults(drifted);

    expect(identical(fixed, drifted), isFalse);
    expect(fixed.messages.single.swipes.first, 'Edited');
    // Metadata is padded to the swipes, and the agent swipe backfilled.
    expect(fixed.messages.single.swipesMeta, hasLength(2));
    expect(fixed.messages.single.agentSwipes.single.content, 'Edited');
  });

  test('a generation left stuck in a stored agent swipe becomes an error', () {
    final stuck = session([
      ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'Look: [IMG:GEN:a cat]',
        swipes: const ['Look: [IMG:GEN:a cat]'],
        swipeId: 0,
        swipesMeta: [
          {
            'agentSwipes': [
              {'content': 'Look: [IMG:GEN:a cat]', 'kind': 'final'},
            ],
            'agentSwipeId': 0,
          },
        ],
        agentSwipes: const [
          AgentSwipe(content: 'Look: [IMG:GEN:a cat]', kind: 'final'),
        ],
        agentSwipeId: 0,
      ),
    ]);

    final fixed = ImageRecoveryService.fixupSwipesWithImageResults(stuck);
    final message = fixed.messages.single;

    expect(message.content, contains('[IMG:ERROR:'));
    expect(message.swipes.single, contains('[IMG:ERROR:'));
    expect(message.agentSwipes.single.content, contains('[IMG:ERROR:'));
    final storedAgentSwipes = message.swipesMeta.single['agentSwipes'] as List;
    expect(
      (storedAgentSwipes.single as Map)['content'],
      contains('[IMG:ERROR:'),
    );
  });
}
