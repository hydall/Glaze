part of '../app_db.dart';

extension _AppDatabaseMemoryLegacyMigrations on AppDatabase {
  /// Removes retired agentic micro-memory after a schema upgrade or a restore.
  ///
  /// Backup and cloud imports can carry a pre-v66 `memory_book_rows` payload
  /// into an already-upgraded database, so this must remain callable after the
  /// one-time schema migration as well.
  Future<void> purgeRetiredAgenticMicroMemory() async {
    final rows = await customSelect(
      'SELECT session_id, entries_json, pending_drafts_json '
      'FROM memory_book_rows',
    ).get();
    for (final row in rows) {
      final removedIds = <String>{};

      List<dynamic>? filterAgentic(String raw, {required bool collectIds}) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! List) return null;
          return decoded.where((item) {
            if (item is! Map) return true;
            final isAgentic = item['source'] == 'agentic';
            if (isAgentic && collectIds) {
              final id = item['id'];
              if (id is String && id.isNotEmpty) removedIds.add(id);
            }
            return !isAgentic;
          }).toList();
        } catch (_) {
          return null;
        }
      }

      final entriesRaw = row.read<String>('entries_json');
      final draftsRaw = row.read<String>('pending_drafts_json');
      final entries = filterAgentic(entriesRaw, collectIds: true);
      final drafts = filterAgentic(draftsRaw, collectIds: false);
      if (entries != null || drafts != null) {
        await customStatement(
          'UPDATE memory_book_rows SET entries_json = ?, '
          'pending_drafts_json = ? WHERE session_id = ?',
          [
            entries == null ? entriesRaw : jsonEncode(entries),
            drafts == null ? draftsRaw : jsonEncode(drafts),
            row.read<String>('session_id'),
          ],
        );
      }

      for (final entryId in removedIds) {
        await customStatement('DELETE FROM embeddings WHERE entry_id = ?', [
          entryId,
        ]);
        await customStatement(
          'DELETE FROM memory_catalog_rows WHERE memory_entry_id = ?',
          [entryId],
        );
        await customStatement(
          'DELETE FROM memory_entity_rows WHERE memory_entry_id = ?',
          [entryId],
        );
        await customStatement(
          'DELETE FROM memory_salience_rows WHERE memory_entry_id = ?',
          [entryId],
        );
      }
    }
  }
}
