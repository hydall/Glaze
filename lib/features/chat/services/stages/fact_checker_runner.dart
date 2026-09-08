import '../../../../core/models/agent_operation_record.dart';
import '../../state/agent_operations_log_provider.dart';
import 'stage_context.dart';

/// Records fact-checker (character/world auditor) operations into the
/// agentic operations log.
///
/// Extracted from `CleanerStage._recordFactCheckerOperation` so the recording
/// logic is testable in isolation and `CleanerStage` stays focused on
/// orchestration.
class FactCheckerRunner {
  final StageContext ctx;

  FactCheckerRunner(this.ctx);

  /// Records a fact-checker operation. [issues] is the audit result (`null`
  /// when the audit failed/timed out, `[]` when no contradictions found).
  /// [error] is set when the audit itself errored.
  void record({
    required String sessionId,
    required String messageId,
    required int startedAtMs,
    required List<String>? issues,
    String? error,
    String? model,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final status = error == null && issues != null
        ? AgentOperationStatus.ok
        : AgentOperationStatus.error;
    ctx.ref.read(agentOperationsLogProvider.notifier).state = ctx.ref
        .read(agentOperationsLogProvider)
        .append(
          AgentOperationRecord(
            id: 'fact-checker-$messageId-${DateTime.now().microsecondsSinceEpoch}',
            kind: AgentOperationKind.factChecker,
            status: status,
            sessionId: sessionId,
            messageId: messageId,
            attempts: [
              AgentOperationAttempt(
                attempt: 1,
                statusCode: 0,
                status: status.label,
                error: status.isFailure ? (error ?? 'audit failed') : null,
                startedAtMs: startedAtMs,
                elapsedMs: now - startedAtMs,
              ),
            ],
            totalElapsedMs: now - startedAtMs,
            model: model,
            summary: status.isOk
                ? 'issues=${issues?.length ?? 0}'
                : error ?? 'audit failed',
            startedAtMs: startedAtMs,
            finishedAtMs: now,
            canRegenerate: status.isFailure,
          ),
        );
  }
}
