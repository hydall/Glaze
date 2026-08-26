import '../../db/repositories/ledger_debug_run_repo.dart';
import '../aux_retry_runner.dart';
import '../studio_ledger_export_parser.dart';
import '../transport/llm_call_event.dart';
import 'ledger_run_result.dart';

class LedgerRunDiagnostics {
  const LedgerRunDiagnostics(this._debugRunRepo);

  final LedgerDebugRunRepo _debugRunRepo;

  Future<void> recordDebugRun(
    LedgerRunTrace trace,
    LedgerRunResult result,
  ) async {
    if (!trace.reachedModel) return;
    await _debugRunRepo.record(
      LedgerDebugRun(
        sessionId: trace.sessionId,
        kind: trace.kind,
        status: result.status,
        messageId: trace.messageId,
        swipeId: trace.swipeId,
        agentSwipeId: trace.agentSwipeId,
        model: result.model ?? trace.model,
        parseFailure: trace.parseFailure,
        rejectionReason: trace.rejectionReason,
        rejectedOps: trace.rejectedOps,
        repairAttempted: trace.repairAttempted || result.repairAttempted,
        repairFailure: trace.repairFailure,
        responseText: trace.responseText,
        repairResponseText: trace.repairResponseText,
        attempts: result.attempts,
        error: result.error,
        opsApplied: result.opsApplied,
        elapsedMs: result.elapsedMs,
        promptChars: result.promptChars,
        responseChars: result.responseChars,
      ),
    );
  }

  Future<void> recordLedgerParserVerdict(
    AuxCallOutcome outcome,
    LedgerParseResult parsed,
  ) {
    final context = outcome.selectedCaptureContext;
    if (context == null) return Future<void>.value();
    return LlmCallEventCapture.record(
      LlmCallEvent.parserVerdict(
        context: context,
        parserName: 'StudioLedgerExportParser',
        accepted: parsed.export != null && !parsed.wasRejected,
        code: parsed.failure.name,
        detail: parsed.rejectionReason,
        payload: {
          'rejectedOps': parsed.rejectedOps,
          'hasExport': parsed.hasExport,
        },
      ),
    );
  }
}

class LedgerRunTrace {
  LedgerRunTrace({
    required this.sessionId,
    required this.kind,
    required this.messageId,
    required this.swipeId,
    required this.agentSwipeId,
  });

  final String sessionId;
  final LedgerDebugRunKind kind;
  final String messageId;
  final int swipeId;
  final int agentSwipeId;

  bool reachedModel = false;
  String model = '';
  String parseFailure = 'none';
  String? rejectionReason;
  List<String> rejectedOps = const [];
  bool repairAttempted = false;
  String? repairFailure;
  String? responseText;
  String? repairResponseText;

  void recordFirstResponse({
    required String model,
    required String responseText,
    required LedgerParseResult parsed,
  }) {
    reachedModel = true;
    this.model = model;
    this.responseText = responseText;
    parseFailure = parsed.failure.name;
    rejectionReason = parsed.rejectionReason;
    rejectedOps = parsed.rejectedOps;
  }

  void recordRepairRequested({required bool exportRepair}) {
    repairAttempted = true;
    if (!exportRepair) {
      repairFailure = 'cleanupBlockMissing';
    }
  }

  void recordRepairResponse({
    required String responseText,
    LedgerParseResult? parsed,
  }) {
    repairResponseText = responseText;
    if (parsed == null) return;
    repairFailure = parsed.failure.name;
    if (parsed.rejectedOps.isNotEmpty) rejectedOps = parsed.rejectedOps;
  }
}
