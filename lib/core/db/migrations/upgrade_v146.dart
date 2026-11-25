part of '../app_db.dart';

extension _AppDatabaseUpgradeV146 on AppDatabase {
  Future<void> _upgradeV146(Migrator m, int from) async {
    if (from >= 146) return;

    // Per-connection switch that lets the reply timeout replace the
    // transport's fixed network limit. Off for every existing connection.
    await _ensureApiConfigTimeoutOverrideColumn(m);
  }

  /// Guarded: the v136 rebuild adds it first on older databases, and a
  /// database restored from a backup can carry it while its user_version
  /// lags.
  Future<void> _ensureApiConfigTimeoutOverrideColumn(Migrator m) async {
    final columns = await customSelect(
      "PRAGMA table_info('api_configs')",
    ).get();
    final names = columns.map((column) => column.read<String>('name')).toSet();
    if (!names.contains('first_chunk_timeout_overrides_network')) {
      await m.addColumn(
        apiConfigs,
        apiConfigs.firstChunkTimeoutOverridesNetwork,
      );
    }
  }
}
