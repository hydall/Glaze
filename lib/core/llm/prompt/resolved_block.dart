class ResolvedDepthBlock {
  final String id;
  final String role;
  final String content;
  final int depth;
  final bool isSummary;
  const ResolvedDepthBlock({
    required this.id,
    required this.role,
    required this.content,
    required this.depth,
    this.isSummary = false,
  });
}

class ResolvedRelativeBlock {
  final String id;
  final String name;
  final String role;

  /// Fully expanded content — what the LLM sees. Used for `messages` and
  /// `appendedEntries` (which merge into the last user message).
  final String content;

  /// Accounting-only content with dynamic macro injections blanked out.
  /// Used for `attributionBlocks` and `mergeBuffer` so that the preset's
  /// "static chrome" tokens are not double-counted alongside the dedicated
  /// `sourceTokens['memory']` / `sourceTokens['summary']` etc. buckets.
  final String contentForAccounting;
  final bool isSummary;
  final bool appendToLastMessage;
  const ResolvedRelativeBlock({
    required this.id,
    required this.name,
    required this.role,
    required this.content,
    required this.contentForAccounting,
    this.isSummary = false,
    this.appendToLastMessage = false,
  });
}
