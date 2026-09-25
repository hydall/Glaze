part of '../app_db.dart';

extension _AppDatabaseUpgradeV136 on AppDatabase {
  Future<void> _upgradeV136(Migrator m, int from) async {
    if (from >= 136) return;

    // The connection defaults moved to the new "standard": a 1500-token cap,
    // provider-neutral sampling (temperature/top_p 1.0), and the sampling omit
    // flags on. SQLite cannot change a column default in place, so rebuild the
    // table to adopt them. Existing rows keep their stored values — only
    // inserts that leave a column out pick up the new defaults.
    await m.alterTable(TableMigration(apiConfigs));
  }
}
