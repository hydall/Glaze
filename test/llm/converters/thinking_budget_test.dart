import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/converters/thinking_budget.dart';

void main() {
  group('calculateClaudeBudgetTokens (traditional)', () {
    test('auto → null', () {
      expect(
        calculateClaudeBudgetTokens(
          maxTokens: 4000,
          reasoningEffort: 'auto',
          stream: true,
          isAdaptiveModel: false,
        ),
        isNull,
      );
    });

    test('min → 1024', () {
      expect(
        calculateClaudeBudgetTokens(
          maxTokens: 4000,
          reasoningEffort: 'min',
          stream: true,
          isAdaptiveModel: false,
        ),
        1024,
      );
    });

    test('medium → floor(maxTokens * 0.25)', () {
      expect(
        calculateClaudeBudgetTokens(
          maxTokens: 20000,
          reasoningEffort: 'medium',
          stream: true,
          isAdaptiveModel: false,
        ),
        5000,
      );
    });

    test('low clamped up to 1024 floor', () {
      // low = 10% of 4000 = 400 → clamped to 1024.
      expect(
        calculateClaudeBudgetTokens(
          maxTokens: 4000,
          reasoningEffort: 'low',
          stream: true,
          isAdaptiveModel: false,
        ),
        1024,
      );
    });

    test('non-stream caps at 21333', () {
      // 0.5 * 100000 = 50000 → clamped to 21333.
      expect(
        calculateClaudeBudgetTokens(
          maxTokens: 100000,
          reasoningEffort: 'high',
          stream: false,
          isAdaptiveModel: false,
        ),
        21333,
      );
    });
  });

  group('calculateClaudeBudgetTokens (adaptive)', () {
    test('adaptive medium → "medium" string', () {
      expect(
        calculateClaudeBudgetTokens(
          maxTokens: 4000,
          reasoningEffort: 'medium',
          stream: true,
          isAdaptiveModel: true,
        ),
        'medium',
      );
    });

    test('adaptive auto → null', () {
      expect(
        calculateClaudeBudgetTokens(
          maxTokens: 4000,
          reasoningEffort: 'auto',
          stream: true,
          isAdaptiveModel: true,
        ),
        isNull,
      );
    });
  });

  group('calculateGoogleBudgetTokens', () {
    test('gemini-2.5-flash low → integer budget', () {
      final r = calculateGoogleBudgetTokens(
        maxTokens: 10000,
        reasoningEffort: 'low',
        model: 'gemini-2.5-flash',
      );
      expect(r, 1000);
    });

    test('gemini-2.5-flash min → 0', () {
      expect(
        calculateGoogleBudgetTokens(
          maxTokens: 10000,
          reasoningEffort: 'min',
          model: 'gemini-2.5-flash',
        ),
        0,
      );
    });

    test('gemini-2.5-pro min → 128', () {
      expect(
        calculateGoogleBudgetTokens(
          maxTokens: 10000,
          reasoningEffort: 'min',
          model: 'gemini-2.5-pro',
        ),
        128,
      );
    });

    test('gemini-3-pro medium → "low" symbolic', () {
      expect(
        calculateGoogleBudgetTokens(
          maxTokens: 10000,
          reasoningEffort: 'medium',
          model: 'gemini-3-pro',
        ),
        'low',
      );
    });

    test('gemini-3-flash medium → "medium" symbolic', () {
      expect(
        calculateGoogleBudgetTokens(
          maxTokens: 10000,
          reasoningEffort: 'medium',
          model: 'gemini-3-flash',
        ),
        'medium',
      );
    });

    test('unknown model → null', () {
      expect(
        calculateGoogleBudgetTokens(
          maxTokens: 10000,
          reasoningEffort: 'medium',
          model: 'some-other-model',
        ),
        isNull,
      );
    });
  });

  group('isAdaptiveClaudeModel', () {
    test('Opus 4.6+ is adaptive', () {
      expect(isAdaptiveClaudeModel('claude-opus-4-6'), isTrue);
      expect(isAdaptiveClaudeModel('claude-opus-4-7'), isTrue);
      expect(isAdaptiveClaudeModel('claude-opus-5'), isTrue);
    });

    test('older claude is not adaptive', () {
      expect(isAdaptiveClaudeModel('claude-3-5-sonnet'), isFalse);
      expect(isAdaptiveClaudeModel('claude-opus-3'), isFalse);
    });
  });
}
