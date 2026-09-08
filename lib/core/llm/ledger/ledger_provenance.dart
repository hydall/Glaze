/// Builds provenance strings for Studio Ledger tracker writes.
///
/// Shared by [LedgerOpApplier] (per-op provenance with evidence).
String buildLedgerProvenance({
  required String messageId,
  required int swipeId,
  required int agentSwipeId,
  String evidence = '',
}) {
  final parts = <String>[
    'source=studio_ledger',
    'message=$messageId',
    'swipe=$swipeId',
    'agentSwipe=$agentSwipeId',
  ];
  final trimmedEvidence = evidence.trim();
  if (trimmedEvidence.isNotEmpty) {
    parts.add(
      'evidence=${trimmedEvidence.substring(0, trimmedEvidence.length.clamp(0, 80))}',
    );
  }
  return parts.join('|');
}
