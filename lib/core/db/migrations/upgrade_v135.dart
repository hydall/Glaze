part of '../app_db.dart';

extension _AppDatabaseUpgradeV135 on AppDatabase {
  Future<void> _upgradeV135(Migrator m, int from) async {
    if (from >= 135) return;

    // The two knobs stepped trimming spends: when the held window has to move,
    // and how much budget the move gives back. Meaningless while the connection
    // is on `sliding`, so existing rows just take the defaults.
    //
    // Guarded per column: a database restored from a backup can already carry
    // them while its user_version lags behind.
    final columns = await customSelect(
      "PRAGMA table_info('api_configs')",
    ).get();
    final names = columns.map((column) => column.read<String>('name')).toSet();
    if (!names.contains('history_trim_trigger_percent')) {
      await m.addColumn(apiConfigs, apiConfigs.historyTrimTriggerPercent);
    }
    if (!names.contains('history_trim_step_percent')) {
      await m.addColumn(apiConfigs, apiConfigs.historyTrimStepPercent);
    }
  }
}
