import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/memory_studio_service.dart' show StudioPipelineResult;
import '../../../core/models/agent_operation_record.dart';
import '../state/agent_operations_log_provider.dart';

/// Records memory agent and Studio tracker operations in the agentic
/// operations log.
///
/// Extracted from `StreamGenerationService` — encapsulates the
/// `AgentOperationRecord` construction logic that was previously inlined
/// as private methods.
class MemoryAgentRecorder {
  final Ref _ref;

  MemoryAgentRecorder(this._ref);

  /// Records memory agent operations in the agentic operations log.
  ///
  /// Agentic search (searchMemory tool) operation.
  void recordMemoryAgentOperation(
    String sessionId,
    String? messageId,
    Map<String, dynamic> diagnostics,
  ) {
    final agenticStatus = diagnostics['agenticStatus'] as String?;
    if (agenticStatus != null &&
        agenticStatus != 'disabled' &&
        agenticStatus != 'aborted') {
      final rawAttempts = diagnostics['agenticAttempts'];
      if (rawAttempts is List) {
        final attempts = rawAttempts
            .whereType<Map<dynamic, dynamic>>()
            .map(
              (e) =>
                  AgentOperationAttempt.fromJson(Map<String, dynamic>.from(e)),
            )
            .toList();
        if (attempts.isNotEmpty) {
          final status = memoryAgentStatusToOp(agenticStatus);
          _appendOperation(
            AgentOperationRecord(
              id: 'agentic-search-$sessionId-${DateTime.now().microsecondsSinceEpoch}',
              kind: AgentOperationKind.agenticSearch,
              status: status,
              sessionId: sessionId,
              messageId: messageId,
              attempts: attempts,
              totalElapsedMs: attempts.fold(0, (sum, a) => sum + a.elapsedMs),
              summary: status == AgentOperationStatus.ok
                  ? 'agentic search'
                  : agenticStatus,
              startedAtMs: attempts.first.startedAtMs,
              finishedAtMs: attempts.last.startedAtMs + attempts.last.elapsedMs,
              canRegenerate: status.isFailure,
            ),
          );
        }
      }
    }
  }

