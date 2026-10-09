// The output-token cap warning is stored per swipe (`swipesMeta[i]
// ['outputLimitHit']`) and drawn by the WebView from the message map. These
// cover the three hops: the writer stamps it, the mapper reads it off the
// visible variation, and a continuation replaces it with its own outcome.

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_message_mapper.dart';
import 'package:glaze_flutter/features/chat/services/continuation_message_merger.dart';
import 'package:glaze_flutter/features/chat/services/saved_message_writer.dart';

void main() {
  const ctx = ChatMessageMapperContext(isGenerating: false);
  const session = ChatSession(id: 's', characterId: 'c', sessionIndex: 0);

  test('the writer stamps the variation that hit the cap', () {
    final state = const SavedMessageWriter().writeAssistant(
      text: 'She opened her mouth to',
      reasoning: null,
      currentSession: session,
      isAborted: () => false,
      outputLimitHit: true,
    );
    final message = state.session!.messages.last;
    expect(message.swipesMeta.single['outputLimitHit'], isTrue);
    expect(ChatMessageMapper.toMap(message, ctx)['outputLimitHit'], isTrue);
  });

  test('a reply that ended on its own carries no flag', () {
    final state = const SavedMessageWriter().writeAssistant(
      text: 'Done.',
      reasoning: null,
      currentSession: session,
      isAborted: () => false,
    );
    final message = state.session!.messages.last;
    expect(message.swipesMeta.single.containsKey('outputLimitHit'), isFalse);
    expect(
      ChatMessageMapper.toMap(message, ctx).containsKey('outputLimitHit'),
      isFalse,
    );
  });

  test('the warning follows the visible swipe', () {
    const message = ChatMessage(
      id: 'a',
      role: 'assistant',
      content: 'two',
      swipes: ['one', 'two'],
      swipeId: 1,
      swipesMeta: [
        {'outputLimitHit': true},
        <String, dynamic>{},
      ],
    );
    expect(
      ChatMessageMapper.toMap(message, ctx).containsKey('outputLimitHit'),
      isFalse,
    );
    expect(
      ChatMessageMapper.toMap(
        message.copyWith(swipeId: 0, content: 'one'),
        ctx,
      )['outputLimitHit'],
      isTrue,
    );
  });

  test('a continuation that finishes clears the warning', () {
    const original = ChatMessage(
      id: 'a',
      role: 'assistant',
      content: 'She opened her mouth to',
      swipes: ['She opened her mouth to'],
      swipesMeta: [
        {'outputLimitHit': true},
      ],
    );
    const generated = ChatMessage(
      id: 'tmp',
      role: 'assistant',
      content: 'speak.',
      swipes: ['speak.'],
      swipesMeta: [<String, dynamic>{}],
    );
    final merged = mergeContinuationMessage(original, generated);
    expect(merged.swipesMeta.single.containsKey('outputLimitHit'), isFalse);
  });

  test('a continuation that is cut off again keeps it', () {
    const original = ChatMessage(
      id: 'a',
      role: 'assistant',
      content: 'Fine.',
      swipes: ['Fine.'],
      swipesMeta: [<String, dynamic>{}],
    );
    const generated = ChatMessage(
      id: 'tmp',
      role: 'assistant',
      content: 'And then she',
      swipes: ['And then she'],
      swipesMeta: [
        {'outputLimitHit': true},
      ],
    );
    final merged = mergeContinuationMessage(original, generated);
    expect(merged.swipesMeta.single['outputLimitHit'], isTrue);
  });
}
