import 'package:drift/drift.dart';

import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';

/// Owns durable post-commit indexing work. External API calls belong to a
/// worker, never to this repository or the surrounding apply transaction.
class SessionLorebookEmbeddingJobRepo {
  const SessionLorebookEmbeddingJobRepo(this.db);

  final AppDatabase db;

  Future<SessionLorebookEmbeddingJobRow> enqueueInTransaction({
    required String sessionId,
    required String checkpointId,
    required String lorebookId,
    required String entryId,
    required String expectedContentHash,
    String operation = 'reindex',
  }) async {
    if (operation != 'reindex' && operation != 'delete') {
      throw ArgumentError.value(operation, 'operation');
    }
    final now = currentTimestampSeconds();
    await (db.update(db.sessionLorebookEmbeddingJobRows)..where(
          (row) =>
              row.chatSessionId.equals(sessionId) &
              row.lorebookId.equals(lorebookId) &
              row.entryId.equals(entryId) &
              row.status.isIn(const ['pending', 'running']),
        ))
        .write(
          SessionLorebookEmbeddingJobRowsCompanion(
            status: const Value('superseded'),
            updatedAt: Value(now),
          ),
        );
    final id = 'lorebook-embedding-job-${generateId()}';
    await db
        .into(db.sessionLorebookEmbeddingJobRows)
        .insert(
          SessionLorebookEmbeddingJobRowsCompanion.insert(
            id: id,
            chatSessionId: sessionId,
            checkpointId: checkpointId,
            lorebookId: lorebookId,
            entryId: entryId,
            expectedContentHash: expectedContentHash,
            operation: operation,
            createdAt: now,
            updatedAt: now,
          ),
        );
    return (db.select(
      db.sessionLorebookEmbeddingJobRows,
    )..where((row) => row.id.equals(id))).getSingle();
  }

  Future<SessionLorebookEmbeddingJobRow?> claimNext() =>
      db.transaction(() async {
        final pending =
            await (db.select(db.sessionLorebookEmbeddingJobRows)
                  ..where((row) => row.status.equals('pending'))
                  ..orderBy([(row) => OrderingTerm.asc(row.createdAt)])
                  ..limit(1))
                .getSingleOrNull();
        if (pending == null) return null;
        final changed =
            await (db.update(db.sessionLorebookEmbeddingJobRows)..where(
                  (row) =>
                      row.id.equals(pending.id) & row.status.equals('pending'),
                ))
                .write(
                  SessionLorebookEmbeddingJobRowsCompanion(
                    status: const Value('running'),
                    attemptCount: Value(pending.attemptCount + 1),
                    lastError: const Value(null),
                    updatedAt: Value(currentTimestampSeconds()),
                  ),
                );
        if (changed != 1) return null;
        return (db.select(
          db.sessionLorebookEmbeddingJobRows,
        )..where((row) => row.id.equals(pending.id))).getSingle();
      });

  Future<int> recoverInterrupted() {
    final now = currentTimestampSeconds();
    return (db.update(
      db.sessionLorebookEmbeddingJobRows,
    )..where((row) => row.status.equals('running'))).write(
      SessionLorebookEmbeddingJobRowsCompanion(
        status: const Value('pending'),
        lastError: const Value('interrupted'),
        updatedAt: Value(now),
      ),
    );
  }

  Future<SessionLorebookEmbeddingJobRow?> getById(String id) => (db.select(
    db.sessionLorebookEmbeddingJobRows,
  )..where((row) => row.id.equals(id))).getSingleOrNull();

  Future<bool> supersede({
    required String id,
    required String expectedCheckpointId,
    required String expectedContentHash,
    String? reason,
  }) async {
    final changed =
        await (db.update(db.sessionLorebookEmbeddingJobRows)..where(
              (row) =>
                  row.id.equals(id) &
                  row.status.equals('running') &
                  row.checkpointId.equals(expectedCheckpointId) &
                  row.expectedContentHash.equals(expectedContentHash),
            ))
            .write(
              SessionLorebookEmbeddingJobRowsCompanion(
                status: const Value('superseded'),
                lastError: Value(reason),
                updatedAt: Value(currentTimestampSeconds()),
              ),
            );
    return changed == 1;
  }

  Future<bool> finish({
    required String id,
    required String expectedCheckpointId,
    required String expectedContentHash,
    required bool succeeded,
    String? error,
  }) async {
    final changed =
        await (db.update(db.sessionLorebookEmbeddingJobRows)..where(
              (row) =>
                  row.id.equals(id) &
                  row.status.equals('running') &
                  row.checkpointId.equals(expectedCheckpointId) &
                  row.expectedContentHash.equals(expectedContentHash),
            ))
            .write(
              SessionLorebookEmbeddingJobRowsCompanion(
                status: Value(succeeded ? 'succeeded' : 'failed'),
                lastError: Value(succeeded ? null : error),
                updatedAt: Value(currentTimestampSeconds()),
              ),
            );
    return changed == 1;
  }
}
