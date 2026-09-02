part of '../app_db.dart';

extension _AppDatabaseUpgradeV133 on AppDatabase {
  Future<void> _upgradeV133(Migrator m, int from) async {
    if (from >= 133) return;

    // Embedding presets are rows of their own now, and each one names the LLM
    // preset it borrows an endpoint from while "use LLM API" is on. The rows
    // themselves are seeded from the old per-preset embedding settings by
    // `EmbeddingPresetListNotifier`, which also moves the stored selection with
    // them — this migration only opens the column.
    //
    // Guarded like the other column additions: a database restored from a
    // backup can already carry the column while its user_version lags behind.
    final columns = await customSelect(
      "PRAGMA table_info('api_configs')",
    ).get();
    final names = columns.map((column) => column.read<String>('name')).toSet();
    if (names.contains('embedding_llm_preset_id')) return;
    await m.addColumn(apiConfigs, apiConfigs.embeddingLlmPresetId);
  }
}
