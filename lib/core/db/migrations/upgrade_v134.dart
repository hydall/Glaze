part of '../app_db.dart';

extension _AppDatabaseUpgradeV134 on AppDatabase {
  Future<void> _upgradeV134(Migrator m, int from) async {
    if (from >= 134) return;

    // How a connection cuts history once it stops fitting — `sliding` (the old
    // and still default behaviour) or `stepped`. Existing rows take the column
    // default, so nothing changes for anyone who does not opt in.
    //
    // Guarded like the other column additions: a database restored from a
    // backup can already carry the column while its user_version lags behind.
    final columns = await customSelect(
      "PRAGMA table_info('api_configs')",
    ).get();
    final names = columns.map((column) => column.read<String>('name')).toSet();
    if (names.contains('history_trim_mode')) return;
    await m.addColumn(apiConfigs, apiConfigs.historyTrimMode);
  }
}
