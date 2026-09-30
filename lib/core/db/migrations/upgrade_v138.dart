part of '../app_db.dart';

extension _AppDatabaseUpgradeV138 on AppDatabase {
  Future<void> _upgradeV138(Migrator m, int from) async {
    if (from >= 138) return;

    // Generic folders for the list domains that did not have them (lorebooks,
    // personas, image styles, regex scripts). Brand-new tables, so nothing to
    // migrate: existing rows in the two legacy folder pairs stay where they
    // are.
    await m.createTable(folders);
    await m.createTable(folderMembers);
  }
}
