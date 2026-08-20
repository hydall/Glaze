import 'package:drift/drift.dart';

import '../../utils/time_helpers.dart';
import '../app_db.dart';

/// Owns immutable, hash-linked lorebook history inside canon checkpoints.
class SessionLorebookRevisionRepo {
  const SessionLorebookRevisionRepo(this.db);

  final AppDatabase db;

  Future<List<SessionLorebookRevisionRow>> getForSession(String sessionId) =>
      (db.select(db.sessionLorebookRevisionRows)
            ..where((row) => row.chatSessionId.equals(sessionId))
            ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
          .get();

  Future<SessionLorebookRevisionRow?> getLatestForTarget({
    required String sessionId,
    required String lorebookId,
    required String entryId,
  }) async {
    final history = db.sessionLorebookRevisionRows;
    final checkpoints = db.sessionCanonCheckpointRows;
    final query =
        db.select(history).join([
            innerJoin(
              checkpoints,
              checkpoints.id.equalsExp(history.checkpointId),
            ),
          ])
          ..where(
            history.chatSessionId.equals(sessionId) &
                history.lorebookId.equals(lorebookId) &
                history.entryId.equals(entryId),
          )
          ..orderBy([OrderingTerm.desc(checkpoints.sequence)])
          ..limit(1);
    final row = await query.getSingleOrNull();
    return row?.readTable(history);
  }

  Future<void> appendInTransaction({
    required String checkpointId,
    required String sessionId,
    required String lorebookId,
    required String entryId,
    required String baseContentHash,
    required String expectedPreviousContentHash,
    required String content,
    required String contentHash,
    required String rewriteOperationId,
  }) async {
    final checkpoint =
        await (db.select(db.sessionCanonCheckpointRows)..where(
              (row) =>
                  row.id.equals(checkpointId) &
                  row.chatSessionId.equals(sessionId),
            ))
            .getSingleOrNull();
    if (checkpoint == null) {
      throw StateError('Lorebook revision checkpoint does not exist.');
    }
    final latest = await getLatestForTarget(
      sessionId: sessionId,
      lorebookId: lorebookId,
      entryId: entryId,
    );
    if (latest != null && latest.contentHash != expectedPreviousContentHash) {
      throw StateError('Lorebook revision parent hash is stale.');
    }
    await db
        .into(db.sessionLorebookRevisionRows)
        .insert(
          SessionLorebookRevisionRowsCompanion.insert(
            checkpointId: checkpointId,
            chatSessionId: sessionId,
            lorebookId: lorebookId,
            entryId: entryId,
            baseContentHash: baseContentHash,
            previousContentHash: expectedPreviousContentHash,
            content: content,
            contentHash: contentHash,
            rewriteOperationId: rewriteOperationId,
            createdAt: currentTimestampSeconds(),
          ),
        );
  }
}
