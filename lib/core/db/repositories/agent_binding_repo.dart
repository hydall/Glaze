import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../models/agent_binding.dart';

/// Per-character and per-chat agent switches (`agent_bindings`).
class AgentBindingRepo {
  final AppDatabase _db;
  const AgentBindingRepo(this._db);

  Future<List<AgentBinding>> getAll() async {
    final rows = await _db.select(_db.agentBindingRows).get();
    return [for (final row in rows) _toModel(row)];
  }

  Stream<List<AgentBinding>> watchAll() => _db
      .select(_db.agentBindingRows)
      .watch()
      .map((rows) => [for (final row in rows) _toModel(row)]);

  /// Sets the switch of [agentId] for one character or chat; null removes it,
  /// so the next less specific level decides again.
  Future<void> set({
    required String agentId,
    required String scope,
    required String targetId,
    required bool? enabled,
  }) async {
    if (enabled == null) {
      await (_db.delete(_db.agentBindingRows)..where(
            (row) =>
                row.agentId.equals(agentId) &
                row.scope.equals(scope) &
                row.targetId.equals(targetId),
          ))
          .go();
      return;
    }
    await _db
        .into(_db.agentBindingRows)
        .insertOnConflictUpdate(
          AgentBindingRowsCompanion(
            agentId: Value(agentId),
            scope: Value(scope),
            targetId: Value(targetId),
            enabled: Value(enabled),
          ),
        );
  }

  /// Drops every binding that points at [targetId] in [scope] — when the chat
  /// or character goes away.
  Future<void> deleteForTarget(String scope, String targetId) async {
    await (_db.delete(_db.agentBindingRows)..where(
          (row) => row.scope.equals(scope) & row.targetId.equals(targetId),
        ))
        .go();
  }

  static AgentBinding _toModel(AgentBindingRow row) => AgentBinding(
    agentId: row.agentId,
    scope: row.scope,
    targetId: row.targetId,
    enabled: row.enabled,
  );
}
