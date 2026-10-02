part of '../app_db.dart';

extension _AppDatabaseUpgradeV139 on AppDatabase {
  Future<void> _upgradeV139(Migrator m, int from) async {
    if (from >= 139) return;

    // NoAssistant mode for custom connections. Every column defaults to the
    // mode being off, so existing requests are unchanged.
    final columns = await customSelect(
      "PRAGMA table_info('api_configs')",
    ).get();
    final names = columns.map((column) => column.read<String>('name')).toSet();
    // Guarded like v137: a restored backup can carry the columns while its
    // user_version lags.
    for (final column in [
      apiConfigs.noAssistant,
      apiConfigs.noAssistantStopString,
      apiConfigs.noAssistantUserPrefix,
      apiConfigs.noAssistantCharPrefix,
      apiConfigs.noAssistantSquashRole,
    ]) {
      if (!names.contains(column.name)) {
        await m.addColumn(apiConfigs, column);
      }
    }
  }
}
