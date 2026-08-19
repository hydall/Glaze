import 'dart:convert';

import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

void main() {
  late AppDatabase db;
  late ManualRewriteJobRepo repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = ManualRewriteJobRepo(
      db: db,
      rawTrackerStateReader: LedgerRawTrackerStateReader(db),
    );
    await CharacterRepo(
      db,
    ).put(Character(id: 'c', name: 'Card', description: 'old text'));
  });
  tearDown(() => db.close());

  String snapshotFor({
    String anchor = 'old text',
    String value = 'new text',
    List<String> affected = const [],
  }) => jsonEncode({
    'field': 'description',
    'patches': [
      {
        'scopeKey': 'npc:alice',
        'anchor': anchor,
        'anchorSha256': CardCanonicalizer.scalarSha256(anchor),
        'value': value,
      },
    ],
    'transition': {
      'id': 'transition',
      'scopeKey': 'npc:alice',
      'canonicalClaim': value,
      'promotionDestination': 'card',
      'affectedTrackerKeys': affected,
      'factIds': <String>[],
      'chatSessionId': null,
    },
  });

  Future<String> createJob({String? requestKey}) async =>
      (await repo.createOrGet(
        requestKey: requestKey,
        chatSessionId: 's',
        characterId: 'c',
        requestJson: '{"instruction":"rewrite"}',
        canonStamp: 'stamp-1',
        basisRevision: 3,
        basisRevisionHash: 'basis-hash',
      )).job.id;

  Future<RewriteJobRow> job(String id) =>
      (db.select(db.rewriteJobs)..where((t) => t.id.equals(id))).getSingle();
  Future<RewriteOperationRow> operation(String id) => (db.select(
    db.rewriteOperations,
  )..where((t) => t.id.equals(id))).getSingle();

  test('constructing with a foreign raw tracker reader is rejected', () {
    final other = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(other.close);
    expect(
      () => ManualRewriteJobRepo(
        db: db,
        rawTrackerStateReader: LedgerRawTrackerStateReader(other),
      ),
      throwsArgumentError,
    );
  });

  test(
    'createOrGet is idempotent by request key and blocks a second active job',
    () async {
      final first = await repo.createOrGet(
        requestKey: 'rk',
        chatSessionId: 's',
        characterId: 'c',
        requestJson: '{"instruction":"rewrite"}',
        canonStamp: 'stamp-1',
        basisRevision: 3,
        basisRevisionHash: 'basis-hash',
      );
      expect(first.kind, 'created');
      expect(first.job.status, 'generating');
      expect(first.job.version, 1);
      expect(first.job.canonStamp, 'stamp-1');
      expect(first.job.basisRevision, 3);
      expect(first.job.basisRevisionHash, 'basis-hash');
      expect(first.job.requestKey, 'rk');
      expect(first.job.statusReason, isNull);

      final again = await repo.createOrGet(
        requestKey: 'rk',
        chatSessionId: 's',
        characterId: 'c',
        requestJson: '{"instruction":"other"}',
      );
      expect(again.kind, 'existing');
      expect(again.job.id, first.job.id);

      final conflict = await repo.createOrGet(
        requestKey: 'other-key',
        chatSessionId: 's',
        characterId: 'c',
        requestJson: '{}',
      );
      expect(conflict.kind, 'activeJobConflict');
      expect(conflict.job.id, first.job.id);
      expect(await db.select(db.rewriteJobs).get(), hasLength(1));

      // A terminal job does not block a new request for the pair.
      final cancelled = await repo.cancel(
        jobId: first.job.id,
        expectedVersion: 1,
      );
      expect(cancelled.kind, 'updated');
      final second = await repo.createOrGet(
        requestKey: 'other-key',
        chatSessionId: 's',
        characterId: 'c',
        requestJson: '{}',
      );
      expect(second.kind, 'created');
      expect(second.job.id, isNot(first.job.id));

      // Unkeyed jobs create freely for a different pair.
      final unkeyed = await repo.createOrGet(
        chatSessionId: 's2',
        characterId: 'c',
        requestJson: '{}',
      );
      expect(unkeyed.kind, 'created');
      expect(unkeyed.job.requestKey, isNull);
    },
  );

  test('named transitions are version-CASed with typed conflicts', () async {
    final id = await createJob();
    expect(
      (await repo.markPendingByPersist(jobId: id, expectedVersion: 1)).kind,
      'updated',
    );
    var row = await job(id);
    expect(row.status, 'pending');
    expect(row.version, 2);

    expect(
      (await repo.markPendingByPersist(jobId: id, expectedVersion: 1)).kind,
      'staleVersion',
    );
    expect(
      (await repo.markPendingByPersist(jobId: id, expectedVersion: 2)).kind,
      'invalidState',
    );
    expect(
      (await repo.markFailed(
        jobId: id,
        expectedVersion: 2,
        statusReason: 'parseFailed',
      )).kind,
      'invalidState',
    );
    expect(
      () => repo.markFailed(jobId: id, expectedVersion: 2, statusReason: '  '),
      throwsArgumentError,
    );
    expect(
      (await repo.cancel(jobId: 'missing', expectedVersion: 1)).kind,
      'jobNotFound',
    );
    expect((await repo.cancel(jobId: id, expectedVersion: 2)).kind, 'updated');
    row = await job(id);
    expect(row.status, 'cancelled');
    expect(row.statusReason, 'userCancelled');
    expect(row.version, 3);
    expect(
      (await repo.cancel(jobId: id, expectedVersion: 3)).kind,
      'invalidState',
    );
  });

  test('retry reopens a failed job and clears its durable reason', () async {
    final id = await createJob();
    expect(
      (await repo.markFailed(
        jobId: id,
        expectedVersion: 1,
        statusReason: 'canonMoved',
      )).kind,
      'updated',
    );
    var row = await job(id);
    expect(row.status, 'failed');
    expect(row.statusReason, 'canonMoved');
    expect(row.version, 2);

    expect((await repo.retry(jobId: id, expectedVersion: 2)).kind, 'updated');
    row = await job(id);
    expect(row.status, 'generating');
    expect(row.statusReason, isNull);
    expect(row.version, 3);
    expect(
      (await repo.retry(jobId: id, expectedVersion: 3)).kind,
      'invalidState',
    );
  });

  test(
    'persistGenerationResult commits operations, snapshots, and evidence',
    () async {
      final id = await createJob();
      final outcome = await repo.persistGenerationResult(
        id,
        expectedVersion: 1,
        operations: [
          ManualRewriteOperationDraft(
            id: 'op-valid',
            snapshotJson: snapshotFor(),
            evidence: const [
              ManualRewriteEvidenceDraft(id: 'ev-1', evidenceJson: '{"a":1}'),
              ManualRewriteEvidenceDraft(id: 'ev-2', evidenceJson: '{"b":2}'),
            ],
          ),
          // Advisory-only: a missing anchor marks the operation invalid but
          // still persists it durably for review.
          ManualRewriteOperationDraft(
            id: 'op-invalid',
            snapshotJson: snapshotFor(anchor: 'missing'),
          ),
        ],
      );
      expect(outcome.kind, 'persisted');
      expect(outcome.operationIds, ['op-valid', 'op-invalid']);

      final row = await job(id);
      expect(row.status, 'pending');
      expect(row.version, 2);

      final valid = await operation('op-valid');
      expect(valid.status, 'reviewable');
      expect(valid.decision, 'pending');
      expect(valid.decisionRevision, 0);
      expect(valid.validationStatus, 'valid');
      expect(valid.currentRevision, 1);
      expect(valid.chatSessionId, 's');
      expect((await operation('op-invalid')).validationStatus, 'invalid');

      final revisions = await (db.select(
        db.rewriteOperationRevisions,
      )..where((t) => t.rewriteOperationId.equals('op-valid'))).get();
      expect(revisions, hasLength(1));
      expect(revisions.single.revision, 1);
      expect(revisions.single.snapshotJson, valid.operationJson);
      expect(
        (await db.select(db.rewriteEvidenceRows).get())
            .map((row) => row.id)
            .toList()
          ..sort(),
        ['ev-1', 'ev-2'],
      );
    },
  );

  test(
    'live exact canon lock or override marks a persisted op invalid',
    () async {
      final id = await createJob();
      await TrackerRepo(db).upsert(
        const Tracker(
          sessionId: 's',
          name: 'canon_lock:npc:alice.status',
          value: 'locked',
          scope: 'ledger',
          updatedAt: 1,
        ),
      );
      final outcome = await repo.persistGenerationResult(
        id,
        expectedVersion: 1,
        operations: [
          ManualRewriteOperationDraft(
            id: 'op-locked',
            snapshotJson: snapshotFor(affected: ['npc:alice.status']),
          ),
          ManualRewriteOperationDraft(
            id: 'op-free',
            snapshotJson: snapshotFor(affected: ['npc:bob.status']),
          ),
        ],
      );
      expect(outcome.kind, 'persisted');
      expect((await operation('op-locked')).validationStatus, 'invalid');
      expect((await operation('op-free')).validationStatus, 'valid');
    },
  );

  test(
    'a concurrent cancel discards the parsed result with zero rows persisted',
    () async {
      final id = await createJob();
      await repo.cancel(jobId: id, expectedVersion: 1, reason: 'userCancelled');
      final currentVersion = (await job(id)).version;

      final outcome = await repo.persistGenerationResult(
        id,
        expectedVersion: currentVersion,
        operations: [
          ManualRewriteOperationDraft(id: 'op', snapshotJson: snapshotFor()),
        ],
      );
      expect(outcome.kind, 'jobCancelled');
      expect(await db.select(db.rewriteOperations).get(), isEmpty);
      expect(await db.select(db.rewriteOperationRevisions).get(), isEmpty);
      expect(await db.select(db.rewriteEvidenceRows).get(), isEmpty);
      expect((await job(id)).status, 'cancelled');

      expect(
        (await repo.persistGenerationResult(
          id,
          expectedVersion: 99,
          operations: const [],
        )).kind,
        'staleVersion',
      );
      expect(
        (await repo.persistGenerationResult(
          'missing',
          expectedVersion: 1,
          operations: const [],
        )).kind,
        'jobNotFound',
      );
    },
  );

  test('failed outcome statements roll back every draft write', () async {
    final id = await createJob();
    await expectLater(
      repo.persistGenerationResult(
        id,
        expectedVersion: 1,
        operations: [
          ManualRewriteOperationDraft(id: 'dup', snapshotJson: snapshotFor()),
          ManualRewriteOperationDraft(id: 'dup', snapshotJson: snapshotFor()),
        ],
      ),
      throwsA(anything),
    );
    expect(await db.select(db.rewriteOperations).get(), isEmpty);
    expect(await db.select(db.rewriteOperationRevisions).get(), isEmpty);
    final row = await job(id);
    expect(row.status, 'generating');
    expect(row.version, 1);
  });

  test(
    'setDecision binds the reviewed immutable revision and bumps the job',
    () async {
      final id = await createJob();
      await repo.persistGenerationResult(
        id,
        expectedVersion: 1,
        operations: [
          ManualRewriteOperationDraft(id: 'op', snapshotJson: snapshotFor()),
        ],
      );
      final approved = await repo.setDecision(
        operationId: 'op',
        expectedCurrentRevision: 1,
        expectedDecision: 'pending',
        decision: 'approved',
      );
      expect(approved.kind, 'updated');
      var op = await operation('op');
      expect(op.decision, 'approved');
      expect(op.decisionRevision, 1);
      expect((await job(id)).version, 3);

      expect(
        (await repo.setDecision(
          operationId: 'op',
          expectedCurrentRevision: 2,
          expectedDecision: 'approved',
          decision: 'rejected',
        )).kind,
        'staleRevision',
      );
      expect(
        (await repo.setDecision(
          operationId: 'op',
          expectedCurrentRevision: 1,
          expectedDecision: 'pending',
          decision: 'rejected',
        )).kind,
        'staleDecision',
      );
      expect(
        (await repo.setDecision(
          operationId: 'missing',
          expectedCurrentRevision: 1,
          expectedDecision: 'pending',
          decision: 'approved',
        )).kind,
        'operationNotFound',
      );
      await (db.update(db.rewriteOperations)..where((t) => t.id.equals('op')))
          .write(const RewriteOperationsCompanion(status: Value('applied')));
      expect(
        (await repo.setDecision(
          operationId: 'op',
          expectedCurrentRevision: 1,
          expectedDecision: 'approved',
          decision: 'rejected',
        )).kind,
        'notReviewable',
      );
      expect(
        () => repo.setDecision(
          operationId: 'op',
          expectedCurrentRevision: 1,
          expectedDecision: 'pending',
          decision: 'pending',
        ),
        throwsArgumentError,
      );
      op = await operation('op');
      expect(op.decision, 'approved');
      expect((await job(id)).version, 3);
    },
  );

  test(
    'editAndRevalidate appends an immutable revision and revalidates it only',
    () async {
      final id = await createJob();
      await repo.persistGenerationResult(
        id,
        expectedVersion: 1,
        operations: [
          ManualRewriteOperationDraft(id: 'op', snapshotJson: snapshotFor()),
        ],
      );
      final original = (await (db.select(
        db.rewriteOperationRevisions,
      )..where((t) => t.rewriteOperationId.equals('op'))).get()).single;

      final edited = snapshotFor(value: 'edited text');
      final outcome = await repo.editAndRevalidate(
        operationId: 'op',
        expectedCurrentRevision: 1,
        newSnapshotJson: edited,
        evidence: const [
          ManualRewriteEvidenceDraft(id: 'ev-edit', evidenceJson: '{"note":1}'),
        ],
      );
      expect(outcome.kind, 'updated');
      final op = await operation('op');
      expect(op.currentRevision, 2);
      expect(op.operationJson, edited);
      expect(op.decision, 'pending');
      expect(op.decisionRevision, 0);
      expect(op.validationStatus, 'valid');
      expect((await job(id)).version, 3);

      final revisions =
          await ((db.select(db.rewriteOperationRevisions)
                  ..where((t) => t.rewriteOperationId.equals('op')))
                ..orderBy([(t) => OrderingTerm.asc(t.revision)]))
              .get();
      expect(revisions, hasLength(2));
      // The original revision is immutable: it was never updated in place.
      expect(
        revisions.first.revision == 1 &&
            revisions.first.snapshotJson == original.snapshotJson,
        isTrue,
      );
      expect(revisions.last.revision, 2);
      expect(revisions.last.snapshotJson, edited);

      expect(
        (await repo.editAndRevalidate(
          operationId: 'op',
          expectedCurrentRevision: 1,
          newSnapshotJson: edited,
        )).kind,
        'staleRevision',
      );
      expect(
        (await repo.editAndRevalidate(
          operationId: 'missing',
          expectedCurrentRevision: 1,
          newSnapshotJson: edited,
        )).kind,
        'operationNotFound',
      );

      // Revalidation binds to the NEW revision text only.
      final invalid = await repo.editAndRevalidate(
        operationId: 'op',
        expectedCurrentRevision: 2,
        newSnapshotJson: snapshotFor(anchor: 'missing'),
      );
      expect(invalid.kind, 'updated');
      expect((await operation('op')).validationStatus, 'invalid');
      expect(
        (await db.select(db.rewriteEvidenceRows).get()).map((row) => row.id),
        contains('ev-edit'),
      );
    },
  );

  test(
    'edit can preserve three patches after dropping one bad patch',
    () async {
      final id = await createJob();
      final patches = [
        for (var index = 0; index < 4; index++)
          {
            'scopeKey': 'npc:person-$index',
            'anchor': 'old text',
            'anchorSha256': CardCanonicalizer.scalarSha256('old text'),
            'value': 'new text $index',
          },
      ];
      final original = jsonEncode({
        'field': 'description',
        'patches': patches,
        'transition': {
          'id': 'transition',
          'scopeKey': 'npc:alice',
          'canonicalClaim': 'updated',
          'promotionDestination': 'card',
          'affectedTrackerKeys': <String>[],
          'factIds': <String>[],
          'chatSessionId': null,
        },
      });
      await repo.persistGenerationResult(
        id,
        expectedVersion: 1,
        operations: [
          ManualRewriteOperationDraft(id: 'op', snapshotJson: original),
        ],
      );
      final decoded =
          RewriteOperationSnapshotCodec.tryDecode(jsonDecode(original))!
              as CardRewriteOperationSnapshot;
      final withoutRichard = CardRewriteOperationSnapshot(
        field: decoded.field,
        patches: [decoded.patches[0], decoded.patches[2], decoded.patches[3]],
        transition: decoded.transition,
      );

      final outcome = await repo.editAndRevalidate(
        operationId: 'op',
        expectedCurrentRevision: 1,
        newSnapshotJson: ManualRewriteOperationSnapshotCodec.encode(
          withoutRichard,
        ),
      );

      expect(outcome.kind, 'updated');
      expect(outcome.operation!.currentRevision, 2);
      final revision =
          await (db.select(db.rewriteOperationRevisions)
                ..where((row) => row.rewriteOperationId.equals('op'))
                ..where((row) => row.revision.equals(2)))
              .getSingle();
      final saved =
          RewriteOperationSnapshotCodec.tryDecode(
                jsonDecode(revision.snapshotJson),
              )!
              as CardRewriteOperationSnapshot;
      expect(saved.patches, hasLength(3));
      expect(
        saved.patches.map((patch) => patch.scopeKey),
        isNot(contains('npc:person-1')),
      );
    },
  );

  test(
    'watchJob streams the joined job/operation/evidence aggregate',
    () async {
      final id = await createJob();
      final stream = repo.watchJob(id);

      expect(await repo.watchJob('missing').first, isNull);

      await repo.persistGenerationResult(
        id,
        expectedVersion: 1,
        operations: [
          ManualRewriteOperationDraft(
            id: 'op',
            snapshotJson: snapshotFor(),
            evidence: const [
              ManualRewriteEvidenceDraft(id: 'ev-1', evidenceJson: '{}'),
              ManualRewriteEvidenceDraft(id: 'ev-2', evidenceJson: '{}'),
            ],
          ),
        ],
      );
      final snapshot = await stream.firstWhere(
        (value) => value != null && value.job.status == 'pending',
      );
      expect(snapshot, isNotNull);
      expect(snapshot!.job.id, id);
      expect(snapshot.operations, hasLength(1));
      final view = snapshot.operations.single;
      expect(view.operation.id, 'op');
      expect(view.operation.currentRevision, 1);
      expect(view.currentSnapshotJson, view.operation.operationJson);
      expect(view.evidenceCount, 2);

      await repo.cancel(jobId: id, expectedVersion: 2);
      final cancelled = await stream.firstWhere(
        (value) => value != null && value.job.status == 'cancelled',
      );
      expect(cancelled!.job.statusReason, 'userCancelled');
    },
  );

  test(
    'watchJobsBySessionId orders a session history by latest update',
    () async {
      final first = await createJob(requestKey: 'history-first');
      await repo.cancel(jobId: first, expectedVersion: 1);
      await (db.update(db.rewriteJobs)..where((row) => row.id.equals(first)))
          .write(const RewriteJobsCompanion(updatedAt: Value(1)));
      final second = await createJob(requestKey: 'history-second');

      final history = await repo.watchJobsBySessionId('s').first;

      expect(history.map((job) => job.id), [second, first]);
    },
  );
}
