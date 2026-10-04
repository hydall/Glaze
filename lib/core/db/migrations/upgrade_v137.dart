part of '../app_db.dart';

extension _AppDatabaseUpgradeV137 on AppDatabase {
  Future<void> _upgradeV137(Migrator m, int from) async {
    if (from >= 137) return;

    // Per-connection tokenizer choice. Existing rows take `auto`, which picks
    // the tokenizer from the model name.
    await _ensureApiConfigTokenizerColumn(m);
  }

  /// Guarded: the v136 rebuild adds it first on older databases, and a
  /// database restored from a backup can carry it while its user_version lags.
  Future<void> _ensureApiConfigTokenizerColumn(Migrator m) async {
    final columns = await customSelect(
      "PRAGMA table_info('api_configs')",
    ).get();
    final names = columns.map((column) => column.read<String>('name')).toSet();
    if (!names.contains('tokenizer')) {
      await m.addColumn(apiConfigs, apiConfigs.tokenizer);
    }
  }
}
