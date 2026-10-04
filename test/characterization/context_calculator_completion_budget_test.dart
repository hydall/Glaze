import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/context_calculator.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';

/// Regression tests for the completion-budget reservation in
/// [ContextCalculator]. The provider enforces
/// `prompt_tokens + max_tokens <= contextSize`; the transport layer sends
/// `max_tokens` with every request. If the prompt is allowed to fill the whole
/// context window the model has no room to answer and returns an empty
/// completion. [ContextCalculator.safeContext] must therefore reserve
/// [maxTokens] before allocating the history budget.
void main() {
  PromptMessage userTurn(String id, String content) => PromptMessage(
    role: 'user',
    content: content,
    isHistory: true,
    sourceMessageId: id,
  );

  group('ContextCalculator completion-budget reservation', () {
    test('safeContext reserves maxTokens for the response', () {
      final calc = ContextCalculator(contextSize: 150000, maxTokens: 15000);
      expect(calc.safeContext, 135000);
    });

    test('historyBudget leaves room for the completion', () {
      final calc = ContextCalculator(contextSize: 1000, maxTokens: 400);
      final breakdown = calc.calculate(
        staticBlocks: const [],
        historyMessages: [userTurn('m1', 'hello there')],
      );
      // contextSize - maxTokens = 600, no static blocks => 600 budget.
      expect(breakdown.historyBudget, 600);
    });

    test('large memory does not starve the completion budget', () {
      final calc = ContextCalculator(contextSize: 1000, maxTokens: 400);
      // Memory eats most of the *prompt* window, but the 400-token completion
      // reservation is still honoured: historyBudget = 600 - 550 = 50, not
      // 1000 - 550 = 450.
      final breakdown = calc.calculate(
        staticBlocks: const [],
        historyMessages: [userTurn('m1', 'short turn')],
        memoryTokens: 550,
      );
      expect(breakdown.historyBudget, 50);
    });

    test(
      'misconfigured maxTokens >= contextSize clamps safeContext to zero',
      () {
        final calc = ContextCalculator(contextSize: 4000, maxTokens: 8000);
        expect(calc.safeContext, 0);
        final breakdown = calc.calculate(
          staticBlocks: const [],
          historyMessages: [userTurn('m1', 'will be dropped')],
        );
        expect(breakdown.historyBudget, 0);
        // History is fully cut off, but the calculator does not throw.
        expect(breakdown.cutoffIndex, 1);
        expect(breakdown.trimmedHistory, isEmpty);
      },
    );

    test('reasoning tokens reduce the retained history window', () {
      final messages = [
        userTurn('m1', 'older message'),
        const PromptMessage(
          role: 'assistant',
          content: 'recent reply',
          reasoningContent: 'one two three four five six seven eight nine ten',
          isHistory: true,
          sourceMessageId: 'm2',
        ),
      ];
      final contentOnly = ContextCalculator(
        contextSize: 20,
        maxTokens: 5,
      ).calculate(staticBlocks: const [], historyMessages: messages);
      final withReasoning = ContextCalculator(
        contextSize: 20,
        maxTokens: 5,
        reasoningHistoryCount: 1,
      ).calculate(staticBlocks: const [], historyMessages: messages);

      expect(contentOnly.trimmedHistory, hasLength(2));
      expect(withReasoning.trimmedHistory, hasLength(1));
      expect(withReasoning.trimmedHistory.single.sourceMessageId, 'm2');
      expect(
        withReasoning.historyTokens,
        greaterThan(contentOnly.historyTokens),
      );
    });

    test(
      'excludeReasoningFromContextBudget keeps reasoning without trimming',
      () {
        final messages = [
          userTurn('m1', 'older message'),
          const PromptMessage(
            role: 'assistant',
            content: 'recent reply',
            reasoningContent:
                'one two three four five six seven eight nine ten',
            isHistory: true,
            sourceMessageId: 'm2',
          ),
        ];
        // Without the flag, reasoning tokens eat budget and the older message
        // is trimmed (same as the test above).
        final withReasoning = ContextCalculator(
          contextSize: 20,
          maxTokens: 5,
          reasoningHistoryCount: 1,
        ).calculate(staticBlocks: const [], historyMessages: messages);
        expect(withReasoning.trimmedHistory, hasLength(1));

        // With the flag, reasoning tokens are excluded from the trim budget
        // so the older message is retained alongside the reasoning block.
        final excluded = ContextCalculator(
          contextSize: 20,
          maxTokens: 5,
          reasoningHistoryCount: 1,
          excludeReasoningFromContextBudget: true,
        ).calculate(staticBlocks: const [], historyMessages: messages);
        expect(excluded.trimmedHistory, hasLength(2));
        // historyTokens still includes reasoning for accurate reporting.
        expect(
          excluded.historyTokens,
          greaterThan(withReasoning.historyTokens),
        );
      },
    );
    test('minus one budgets every retained reasoning block', () {
      const messages = [
        PromptMessage(
          role: 'assistant',
          content: 'older reply',
          reasoningContent: 'older private reasoning',
          isHistory: true,
        ),
        PromptMessage(
          role: 'assistant',
          content: 'newer reply',
          reasoningContent: 'newer private reasoning',
          isHistory: true,
        ),
      ];
      final one = ContextCalculator(
        contextSize: 100,
        maxTokens: 10,
        reasoningHistoryCount: 1,
      ).calculate(staticBlocks: const [], historyMessages: messages);
      final all = ContextCalculator(
        contextSize: 100,
        maxTokens: 10,
        reasoningHistoryCount: -1,
      ).calculate(staticBlocks: const [], historyMessages: messages);

      expect(all.historyTokens, greaterThan(one.historyTokens));
      expect(all.totalTokens, all.historyTokens);
    });
  });
}
