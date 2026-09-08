import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/services/continuation_message_merger.dart';

void main() {
  test('continuation preserves identity and synchronizes active swipes', () {
    final original = ChatMessage(
      id: 'original',
      role: 'assistant',
      content: 'this hut.',
      swipes: const ['older', 'this hut.'],
      swipeId: 1,
      swipesMeta: const [
        <String, dynamic>{},
        <String, dynamic>{'genTime': 'old'},
      ],
      agentSwipes: const [
        AgentSwipe(content: 'draft', kind: 'final'),
        AgentSwipe(content: 'this hut.', kind: 'cleaned'),
      ],
      agentSwipeId: 1,
    );
    const generated = ChatMessage(
      id: 'temporary',
      role: 'assistant',
      content: '*Cold...*',
    );

    final merged = mergeContinuationMessage(original, generated);

    expect(merged.id, 'original');
    expect(merged.content, 'this hut.\n\n*Cold...*');
    expect(merged.swipes, ['older', 'this hut.\n\n*Cold...*']);
    expect(merged.agentSwipes[0].content, 'draft');
    expect(merged.agentSwipes[1].content, merged.content);
    expect(
      merged.swipesMeta[1]['agentSwipes'],
      merged.agentSwipes.map((swipe) => swipe.toJson()).toList(),
    );
    expect(merged.swipesMeta[1]['agentSwipeId'], 1);
  });

  test('continuation replaces the original and removes temporary message', () {
    const original = ChatMessage(
      id: 'original',
      role: 'assistant',
      content: 'First',
    );
    const generated = ChatMessage(
      id: 'temporary',
      role: 'assistant',
      content: 'Second',
    );

    final messages = mergeContinuationMessages(const [
      ChatMessage(id: 'user', role: 'user', content: 'Prompt'),
      original,
      generated,
    ], original);

    expect(messages, hasLength(2));
    expect(messages!.map((message) => message.id), ['user', 'original']);
    expect(messages.last.content, 'First\n\nSecond');
  });

  test('continuation creates coherent swipe state for legacy messages', () {
    const original = ChatMessage(
      id: 'original',
      role: 'assistant',
      content: 'First',
    );
    const generated = ChatMessage(
      id: 'temporary',
      role: 'assistant',
      content: 'Second',
      reasoning: 'reasoning',
      genTime: '1.0s',
      tokens: 2,
    );

    final merged = mergeContinuationMessage(original, generated);

    expect(merged.swipes, [merged.content]);
    expect(merged.agentSwipes.single.content, merged.content);
    expect(merged.agentSwipes.single.reasoning, 'reasoning');
    expect(merged.agentSwipes.single.genTime, '1.0s');
    expect(merged.agentSwipes.single.tokens, 2);
  });
}
