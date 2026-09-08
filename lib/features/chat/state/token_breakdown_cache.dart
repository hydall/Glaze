import '../../../core/llm/context_calculator.dart';

/// Hash-based cache for TokenBreakdown results.
/// Lives outside Riverpod to avoid reactive overhead (mirrors JS plain variable).
class TokenBreakdownCache {
  static String? _hash;
  static TokenBreakdown? _breakdown;

  /// Compute cache key from all factors that affect token breakdown.
  static String computeHash({
    required String charId,
    required String sessionId,
    required int messageCount,
    required int contextSize,
    required int maxTokens,
    required String authorsNote,
    required String summary,
  }) =>
      '${charId}_${sessionId}_${messageCount}_${contextSize}_${maxTokens}_${authorsNote}_$summary';

  /// Get cached breakdown if hash matches, otherwise null.
  static TokenBreakdown? get(String hash) =>
      _hash == hash ? _breakdown : null;

  /// Store breakdown with its hash.
  static void set(String hash, TokenBreakdown breakdown) {
    _hash = hash;
    _breakdown = breakdown;
  }

  /// Clear cache (called on session/preset/persona changes).
  static void invalidate() {
    _hash = null;
    _breakdown = null;
  }
}
