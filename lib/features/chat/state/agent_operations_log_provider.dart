import 'package:flutter_riverpod/legacy.dart';

import '../../../core/models/agent_operation_record.dart';

/// State held by [agentOperationsLogProvider]. Keeps a bounded ring buffer of
/// the most recent agentic operations so the user can inspect the log from a
/// dedicated UI screen.
class AgentOperationsLogState {
  /// Maximum number of records kept in-memory (older ones evicted FIFO).
  static const int maxRecords = 200;

  final List<AgentOperationRecord> records;

  const AgentOperationsLogState({this.records = const []});

  AgentOperationsLogState append(AgentOperationRecord record) {
    final next = [...records, record];
    if (next.length > maxRecords) {
      next.removeRange(0, next.length - maxRecords);
    }
    return AgentOperationsLogState(records: next);
  }

  AgentOperationsLogState clearForSession(String sessionId) {
    return AgentOperationsLogState(
      records: records.where((r) => r.sessionId != sessionId).toList(),
    );
  }

  /// Records filtered by session (null = all sessions).
  List<AgentOperationRecord> forSession(String? sessionId) {
    if (sessionId == null) return records;
    return records.where((r) => r.sessionId == sessionId).toList();
  }

  /// Failed records (any non-ok / non-disabled / non-aborted).
  List<AgentOperationRecord> get failures =>
      records.where((r) => r.status.isFailure).toList();
}

/// Global agentic operations log. Shared across all sessions — UI filters by
/// `sessionId` when needed. Writers append via `ref.read(...).notifier).state
/// = state.append(record)`.
final agentOperationsLogProvider =
    StateProvider<AgentOperationsLogState>((ref) {
  return const AgentOperationsLogState();
});
