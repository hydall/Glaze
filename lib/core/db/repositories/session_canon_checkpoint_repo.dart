import 'package:drift/drift.dart';

import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';

final class SessionCanonCheckpointAnchor {
  const SessionCanonCheckpointAnchor({
    required this.messageId,
    required this.swipeId,
    required this.agentSwipeId,
  });

  final String messageId;
  final int swipeId;
  final int agentSwipeId;
}

/// Owns the append-only timeline that binds card and lorebook state together.
class SessionCanonCheckpointRepo {
  const SessionCanonCheckpointRepo(this.db);

  final AppDatabase db;

  Future<SessionCanonCheckpointRow?> getLatest(String sessionId) =>
      (db.select(db.sessionCanonCheckpointRows)
            ..where((row) => row.chatSessionId.equals(sessionId))
            ..orderBy([(row) => OrderingTerm.desc(row.sequence)])
            ..limit(1))
          .getSingleOrNull();

  Future<SessionCanonCheckpointRow?> getById(String id) => (db.select(
    db.sessionCanonCheckpointRows,
  )..where((row) => row.id.equals(id))).getSingleOrNull();

  Future<List<SessionCanonCheckpointRow>> getForSession(String sessionId) =>
      (db.select(db.sessionCanonCheckpointRows)
            ..where((row) => row.chatSessionId.equals(sessionId))
            ..orderBy([(row) => OrderingTerm.asc(row.sequence)]))
          .get();

  Future<SessionCanonCheckpointRow> appendRootInTransaction({
    required String sessionId,
    required String characterId,
    required int characterRevision,
    required String characterRevisionHash,
  }) async {
    final existing = await getLatest(sessionId);
    if (existing != null) return existing;
    return _append(
      sessionId: sessionId,
      sequence: 0,
      parentCheckpointId: '',
      characterId: characterId,
      characterRevision: characterRevision,
      characterRevisionHash: characterRevisionHash,
      rewriteJobId: null,
      anchor: const SessionCanonCheckpointAnchor(
        messageId: '',
        swipeId: 0,
        agentSwipeId: 0,
      ),
    );
  }

  Future<SessionCanonCheckpointRow> appendInTransaction({
    required String sessionId,
    required String expectedParentCheckpointId,
    required String characterId,
    required int characterRevision,
    required String characterRevisionHash,
    required String rewriteJobId,
    required SessionCanonCheckpointAnchor anchor,
  }) async {
    if (rewriteJobId.isEmpty || anchor.messageId.isEmpty) {
      throw ArgumentError('A rewrite checkpoint requires job and chat anchor.');
    }
    final parent = await getLatest(sessionId);
    if (parent == null || parent.id != expectedParentCheckpointId) {
      throw StateError('Session canon checkpoint parent is stale.');
    }
    return _append(
      sessionId: sessionId,
      sequence: parent.sequence + 1,
      parentCheckpointId: parent.id,
      characterId: characterId,
      characterRevision: characterRevision,
      characterRevisionHash: characterRevisionHash,
      rewriteJobId: rewriteJobId,
      anchor: anchor,
    );
  }

  Future<SessionCanonCheckpointRow> _append({
    required String sessionId,
    required int sequence,
    required String parentCheckpointId,
    required String characterId,
    required int characterRevision,
    required String characterRevisionHash,
    required String? rewriteJobId,
    required SessionCanonCheckpointAnchor anchor,
  }) async {
    final revision =
        await (db.select(db.characterRevisionRows)..where(
              (row) =>
                  row.characterId.equals(characterId) &
                  row.revision.equals(characterRevision) &
                  row.revisionHash.equals(characterRevisionHash),
            ))
            .getSingleOrNull();
    if (revision == null) {
      throw StateError('Checkpoint character revision does not exist.');
    }
    final id = 'canon-checkpoint-${generateId()}';
    await db
        .into(db.sessionCanonCheckpointRows)
        .insert(
          SessionCanonCheckpointRowsCompanion.insert(
            id: id,
            chatSessionId: sessionId,
            sequence: sequence,
            parentCheckpointId: Value(parentCheckpointId),
            characterId: characterId,
            characterRevision: characterRevision,
            characterRevisionHash: characterRevisionHash,
            rewriteJobId: Value(rewriteJobId),
            anchorMessageId: Value(anchor.messageId),
            anchorSwipeId: Value(anchor.swipeId),
            anchorAgentSwipeId: Value(anchor.agentSwipeId),
            createdAt: currentTimestampSeconds(),
          ),
        );
    return (db.select(
      db.sessionCanonCheckpointRows,
    )..where((row) => row.id.equals(id))).getSingle();
  }
}
