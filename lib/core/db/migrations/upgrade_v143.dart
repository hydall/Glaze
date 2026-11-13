part of '../app_db.dart';

extension _AppDatabaseUpgradeV143 on AppDatabase {
  Future<void> _upgradeV143(Migrator m, int from) async {
    if (from >= 143) return;

    // The chat summary as a chain of blocks. Null leaves an existing summary
    // readable as one note.
    await _ensureChatSummaryBlocksColumn(m);
  }

  /// Guarded like v142: a restored backup can carry the column while its
  /// user_version lags.
  Future<void> _ensureChatSummaryBlocksColumn(Migrator m) async {
    final columns = await customSelect(
      "PRAGMA table_info('chat_summaries')",
    ).get();
    final names = columns.map((column) => column.read<String>('name')).toSet();
    if (!names.contains(chatSummaries.blocksJson.name)) {
      await m.addColumn(chatSummaries, chatSummaries.blocksJson);
    }
  }
}
