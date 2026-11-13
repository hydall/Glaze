part of '../app_db.dart';

extension _AppDatabaseUpgradeV144 on AppDatabase {
  Future<void> _upgradeV144(Migrator m, int from) async {
    if (from >= 144) return;

    // The summary block goes in place of the messages it covers by default
    // now. Only a block still on the old default (depth 4) moves; one the
    // reader placed otherwise keeps its placement.
    try {
      final rows = await customSelect(
        'SELECT preset_id, data_json FROM presets',
      ).get();
      for (final row in rows) {
        final presetId = row.read<String>('preset_id');
        final data = jsonDecode(row.read<String>('data_json'));
        if (data is! Map<String, dynamic>) continue;
        final blocks = data['blocks'];
        if (blocks is! List) continue;
        var changed = false;
        for (final block in blocks) {
          if (block is Map<String, dynamic> &&
              block['id'] == 'summary' &&
              block['insertionMode'] == 'depth' &&
              block['depth'] == 4) {
            block['insertionMode'] = 'in_place';
            changed = true;
          }
        }
        if (changed) {
          await customStatement(
            'UPDATE presets SET data_json = ? WHERE preset_id = ?',
            [jsonEncode(data), presetId],
          );
        }
      }
    } catch (e) {
      debugPrint('Migration 144 (summary block in place) failed: $e');
    }
  }
}
