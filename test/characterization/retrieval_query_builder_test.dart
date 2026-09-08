import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/retrieval_query_builder.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

ChatMessage _msg({
  required String id,
  required String role,
  required String content,
  bool hidden = false,
  bool typing = false,
}) =>
    ChatMessage(
      id: id,
      role: role,
      content: content,
      isHidden: hidden,
      isTyping: typing,
    );

void main() {
  group('RetrievalQueryBuilder.build', () {
    test('includes currentText first even if history is empty', () {
      final q = RetrievalQueryBuilder.build(
        currentText: 'Where is the bridge?',
        history: const [],
      );
      expect(q, 'Where is the bridge?');
    });

    test('includes last assistant turn after currentText', () {
      final history = [
        _msg(id: 'u1', role: 'user', content: 'first user message'),
        _msg(id: 'a1', role: 'assistant', content: 'first assistant reply'),
        _msg(id: 'u2', role: 'user', content: 'second user message'),
        _msg(id: 'a2', role: 'assistant', content: 'second assistant reply'),
      ];
      final q = RetrievalQueryBuilder.build(
        currentText: 'third user',
        history: history,
        includeAssistant: true,
        recentTurns: 6,
        maxChars: 5000,
      );
      expect(q.split('\n').first, 'third user');
      expect(q, contains('second assistant reply'));
      expect(q, contains('second user message'));
      // assistant should appear before earlier user messages in the walk
      final aIdx = q.indexOf('second assistant reply');
      final u2Idx = q.indexOf('second user message');
      expect(aIdx, lessThan(u2Idx));
    });

    test('skips hidden/typing/empty messages', () {
      final history = [
        _msg(id: 'h1', role: 'user', content: 'hidden', hidden: true),
        _msg(id: 't1', role: 'user', content: 'typing', typing: true),
        _msg(id: 'e1', role: 'user', content: ''),
        _msg(id: 'u1', role: 'user', content: 'real content'),
      ];
      final q = RetrievalQueryBuilder.build(
        currentText: 'now',
        history: history,
      );
      expect(q.split('\n'), ['now', 'real content']);
    });

    test('respects maxChars cap', () {
      final history = [
        _msg(id: 'u1', role: 'user', content: 'a' * 500),
        _msg(id: 'a1', role: 'assistant', content: 'b' * 500),
        _msg(id: 'u2', role: 'user', content: 'c' * 500),
      ];
      final q = RetrievalQueryBuilder.build(
        currentText: 'current' * 10,
        history: history,
        maxChars: 60,
        includeAssistant: true,
      );
      expect(q.length, lessThanOrEqualTo(60));
    });

    test('includeAssistant=false omits assistant turns', () {
      final history = [
        _msg(id: 'a1', role: 'assistant', content: 'reply1'),
        _msg(id: 'u1', role: 'user', content: 'user1'),
      ];
      final q = RetrievalQueryBuilder.build(
        currentText: 'now',
        history: history,
        includeAssistant: false,
        maxChars: 5000,
      );
      expect(q, isNot(contains('reply1')));
    });
  });
}
