import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../models/agent_definition.dart';

/// The agent library (`agent_definitions`).
class AgentRepo {
  final AppDatabase _db;
  const AgentRepo(this._db);

  /// Every agent, in library order. A row that no longer decodes is skipped
  /// rather than failing the whole library.
  Future<List<AgentDefinition>> getAll() async {
    final rows =
        await (_db.select(_db.agentDefinitionRows)..orderBy([
              (row) => OrderingTerm.asc(row.sortOrder),
              (row) => OrderingTerm.asc(row.agentId),
            ]))
            .get();
    final agents = <AgentDefinition>[];
    for (final row in rows) {
      final agent = decode(row.dataJson);
      if (agent != null) agents.add(agent);
    }
    return agents;
  }

  Future<AgentDefinition?> getById(String id) async {
    final row = await (_db.select(
      _db.agentDefinitionRows,
    )..where((row) => row.agentId.equals(id))).getSingleOrNull();
    return row == null ? null : decode(row.dataJson);
  }

  Future<void> put(AgentDefinition agent) async {
    await _db
        .into(_db.agentDefinitionRows)
        .insertOnConflictUpdate(
          AgentDefinitionRowsCompanion(
            agentId: Value(agent.id),
            dataJson: Value(jsonEncode(agent.toJson())),
            sortOrder: Value(agent.order),
            updatedAt: Value(agent.updatedAt),
          ),
        );
  }

  /// Deletes the agent and its bindings in one transaction.
  Future<void> delete(String id) async {
    await _db.transaction(() async {
      await (_db.delete(
        _db.agentDefinitionRows,
      )..where((row) => row.agentId.equals(id))).go();
      await (_db.delete(
        _db.agentBindingRows,
      )..where((row) => row.agentId.equals(id))).go();
    });
  }

  static AgentDefinition? decode(String raw) {
    try {
      return AgentDefinition.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }
}
