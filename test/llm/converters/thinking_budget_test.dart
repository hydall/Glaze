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

    group('Gemini 3 levels follow what each model supports', () {
      Object? level(String model, String effort) => calculateGoogleBudgetTokens(
        maxTokens: 10000,
        reasoningEffort: effort,
        model: model,
      );

      test('3.1 Pro has medium, 3 Pro does not', () {
        expect(level('gemini-3.1-pro-preview', 'medium'), 'medium');
        expect(level('gemini-3-pro-preview', 'medium'), 'low');
        expect(level('gemini-3.1-pro-preview', 'min'), 'low');
        expect(level('gemini-3.1-pro-preview', 'max'), 'high');
      });

      test('3.7 and 3.8 Flash get low where minimal is rejected', () {
        expect(level('gemini-3.8-flash', 'min'), 'low');
        expect(level('gemini-3.7-flash', 'min'), 'low');
        expect(level('gemini-3.8-flash', 'medium'), 'medium');
      });

      test('the other Flash and Flash-Lite models keep minimal', () {
        for (final model in const [
          'gemini-3-flash-preview',
          'gemini-3.6-flash',
          'gemini-3.5-flash-lite',
          'gemini-3.1-flash-lite',
        ]) {
          expect(level(model, 'min'), 'minimal', reason: model);
        }
      });
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

    group('Gemini 4 takes levels, never a token budget', () {
      Object? level(String model, String effort) => calculateGoogleBudgetTokens(
        maxTokens: 30000,
        reasoningEffort: effort,
        model: model,
      );

      test('Carbon and Argon: low / medium / high, max capped at high', () {
        for (final model in const ['gemini-4-carbon', 'gemini-4-argon']) {
          expect(level(model, 'auto'), isNull, reason: model);
          expect(level(model, 'min'), 'low', reason: model);
          expect(level(model, 'low'), 'low', reason: model);
          expect(level(model, 'medium'), 'medium', reason: model);
          expect(level(model, 'high'), 'high', reason: model);
          expect(level(model, 'max'), 'high', reason: model);
        }
      });

      test('Hydrogen alone reaches xhigh', () {
        expect(level('gemini-4-hydrogen', 'high'), 'high');
        expect(level('gemini-4-hydrogen', 'max'), 'xhigh');
      });

      test('a Gemini 4 name with flash or pro in it still gets a level', () {
        expect(level('gemini-4-flash', 'medium'), 'medium');
        expect(level('gemini-4.5-pro', 'low'), 'low');
      });

      test('a proxy prefix does not hide the family', () {
        expect(isGemini4Model('google/gemini-4-carbon'), isTrue);
        expect(isGemini4Model('gemini-3-pro'), isFalse);
        expect(isGemini4Model('gemini-2.5-flash'), isFalse);
      });
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
