part of '../app_db.dart';

extension _AppDatabaseUpgradeV142 on AppDatabase {
  Future<void> _upgradeV142(Migrator m, int from) async {
    if (from >= 142) return;

    // Character appearance blurb, sent as a text description when the active
    // image model does not accept reference images.
    await _ensureCharacterAppearanceColumn(m);
  }

  /// Guarded like v139: a restored backup can carry the column while its
  /// user_version lags.
  Future<void> _ensureCharacterAppearanceColumn(Migrator m) async {
    final columns = await customSelect(
      "PRAGMA table_info('characters')",
    ).get();
    final names = columns.map((column) => column.read<String>('name')).toSet();
    if (!names.contains(characters.appearance.name)) {
      await m.addColumn(characters, characters.appearance);
    }
  }
}
