import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/studio/studio_history_limiter.dart';
import 'package:glaze_flutter/core/llm/studio/studio_stream_interceptor.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

void main() {
  group('Studio history window rotation', () {
    test('does not rotate while the newest chunk has only a user message', () {
      final history = _alternatingPromptHistory(51);

      final plan = StudioHistoryLimiter.planCompletedWindow(
        history,
        maxMessages: 50,
      );

      expect(plan.didRotate, isFalse);
      expect(plan.messages, same(history));
    });

    test('does not rotate at the message limit', () {
      final history = _alternatingPromptHistory(50);

      final plan = StudioHistoryLimiter.planCompletedWindow(
        history,
        maxMessages: 50,
      );

      expect(plan.didRotate, isFalse);
      expect(plan.messages, hasLength(50));
    });

    test('drops roughly half only at a complete chunk boundary', () {
      final history = _alternatingPromptHistory(52);

      final plan = StudioHistoryLimiter.planCompletedWindow(
        history,
        maxMessages: 50,
      );

      expect(plan.didRotate, isTrue);
      expect(plan.droppedMessageCount, 26);
      expect(plan.messages, hasLength(26));
      expect(plan.messages.first.role, 'user');
      expect(plan.messages.first.sourceMessageId, 'm26');
      expect(plan.messages.last.role, 'assistant');
    });

    test('persisted boundary remains stable when the next user is added', () {
      final history = _alternatingChatHistory(53);

      final ids = StudioStreamInterceptor.computeStudioFinalVisibleMessageIds(
        history,
        50,
        historyWindowStartMessageId: 'm26',
      );

      expect(ids, hasLength(27));
      expect(ids, containsAll(['m26', 'm52']));
      expect(ids, isNot(contains('m25')));
    });

    test('token overflow rotates by complete chunks', () {
      final large = List.filled(20000, 'token').join(' ');
      final history = <PromptMessage>[
        PromptMessage(role: 'user', content: large, sourceMessageId: 'm0'),
        PromptMessage(role: 'assistant', content: large, sourceMessageId: 'm1'),
        PromptMessage(role: 'user', content: large, sourceMessageId: 'm2'),
        PromptMessage(role: 'assistant', content: large, sourceMessageId: 'm3'),
      ];

      final plan = StudioHistoryLimiter.planCompletedWindow(
        history,
        maxMessages: 0,
      );

      expect(plan.didRotate, isTrue);
      expect(plan.droppedMessageCount, 2);
      expect(plan.messages.map((message) => message.sourceMessageId), [
        'm2',
        'm3',
      ]);
    });

    test('reasoning can trigger rotation unless excluded from budget', () {
      final reasoning = List.filled(80000, 'thought').join(' ');
      final history = [
        const PromptMessage(
          role: 'user',
          content: 'one',
          sourceMessageId: 'm0',
        ),
        const PromptMessage(
          role: 'assistant',
          content: 'two',
          sourceMessageId: 'm1',
        ),
        const PromptMessage(
          role: 'user',
          content: 'three',
          sourceMessageId: 'm2',
        ),
        PromptMessage(
          role: 'assistant',
          content: 'four',
          reasoningContent: reasoning,
          sourceMessageId: 'm3',
        ),
      ];

      final included = StudioHistoryLimiter.planCompletedWindow(
        history,
        maxMessages: 50,
        reasoningHistoryCount: 1,
      );
      final excluded = StudioHistoryLimiter.planCompletedWindow(
        history,
        maxMessages: 50,
        reasoningHistoryCount: 1,
        excludeReasoningFromContextBudget: true,
      );

      expect(included.didRotate, isTrue);
      expect(excluded.didRotate, isFalse);
    });
  });
}

List<PromptMessage> _alternatingPromptHistory(int count) => List.generate(
  count,
  (index) => PromptMessage(
    role: index.isEven ? 'user' : 'assistant',
    content: 'message $index',
    sourceMessageId: 'm$index',
  ),
);

List<ChatMessage> _alternatingChatHistory(int count) => List.generate(
  count,
  (index) => ChatMessage(
    id: 'm$index',
    role: index.isEven ? 'user' : 'assistant',
    content: 'message $index',
  ),
);
