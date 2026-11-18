part of '../app_db.dart';

extension _AppDatabaseUpgradeV147 on AppDatabase {
  Future<void> _upgradeV147(Migrator m, int from) async {
    if (from >= 147) return;

    // Studio is removed. Its per-chat switches and agentic presets go with it,
    // as do folder memberships that pointed at those presets. Earlier steps no
    // longer create or alter these tables, so they may already be missing.
    await customStatement('DROP TABLE IF EXISTS studio_config_rows');
    await customStatement('DROP TABLE IF EXISTS studio_preset_rows');
    await customStatement(
      "DELETE FROM preset_folder_members WHERE kind = 'agentic'",
    );
  }
}
