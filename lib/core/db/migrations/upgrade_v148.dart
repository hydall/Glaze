part of '../app_db.dart';

extension _AppDatabaseUpgradeV148 on AppDatabase {
  Future<void> _upgradeV148(Migrator m, int from) async {
    if (from >= 148) return;

    // The agents system: library, per-character/chat bindings, run log.
    // Guarded so a restored database that already has them still upgrades.
    final tables = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    ).get();
    final names = tables.map((row) => row.read<String>('name')).toSet();
    if (!names.contains('agent_definitions')) {
      await m.createTable(agentDefinitionRows);
    }
    if (!names.contains('agent_bindings')) {
      await m.createTable(agentBindingRows);
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_agent_bindings_target '
        'ON agent_bindings (scope, target_id)',
      );
    }
    if (!names.contains('agent_runs')) {
      await m.createTable(agentRunRows);
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_agent_runs_session '
        'ON agent_runs (session_id, created_at)',
      );
    }
  }
}
