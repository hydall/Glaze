import '../models/memory_book.dart';
import 'tokenizer.dart';

/// Token-budget guard for memory injection (INV-PS4).
///
/// `MemoryInjectionService.buildInjection()` uses [maxInjectionTokens]
/// to cap the per-call cost of injected memory entries: once the
/// running total of `estimateTokens(entry.content)` exceeds the cap,
/// the tail of the (already score-sorted) entry list is dropped.
///
/// See `docs/INVARIANTS.md` §5.4 for the formula and rationale.
class MemoryInjectionBudget {
  const MemoryInjectionBudget._();

  /// Returns the per-call memory-injection budget in tokens, or null
  /// when the guard should be skipped (no caller-supplied budget or a
  /// non-positive percentage).
  static int? maxInjectionTokens({
    required int? contextBudgetTokens,
    required double percent,
  }) {
    if (contextBudgetTokens == null || contextBudgetTokens <= 0) return null;
    if (percent <= 0) return null;
    return (contextBudgetTokens * percent).floor();
  }

  /// Compose the percent-derived budget with an optional absolute cap.
  ///
  /// Behaviour:
  /// - If both are set, the smaller wins: `min(percentBudget, maxInjectedTokens)`.
  /// - If only one is set, that one is returned.
  /// - If neither is set, returns null (caller treats as no cap).
  static int? composeBudget({
    required int? contextBudgetTokens,
    required double percent,
    required int? absoluteCap,
  }) {
    return describeBudget(
      contextBudgetTokens: contextBudgetTokens,
      percent: percent,
      absoluteCap: absoluteCap,
    ).effectiveTokens;
  }

  /// Describes how the effective memory budget was derived for diagnostics.
  static MemoryBudgetBreakdown describeBudget({
    required int? contextBudgetTokens,
    required double percent,
    required int? absoluteCap,
  }) {
    final percentBudget = maxInjectionTokens(
      contextBudgetTokens: contextBudgetTokens,
      percent: percent,
    );
    if (percentBudget == null && absoluteCap == null) {
      return const MemoryBudgetBreakdown(source: 'none');
    }
    if (percentBudget == null) {
      return MemoryBudgetBreakdown(
        effectiveTokens: absoluteCap,
        absoluteTokens: absoluteCap,
        source: 'absolute',
      );
    }
    if (absoluteCap == null) {
      return MemoryBudgetBreakdown(
        effectiveTokens: percentBudget,
        percentTokens: percentBudget,
        source: 'percent',
      );
    }
    final effective = percentBudget < absoluteCap ? percentBudget : absoluteCap;
    return MemoryBudgetBreakdown(
      effectiveTokens: effective,
      percentTokens: percentBudget,
      absoluteTokens: absoluteCap,
      source: effective == percentBudget ? 'percent_min' : 'absolute_min',
    );
  }

  /// Trims [entries] (already sorted by score, descending) so that the
  /// running total of `estimateTokens(entry.content)` does not exceed
  /// [budget]. Entries are removed from the tail (lowest score) first.
  /// If even the first entry exceeds the budget, an empty list is
  /// returned — the caller is expected to short-circuit on empty
  /// (INV-PS4: "do not skip entirely" means the first entry is always
  /// admitted; if it alone overflows, dropping it would leave the
  /// prompt with no memory at all, which is the worse failure mode).
  static List<MemoryEntry> trimByTokenBudget(
    List<MemoryEntry> entries,
    int budget,
  ) {
    var running = 0;
    final kept = <MemoryEntry>[];
    for (final entry in entries) {
      final cost = estimateTokens(entry.content);
      if (running + cost > budget && kept.isNotEmpty) break;
      kept.add(entry);
      running += cost;
    }
    return kept;
  }
}

class MemoryBudgetBreakdown {
  final int? effectiveTokens;
  final int? percentTokens;
  final int? absoluteTokens;
  final String source;

  const MemoryBudgetBreakdown({
    this.effectiveTokens,
    this.percentTokens,
    this.absoluteTokens,
    required this.source,
  });

  Map<String, dynamic> toJson() => {
    'effectiveTokens': effectiveTokens,
    'percentTokens': percentTokens,
    'absoluteTokens': absoluteTokens,
    'source': source,
  };
}
