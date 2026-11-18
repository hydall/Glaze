import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../models/agent_run.dart';

/// The agent run log (`agent_runs`). Display and debugging only.
class AgentRunRepo {
  final AppDatabase _db;
  const AgentRunRepo(this._db);

  /// Rows kept per chat; older ones are trimmed on insert.
  static const keepPerSession = 300;

  Future<void> insert(AgentRun run) async {
    await _db
        .into(_db.agentRunRows)
        .insert(
          AgentRunRowsCompanion.insert(
            sessionId: run.sessionId,
            messageId: Value(run.messageId),
            agentId: run.agentId,
            agentName: Value(run.agentName),
            phase: run.phase,
            resultType: run.resultType,
            ok: Value(run.ok),
            error: Value(run.error),
            output: Value(run.output),
            promptJson: Value(run.promptJson),
            promptTokens: Value(run.promptTokens),
            completionTokens: Value(run.completionTokens),
            durationMs: Value(run.durationMs),
            createdAt: Value(run.createdAt),
          ),
        );
    await _db.customStatement(
      'DELETE FROM agent_runs WHERE session_id = ? AND id NOT IN '
      '(SELECT id FROM agent_runs WHERE session_id = ? '
      'ORDER BY created_at DESC, id DESC LIMIT ?)',
      [run.sessionId, run.sessionId, keepPerSession],
    );
  }

  /// Newest first.
  Future<List<AgentRun>> forSession(String sessionId, {int limit = 100}) async {
    final rows =
        await (_db.select(_db.agentRunRows)
              ..where((row) => row.sessionId.equals(sessionId))
              ..orderBy([
                (row) => OrderingTerm.desc(row.createdAt),
                (row) => OrderingTerm.desc(row.id),
              ])
              ..limit(limit))
            .get();
    return [for (final row in rows) _toModel(row)];
  }

  Stream<List<AgentRun>> watchForSession(String sessionId, {int limit = 100}) =>
      (_db.select(_db.agentRunRows)
            ..where((row) => row.sessionId.equals(sessionId))
            ..orderBy([
              (row) => OrderingTerm.desc(row.createdAt),
              (row) => OrderingTerm.desc(row.id),
            ])
            ..limit(limit))
          .watch()
          .map((rows) => [for (final row in rows) _toModel(row)]);

  /// The latest successful output of each of [agentIds] in the chat, recorded
  /// for a message other than [excludingMessageId] — how a parallel agent's
  /// answer reaches the next turn.
  Future<Map<String, String>> latestOutputs(
    String sessionId,
    Iterable<String> agentIds, {
    String? excludingMessageId,
  }) async {
    final ids = agentIds.toSet();
    if (ids.isEmpty) return const {};
    final query = _db.select(_db.agentRunRows)
      ..where(
        (row) =>
            row.sessionId.equals(sessionId) &
            row.agentId.isIn(ids) &
            row.ok.equals(true),
      )
      ..orderBy([
        (row) => OrderingTerm.desc(row.createdAt),
        (row) => OrderingTerm.desc(row.id),
      ]);
    if (excludingMessageId != null && excludingMessageId.isNotEmpty) {
      query.where((row) => row.messageId.equals(excludingMessageId).not());
    }
    final result = <String, String>{};
    for (final row in await query.get()) {
      result.putIfAbsent(row.agentId, () => row.output);
      if (result.length == ids.length) break;
    }
    return result;
  }

  Future<void> deleteForSession(String sessionId) async {
    await (_db.delete(
      _db.agentRunRows,
    )..where((row) => row.sessionId.equals(sessionId))).go();
  }

  static AgentRun _toModel(AgentRunRow row) => AgentRun(
    id: row.id,
    sessionId: row.sessionId,
    messageId: row.messageId,
    agentId: row.agentId,
    agentName: row.agentName,
    phase: row.phase,
    resultType: row.resultType,
    ok: row.ok,
    error: row.error,
    output: row.output,
    promptJson: row.promptJson,
    promptTokens: row.promptTokens,
    completionTokens: row.completionTokens,
    durationMs: row.durationMs,
    createdAt: row.createdAt,
  );
}
