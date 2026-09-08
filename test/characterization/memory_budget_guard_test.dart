import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/memory_budget.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';

/// Characterization test for INV-PS4: memory injection is guarded by a
/// token budget. The cap is configured per
/// [MemoryBookSettings.maxInjectionBudgetPercent] (default 0.35).
///
/// Formula (see docs/INVARIANTS.md §5.4):
///
/// ```
/// maxInjectionTokens = max(0, contextBudgetTokens) * percent
/// ```
///
/// Entries are kept in score-descending order; once the running total
/// of `estimateTokens(entry.content)` exceeds the cap, the tail of the
/// list is dropped. If even the first entry exceeds the budget on its
/// own, the list is still allowed to keep it (INV-PS4: "do not skip
/// entirely") and the caller short-circuits on the empty-result case.
void main() {
  group('MemoryInjectionBudget.maxInjectionTokens', () {
    test('returns null when contextBudgetTokens is null', () {
      expect(
        MemoryInjectionBudget.maxInjectionTokens(
          contextBudgetTokens: null,
          percent: 0.35,
        ),
        isNull,
      );
    });

    test('returns null when contextBudgetTokens is zero', () {
      expect(
        MemoryInjectionBudget.maxInjectionTokens(
          contextBudgetTokens: 0,
          percent: 0.35,
        ),
        isNull,
      );
    });

    test('returns null when contextBudgetTokens is negative', () {
      expect(
        MemoryInjectionBudget.maxInjectionTokens(
          contextBudgetTokens: -100,
          percent: 0.35,
        ),
        isNull,
      );
    });

    test('returns null when percent is zero (disabled)', () {
      expect(
        MemoryInjectionBudget.maxInjectionTokens(
          contextBudgetTokens: 10000,
          percent: 0,
        ),
        isNull,
      );
    });

    test('returns null when percent is negative', () {
      expect(
        MemoryInjectionBudget.maxInjectionTokens(
          contextBudgetTokens: 10000,
          percent: -0.1,
        ),
        isNull,
      );
    });

    test('35% of 100000 = 35000 (default percentage)', () {
      expect(
        MemoryInjectionBudget.maxInjectionTokens(
          contextBudgetTokens: 100000,
          percent: 0.35,
        ),
        35000,
      );
    });

    test('35% of 32000 = 11200 (typical 32k context)', () {
      expect(
        MemoryInjectionBudget.maxInjectionTokens(
          contextBudgetTokens: 32000,
          percent: 0.35,
        ),
        11200,
      );
    });

    test('rounds down (floor) for fractional results', () {
      // 1000 * 0.35 = 350.0 exactly
      // 7 * 0.35 = 2.45 -> floor 2
      expect(
        MemoryInjectionBudget.maxInjectionTokens(
          contextBudgetTokens: 7,
          percent: 0.35,
        ),
        2,
      );
    });
  });

  group('MemoryInjectionBudget.trimByTokenBudget', () {
    MemoryEntry entry(int id, String content) => MemoryEntry(
      id: 'e$id',
      title: 'Title $id',
      content: content,
      keys: const [],
      messageIds: const [],
      status: 'active',
      createdAt: 0,
    );

    test('empty input returns empty output', () {
      expect(
        MemoryInjectionBudget.trimByTokenBudget(<MemoryEntry>[], 1000),
        isEmpty,
      );
    });

    test('single small entry within budget is kept', () {
      final entries = [entry(1, 'a b c d e f g h i j')];
      final result = MemoryInjectionBudget.trimByTokenBudget(entries, 1000);
      expect(result, hasLength(1));
      expect(result.first.id, 'e1');
    });

    test('drops tail entries that would push total over budget', () {
      // Three roughly-equal entries at ~5 tokens each, budget = 12.
      // estimateTokens uses word count heuristic. 5-word strings ->
      // roughly 5 tokens. Two fit (10), the third would push to 15
      // which is > 12, so the third is dropped.
      final entries = [
        entry(1, 'one two three four five'),
        entry(2, 'six seven eight nine ten'),
        entry(3, 'eleven twelve thirteen fourteen fifteen'),
      ];
      final result = MemoryInjectionBudget.trimByTokenBudget(entries, 12);
      expect(result.length, lessThanOrEqualTo(2));
      // Kept entries are the highest-scored (head of list).
      expect(result.first.id, 'e1');
    });

    test('preserves order — keeps head, drops tail', () {
      final entries = List.generate(5, (i) => entry(i, 'x x x x x x x x'));
      final result = MemoryInjectionBudget.trimByTokenBudget(entries, 20);
      // All kept entries must come from the head of the input.
      final keptIds = result.map((e) => e.id).toList();
      for (var i = 0; i < keptIds.length; i++) {
        expect(keptIds[i], 'e$i');
      }
    });

    test('keeps first entry even if it alone exceeds budget', () {
      // INV-PS4: "do not skip entirely" — if the highest-scored entry
      // alone overflows the budget, we still keep it (and let the
      // caller decide). This is the less-bad failure mode vs. silently
      // dropping the most relevant memory.
      final entries = [
        entry(1, 'a ' * 200), // huge
        entry(2, 'tiny'),
      ];
      final result = MemoryInjectionBudget.trimByTokenBudget(entries, 10);
      expect(result, hasLength(1));
      expect(result.first.id, 'e1');
    });

    test('zero budget keeps only the first entry (inv-ps4 fallback)', () {
      final entries = [entry(1, 'alpha'), entry(2, 'beta')];
      final result = MemoryInjectionBudget.trimByTokenBudget(entries, 0);
      expect(result, hasLength(1));
      expect(result.first.id, 'e1');
    });
  });

  group('INV-PS4 default configuration', () {
    test('MemoryBookSettings.maxInjectionBudgetPercent defaults to 0.35', () {
      const settings = MemoryBookSettings();
      expect(settings.maxInjectionBudgetPercent, 0.35);
    });

    test(
      'MemoryBookSettings token budget defaults to auto percent-only mode',
      () {
        const settings = MemoryBookSettings();
        expect(settings.maxInjectedTokens, isNull);
        expect(settings.memoryBudgetPreset, 'auto');
      },
    );
  });

  group('composeBudget: percent + absolute cap interaction', () {
    test('min(percentBudget, absoluteCap) when both are set', () {
      // 32k * 0.35 = 11200; cap 6000 -> 6000
      expect(
        MemoryInjectionBudget.composeBudget(
          contextBudgetTokens: 32000,
          percent: 0.35,
          absoluteCap: 6000,
        ),
        6000,
      );
    });

    test('legacy: null absoluteCap returns percent budget only', () {
      expect(
        MemoryInjectionBudget.composeBudget(
          contextBudgetTokens: 32000,
          percent: 0.35,
          absoluteCap: null,
        ),
        11200,
      );
    });
  });
}
