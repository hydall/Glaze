import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/session_canon_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_lorebook_embedding_job_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_lorebook_revision_repo.dart';

void main() {
  late AppDatabase db;
  late SessionCanonCheckpointRepo checkpoints;
  late SessionLorebookRevisionRepo lorebookRevisions;
  late SessionLorebookEmbeddingJobRepo embeddingJobs;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    checkpoints = SessionCanonCheckpointRepo(db);
    lorebookRevisions = SessionLorebookRevisionRepo(db);
    embeddingJobs = SessionLorebookEmbeddingJobRepo(db);
    await db
        .into(db.characterRevisionRows)
        .insert(
          CharacterRevisionRowsCompanion.insert(
            characterId: 'character',
            revision: 1,
            revisionHash: 'card-hash-1',
            snapshotJson: '{}',
          ),
        );
  });

  tearDown(() async => db.close());

  test('checkpoint timeline is append-only and parent-CAS guarded', () async {
    final root = await checkpoints.appendRootInTransaction(
      sessionId: 'session',
      characterId: 'character',
      characterRevision: 1,
      characterRevisionHash: 'card-hash-1',
    );
    final next = await checkpoints.appendInTransaction(
      sessionId: 'session',
      expectedParentCheckpointId: root.id,
      characterId: 'character',
      characterRevision: 1,
      characterRevisionHash: 'card-hash-1',
      rewriteJobId: 'job-1',
      anchor: const SessionCanonCheckpointAnchor(
        messageId: 'message-1',
        swipeId: 2,
        agentSwipeId: 3,
      ),
    );

    expect(next.sequence, 1);
    expect(next.parentCheckpointId, root.id);
    await expectLater(
      checkpoints.appendInTransaction(
        sessionId: 'session',
        expectedParentCheckpointId: root.id,
        characterId: 'character',
        characterRevision: 1,
        characterRevisionHash: 'card-hash-1',
        rewriteJobId: 'job-stale',
        anchor: const SessionCanonCheckpointAnchor(
          messageId: 'message-2',
          swipeId: 0,
          agentSwipeId: 0,
        ),
      ),
      throwsStateError,
    );
    await expectLater(
      (db.update(db.sessionCanonCheckpointRows)
            ..where((row) => row.id.equals(next.id)))
          .write(const SessionCanonCheckpointRowsCompanion(sequence: Value(9))),
      throwsA(anything),
    );
  });

  test(
    'lorebook history follows checkpoint order and rejects stale hash',
    () async {
      final root = await checkpoints.appendRootInTransaction(
        sessionId: 'session',
        characterId: 'character',
        characterRevision: 1,
        characterRevisionHash: 'card-hash-1',
      );
      final first = await checkpoints.appendInTransaction(
        sessionId: 'session',
        expectedParentCheckpointId: root.id,
        characterId: 'character',
        characterRevision: 1,
        characterRevisionHash: 'card-hash-1',
        rewriteJobId: 'job-1',
        anchor: const SessionCanonCheckpointAnchor(
          messageId: 'message-1',
          swipeId: 0,
          agentSwipeId: 0,
        ),
      );
      await lorebookRevisions.appendInTransaction(
        checkpointId: first.id,
        sessionId: 'session',
        lorebookId: 'book',
        entryId: 'entry',
        baseContentHash: 'base-hash',
        expectedPreviousContentHash: 'base-hash',
        content: 'first',
        contentHash: 'first-hash',
        rewriteOperationId: 'operation-1',
      );
      final second = await checkpoints.appendInTransaction(
        sessionId: 'session',
        expectedParentCheckpointId: first.id,
        characterId: 'character',
        characterRevision: 1,
        characterRevisionHash: 'card-hash-1',
        rewriteJobId: 'job-2',
        anchor: const SessionCanonCheckpointAnchor(
          messageId: 'message-2',
          swipeId: 0,
          agentSwipeId: 0,
        ),
      );
      await lorebookRevisions.appendInTransaction(
        checkpointId: second.id,
        sessionId: 'session',
        lorebookId: 'book',
        entryId: 'entry',
        baseContentHash: 'base-hash',
        expectedPreviousContentHash: 'first-hash',
        content: 'second',
        contentHash: 'second-hash',
        rewriteOperationId: 'operation-2',
      );

      expect(
        (await lorebookRevisions.getLatestForTarget(
          sessionId: 'session',
          lorebookId: 'book',
          entryId: 'entry',
        ))?.content,
        'second',
      );
      await expectLater(
        lorebookRevisions.appendInTransaction(
          checkpointId: second.id,
          sessionId: 'session',
          lorebookId: 'book',
          entryId: 'entry',
          baseContentHash: 'base-hash',
          expectedPreviousContentHash: 'first-hash',
          content: 'stale',
          contentHash: 'stale-hash',
          rewriteOperationId: 'operation-stale',
        ),
        throwsStateError,
      );
    },
  );

  test('new embedding work supersedes older active work', () async {
    final root = await checkpoints.appendRootInTransaction(
      sessionId: 'session',
      characterId: 'character',
      characterRevision: 1,
      characterRevisionHash: 'card-hash-1',
    );
    final first = await embeddingJobs.enqueueInTransaction(
      sessionId: 'session',
      checkpointId: root.id,
      lorebookId: 'book',
      entryId: 'entry',
      expectedContentHash: 'hash-1',
    );
    final second = await embeddingJobs.enqueueInTransaction(
      sessionId: 'session',
      checkpointId: root.id,
      lorebookId: 'book',
      entryId: 'entry',
      expectedContentHash: 'hash-2',
    );

    final rows = await db.select(db.sessionLorebookEmbeddingJobRows).get();
    expect(rows.singleWhere((row) => row.id == first.id).status, 'superseded');
    expect(rows.singleWhere((row) => row.id == second.id).status, 'pending');
    final claimed = await embeddingJobs.claimNext();
    expect(claimed?.id, second.id);
    expect(claimed?.attemptCount, 1);
    expect(
      await embeddingJobs.finish(
        id: second.id,
        expectedCheckpointId: root.id,
        expectedContentHash: 'hash-2',
        succeeded: true,
      ),
      isTrue,
    );
  });
}
