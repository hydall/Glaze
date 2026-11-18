import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/agent_operation_record.dart';
import '../state/agent_operations_log_provider.dart';

/// Records memory agent operations in the agentic operations log.
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
}
