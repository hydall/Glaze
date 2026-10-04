import '../../models/agent_operation_record.dart';

/// Result of a single Studio Ledger run.
class LedgerRunResult {
  final String
  status; // 'ok' | 'skipped' | 'disabled' | 'timeout' | 'error' | 'aborted'
  final String? visibleLedger;
  final int opsApplied;
  final String? error;
  final int elapsedMs;
  final List<AgentOperationAttempt> attempts;
  final String? model;
  final bool repairAttempted;
  final int effectiveTimeoutMs;
  final int promptChars;
  final int responseChars;

  const LedgerRunResult({
    required this.status,
    this.visibleLedger,
    this.opsApplied = 0,
    this.error,
    this.elapsedMs = 0,
    this.attempts = const [],
    this.model,
    this.repairAttempted = false,
    this.effectiveTimeoutMs = 0,
    this.promptChars = 0,
    this.responseChars = 0,
  });

  static const LedgerRunResult disabled = LedgerRunResult(status: 'disabled');
  static const LedgerRunResult skipped = LedgerRunResult(status: 'skipped');
  static const LedgerRunResult aborted = LedgerRunResult(status: 'aborted');
}
