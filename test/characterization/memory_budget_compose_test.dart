import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/memory_budget.dart';

void main() {
  group('MemoryInjectionBudget.composeBudget', () {
    test('returns null when both inputs are null/missing', () {
      expect(
        MemoryInjectionBudget.composeBudget(
          contextBudgetTokens: null,
          percent: 0.35,
          absoluteCap: null,
        ),
        isNull,
      );
    });

    test('returns absolute cap when percent budget is unavailable', () {
      expect(
        MemoryInjectionBudget.composeBudget(
          contextBudgetTokens: null,
          percent: 0.35,
          absoluteCap: 6000,
        ),
        6000,
      );
    });

    test('returns percent budget when absolute cap is null', () {
      expect(
        MemoryInjectionBudget.composeBudget(
          contextBudgetTokens: 32000,
          percent: 0.35,
          absoluteCap: null,
        ),
        11200,
      );
    });

    test('returns min(percentBudget, absoluteCap) when both set', () {
      // 32000 * 0.35 = 11200; cap 6000 -> 6000
      expect(
        MemoryInjectionBudget.composeBudget(
          contextBudgetTokens: 32000,
          percent: 0.35,
          absoluteCap: 6000,
        ),
        6000,
      );
    });

    test('returns percent budget when it is smaller than the cap', () {
      // 8000 * 0.35 = 2800; cap 6000 -> 2800
      expect(
        MemoryInjectionBudget.composeBudget(
          contextBudgetTokens: 8000,
          percent: 0.35,
          absoluteCap: 6000,
        ),
        2800,
      );
    });

    test('legacy behavior preserved when absolute cap unset', () {
      // No absolute cap -> same as before this refactor.
      expect(
        MemoryInjectionBudget.composeBudget(
          contextBudgetTokens: 100000,
          percent: 0.35,
          absoluteCap: null,
        ),
        35000,
      );
    });
  });
}
