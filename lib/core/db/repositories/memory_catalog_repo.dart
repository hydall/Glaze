import 'package:drift/drift.dart';

import '../../llm/memory_catalog_builder.dart';
import '../../models/memory_book.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';

class MemoryCatalogRepo {
  final AppDatabase db;

  const MemoryCatalogRepo(this.db);

  Future<List<MemoryCatalogRow>> getBySessionId(String sessionId) {
    return (db.select(db.memoryCatalogRows)
          ..where((row) => row.chatSessionId.equals(sessionId))
          ..orderBy([(row) => OrderingTerm(expression: row.memoryEntryId)]))
        .get();
  }

  Future<void> deleteBySessionId(String sessionId) {
    return (db.delete(
      db.memoryCatalogRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
  }

  Future<void> updateAbstractText({
    required String sessionId,
    required String memoryEntryId,
    required String abstractText,
  }) {
    return (db.update(db.memoryCatalogRows)..where(
          (row) =>
              row.chatSessionId.equals(sessionId) &
              row.memoryEntryId.equals(memoryEntryId),
        ))
        .write(MemoryCatalogRowsCompanion(abstractText: Value(abstractText)));
  }

  Future<List<MemoryCatalogRow>> rebuildForMemoryBook(MemoryBook book) async {
    final now = currentTimestampSeconds();
    final rows = MemoryCatalogBuilder.build(book, nowSeconds: now);

    await db.transaction(() async {
      await deleteBySessionId(book.sessionId);
      for (final row in rows) {
        await db.into(db.memoryCatalogRows).insertOnConflictUpdate(row);
      }
    });

    return getBySessionId(book.sessionId);
  }
}