  /// Records a Studio tracker-cycle operation in the agentic operations log.
  ///
  /// Studio differs from the other agentic ops in that the per-agent LLM
  /// attempts are not surfaced as a structured `attempts` array on the
  /// pipeline result — they are summarised as `stageBriefs` (one per tracker
  /// agent) plus an overall `status`. We synthesise a single aggregate
  /// `AgentOperationAttempt` covering the whole cycle elapsed time and put
  /// the per-agent breakdown into the `summary` text.
  ///
  /// Call sites:
  ///   - success path (`status == 'ok'`)
  ///   - hard failure (`status != 'ok' && status != 'aborted' &&
  ///     status != 'disabled'`)
  ///
  /// Aborted / disabled runs are not logged — they are user-initiated
  /// cancellations or no-op configurations, not real operations.
  void recordStudioTrackerOperation({
    required String sessionId,
    String? messageId,
    required DateTime startGenTime,
    DateTime? finalStartTime,
    required StudioPipelineResult result,
    required String trackerModel,
    required String finalModel,
  }) {
    final status = studioStatusToOp(result.status);
    if (status == AgentOperationStatus.aborted ||
        status == AgentOperationStatus.disabled) {
      return;
    }
    final now = DateTime.now();
    final elapsedMs = now.difference(startGenTime).inMilliseconds;
    final startedAtMs = startGenTime.millisecondsSinceEpoch;

    final briefs = result.stageBriefs;

    if (briefs.isEmpty) {
      _appendOperation(
        AgentOperationRecord(
          id: 'studio-tracker-$sessionId-${now.microsecondsSinceEpoch}',
          kind: AgentOperationKind.studioTracker,
          status: status,
          sessionId: sessionId,
          messageId: messageId,
          attempts: [
            AgentOperationAttempt(
              attempt: 1,
              statusCode: 0,
              status: status.label,
              error: status.isFailure ? (result.error ?? result.status) : null,
              startedAtMs: startedAtMs,
              elapsedMs: elapsedMs,
            ),
          ],
          totalElapsedMs: elapsedMs,
          model: trackerModel,
          summary: result.error ?? result.status,
          startedAtMs: startedAtMs,
          finishedAtMs: now.millisecondsSinceEpoch,
          canRegenerate: status.isFailure,
        ),
      );
      return;
    }

    for (var i = 0; i < briefs.length; i++) {
      final brief = briefs[i];
      final briefStatus = brief.status == 'ok'
          ? AgentOperationStatus.ok
          : AgentOperationStatus.error;
      final summary = brief.status == 'ok'
          ? '${brief.agentName} · ${brief.brief.length} chars'
          : '${brief.agentName} · ${brief.error ?? brief.status}';
      final idStamp = now.microsecondsSinceEpoch + i;
      final opStartedAt = startedAtMs + i;
      _appendOperation(
        AgentOperationRecord(
          id: 'studio-tracker-${brief.agentId}-$sessionId-$idStamp',
          kind: AgentOperationKind.studioTracker,
          status: briefStatus,
          sessionId: sessionId,
          messageId: messageId,
          attempts: [
            AgentOperationAttempt(
              attempt: 1,
              statusCode: 0,
              status: briefStatus.label,
              error: briefStatus.isFailure
                  ? (brief.error ?? brief.status)
                  : null,
              startedAtMs: opStartedAt,
              elapsedMs: elapsedMs,
            ),
          ],
          totalElapsedMs: elapsedMs,
          model: trackerModel,
          summary: summary,
          startedAtMs: opStartedAt,
          finishedAtMs: opStartedAt,
          canRegenerate: briefStatus.isFailure,
        ),
      );
    }

    final finalStartedAt =
        finalStartTime?.millisecondsSinceEpoch ?? startedAtMs + briefs.length;
    final finalElapsedMs = now.millisecondsSinceEpoch - finalStartedAt;
    _appendOperation(
      AgentOperationRecord(
        id: 'studio-final-$sessionId-${now.microsecondsSinceEpoch}',
        kind: AgentOperationKind.studioFinal,
        status: status,
        sessionId: sessionId,
        messageId: messageId,
        attempts: [
          AgentOperationAttempt(
            attempt: 1,
            statusCode: 0,
            status: status.label,
            error: status.isFailure ? (result.error ?? result.status) : null,
            startedAtMs: finalStartedAt,
            elapsedMs: finalElapsedMs < 0 ? elapsedMs : finalElapsedMs,
          ),
        ],
        totalElapsedMs: finalElapsedMs < 0 ? elapsedMs : finalElapsedMs,
        model: finalModel,
        summary: status.isOk
            ? 'final reply · ${result.response.length} chars'
            : result.error ?? result.status,
        startedAtMs: finalStartedAt,
        finishedAtMs: now.millisecondsSinceEpoch,
        canRegenerate: status.isFailure,
      ),
    );
  }

  void _appendOperation(AgentOperationRecord record) {
    _ref.read(agentOperationsLogProvider.notifier).state = _ref
        .read(agentOperationsLogProvider)
        .append(record);
  }

  /// Maps a memory agent status string to an [AgentOperationStatus].
  static AgentOperationStatus memoryAgentStatusToOp(String status) {
    return switch (status) {
      'ok' => AgentOperationStatus.ok,
      'disabled' => AgentOperationStatus.disabled,
      'aborted' => AgentOperationStatus.aborted,
      'timeout' => AgentOperationStatus.timeout,
      'http_error' => AgentOperationStatus.httpError,
      'invalid_output' => AgentOperationStatus.invalidOutput,
      'error' => AgentOperationStatus.error,
      _ => AgentOperationStatus.error,
    };
  }

  /// Maps a Studio pipeline status string to an [AgentOperationStatus].
  static AgentOperationStatus studioStatusToOp(String status) {
    return switch (status) {
      'ok' => AgentOperationStatus.ok,
      'disabled' => AgentOperationStatus.disabled,
      'aborted' => AgentOperationStatus.aborted,
      'timeout' => AgentOperationStatus.timeout,
      'error' => AgentOperationStatus.error,
      'agent_errors' => AgentOperationStatus.error,
      _ => AgentOperationStatus.error,
    };
  }
}
