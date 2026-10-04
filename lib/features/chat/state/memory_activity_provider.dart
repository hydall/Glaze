import 'package:flutter_riverpod/legacy.dart';

class MemoryActivityState {
  final String sessionId;
  final String? messageId;
  final Map<String, dynamic> diagnostics;
  final int updatedAtMillis;

  const MemoryActivityState({
    required this.sessionId,
    this.messageId,
    required this.diagnostics,
    required this.updatedAtMillis,
  });

  bool get hasDiagnostics =>
      (diagnostics['totalCandidates'] as int? ?? 0) > 0 ||
      (diagnostics['selectedCount'] as int? ?? 0) > 0;
}

final lastMemoryActivityProvider =
    StateProvider.family<MemoryActivityState?, String>((ref, _) => null);

/// The handful of numbers the context card's header shows, read out of the raw
/// diagnostics map once so the card and the memory section cannot disagree
/// about which fallback key wins.
class MemoryActivitySummary {
  final int selectedCount;
  final int selectedTokens;
  final int totalCandidates;
  final int skippedCount;
  final int sourceVisibleCount;
  final int latencyMs;
  final bool macroMissing;

  const MemoryActivitySummary({
    required this.selectedCount,
    required this.selectedTokens,
    required this.totalCandidates,
    required this.skippedCount,
    required this.sourceVisibleCount,
    required this.latencyMs,
    required this.macroMissing,
  });

  factory MemoryActivitySummary.of(MemoryActivityState state) {
    final d = state.diagnostics;
    return MemoryActivitySummary(
      selectedCount: d['selectedCount'] as int? ?? 0,
      selectedTokens: d['selectedTokens'] as int? ?? 0,
      totalCandidates:
          d['eligibleCandidates'] as int? ?? d['totalCandidates'] as int? ?? 0,
      skippedCount:
          d['eligibleSkippedCount'] as int? ?? d['skippedCount'] as int? ?? 0,
      sourceVisibleCount: d['excludedBySourceWindow'] as int? ?? 0,
      latencyMs: d['latencyMs'] as int? ?? 0,
      macroMissing: d['memoryMacroMissing'] == true,
    );
  }
}
