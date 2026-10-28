part of '../app_db.dart';

extension _AppDatabaseUpgradeV145 on AppDatabase {
  Future<void> _upgradeV145(Migrator m, int from) async {
    if (from >= 145) return;

    // Per-connection tool calling: off, with no tool group disabled.
    await _ensureApiConfigToolCallingColumns(m);
  }

  /// Guarded: the v136 rebuild adds them first on older databases, and a
  /// database restored from a backup can carry them while its user_version
  /// lags.
  Future<void> _ensureApiConfigToolCallingColumns(Migrator m) async {
    final columns = await customSelect(
      "PRAGMA table_info('api_configs')",
    ).get();
    final names = columns.map((column) => column.read<String>('name')).toSet();
    if (!names.contains('tool_calling')) {
      await m.addColumn(apiConfigs, apiConfigs.toolCalling);
    }
    if (!names.contains('disabled_tool_groups_json')) {
      await m.addColumn(apiConfigs, apiConfigs.disabledToolGroupsJson);
    }
  }
}
