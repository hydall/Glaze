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

  group('generation stats survive the merge (INV-CM7)', () {
    test('the badge counts both runs, not just the continuation', () {
      const original = ChatMessage(
        id: 'original',
        role: 'assistant',
        content: 'First',
        genTime: '4.0s',
        tokens: 120,
        swipes: ['First'],
        swipesMeta: [<String, dynamic>{'genTime': '4.0s', 'tokens': 120}],
      );
      const generated = ChatMessage(
        id: 'temporary',
        role: 'assistant',
        content: 'Second',
        genTime: '2.5s',
        tokens: 30,
      );

      final merged = mergeContinuationMessage(original, generated);

      expect(merged.tokens, 150);
      expect(merged.genTime, '6.5s');
      // The swipe's meta is what a swipe round-trip restores from, so it has
      // to agree with the message or the badge dies on the way back.
      expect(merged.swipesMeta[0]['tokens'], 150);
      expect(merged.swipesMeta[0]['genTime'], '6.5s');
      expect(merged.agentSwipes.single.tokens, 150);
      expect(merged.agentSwipes.single.genTime, '6.5s');
    });

    test('a missing stat on either side does not zero the total', () {
      const original = ChatMessage(
        id: 'original',
        role: 'assistant',
        content: 'First',
        tokens: 120,
      );
      const generated = ChatMessage(
        id: 'temporary',
        role: 'assistant',
        content: 'Second',
      );

      final merged = mergeContinuationMessage(original, generated);

      expect(merged.tokens, 120);
      expect(merged.genTime, isNull);
    });

    test('an unparseable time is treated as absent, never as a wipe', () {
      expect(sumContinuationGenTime('4.0s', 'not a time'), '4.0s');
      expect(sumContinuationGenTime('not a time', '2.0s'), '2.0s');
      expect(sumContinuationGenTime('junk', 'junk'), 'junk');
      expect(sumContinuationGenTime(null, null), isNull);
    });

    test('tokens add up, or fall through to whichever side has a count', () {
      expect(sumContinuationTokens(10, 5), 15);
      expect(sumContinuationTokens(null, 5), 5);
      expect(sumContinuationTokens(10, null), 10);
      expect(sumContinuationTokens(null, null), isNull);
    });
  });

  group('continuation boundary (INV-CM7)', () {
    test('records where the continuation starts in the merged text', () {
      const original = ChatMessage(
        id: 'original',
        role: 'assistant',
        content: 'The opening line.',
      );
      const generated = ChatMessage(
        id: 'temporary',
        role: 'assistant',
        content: 'The continuation.',
      );

      final merged = mergeContinuationMessage(original, generated);

      expect(merged.continuationOffset, 'The opening line.'.length + 2);
      expect(
        merged.content.substring(merged.continuationOffset!),
        'The continuation.',
      );
      expect(merged.swipesMeta[0]['continuationOffset'], merged.continuationOffset);
    });

    test('a continuation that produced nothing keeps the old boundary', () {
      const original = ChatMessage(
        id: 'original',
        role: 'assistant',
        content: 'One\n\nTwo',
        continuationOffset: 5,
      );
      const generated = ChatMessage(
        id: 'temporary',
        role: 'assistant',
        content: '',
      );

      expect(mergeContinuationMessage(original, generated).continuationOffset, 5);
    });

    test('a message that is entirely the continuation has no boundary', () {
      expect(continuationOffsetFor('', 'everything'), 0);
      expect(continuationOffsetFor('something', ''), 0);
    });

    test('previewSource slices from the boundary and tolerates a bad one', () {
      expect(previewSource('One\n\nTwo', 5), 'Two');
      expect(previewSource('One\n\nTwo', null), 'One\n\nTwo');
      expect(previewSource('One\n\nTwo', 0), 'One\n\nTwo');
      // Past the end, negative, or slicing to nothing: show the whole message
      // rather than an empty preview.
      expect(previewSource('One\n\nTwo', 999), 'One\n\nTwo');
      expect(previewSource('One\n\nTwo', -3), 'One\n\nTwo');
      expect(previewSource('One\n\n   ', 5), 'One\n\n   ');
    });
  });

  group('joinContinuationReasoning', () {
    test('files the continuation under an accent Continue header', () {
      expect(
        joinContinuationReasoning('Opening thought', 'Extension thought'),
        'Opening thought\n\n---\n\n==accent==Continue==\n\nExtension thought',
      );
    });

    test('keeps the original when the continuation reasoned about nothing', () {
      expect(
        joinContinuationReasoning('Opening thought', null),
        'Opening thought',
      );
      expect(
        joinContinuationReasoning('Opening thought', '  '),
        'Opening thought',
      );
      expect(joinContinuationReasoning(null, '   '), isNull);
    });

    test('needs no header when the original turn had no reasoning', () {
      expect(
        joinContinuationReasoning(null, 'Extension thought'),
        'Extension thought',
      );
      expect(
        joinContinuationReasoning('', 'Extension thought'),
        'Extension thought',
      );
    });
  });
}
