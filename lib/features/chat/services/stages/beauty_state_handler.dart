import '../../../../core/llm/beauty_state_parser.dart' show beautyStateVarKey;

/// Reads beauty styling state from session vars. Brief extraction (formerly
/// from the removed Beauty Shard agent's studioOutputs) no longer exists.
class BeautyStateHandler {
  /// Reads the current beauty state JSON from [sessionVars].
  ///
  /// Returns `null` when no beauty state has been stored yet.
  static String? extractBeautyState(Map<String, dynamic> sessionVars) {
    return sessionVars[beautyStateVarKey] as String?;
  }
}
