import 'dart:convert';

import 'package:drift/drift.dart';

import '../../services/card_rewriter/card_rewriter_contracts.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';
import 'character_repo.dart';
import 'ledger_raw_tracker_state_reader.dart';
import 'session_lorebook_evolution_repo.dart';

/// Caller-generated evidence payload persisted alongside one operation.
final class ManualRewriteEvidenceDraft {
  const ManualRewriteEvidenceDraft({
    required this.id,
    required this.evidenceJson,
  });

  final String id;
  final String evidenceJson;
}

/// One parsed generation operation awaiting durable persistence.
/// [snapshotJson] must already be in the canonical durable request shape
/// (`{field, patches, transition}`); parsing/serialization of that shape is
/// owned by the prompt/parser lane, not this repository.
final class ManualRewriteOperationDraft {
  const ManualRewriteOperationDraft({
    required this.id,
    required this.snapshotJson,
    this.evidence = const [],
  });

  final String id;
  final String snapshotJson;
  final List<ManualRewriteEvidenceDraft> evidence;
}

/// Typed outcome of [ManualRewriteJobRepo.createOrGet]. Expected conflicts are
/// reported as kinds; they never throw.
final class CreateRewriteJobOutcome {
  const CreateRewriteJobOutcome._(this.kind, this.job);

  /// A new generating job row was inserted for this request.
  const CreateRewriteJobOutcome.created(RewriteJobRow job)
    : this._('created', job);

  /// A job with the same request key already exists; no row was inserted.
  const CreateRewriteJobOutcome.existing(RewriteJobRow job)
    : this._('existing', job);

  /// A different active (generating/pending) job already owns this
  /// session/character pair; no row was inserted.
  const CreateRewriteJobOutcome.activeJobConflict(RewriteJobRow job)
    : this._('activeJobConflict', job);

  final String kind;
  final RewriteJobRow job;
  bool get isCreated => kind == 'created';
}

/// Typed outcome of a named job-state compare-and-swap transition. A 0-row CAS
/// is diagnosed (not thrown) into one of the conflict kinds.
final class RewriteJobTransitionOutcome {
  const RewriteJobTransitionOutcome._(this.kind, [this.job]);

  const RewriteJobTransitionOutcome.updated(RewriteJobRow job)
    : this._('updated', job);
  const RewriteJobTransitionOutcome.notFound() : this._('jobNotFound');
  const RewriteJobTransitionOutcome.staleVersion(RewriteJobRow job)
    : this._('staleVersion', job);
  const RewriteJobTransitionOutcome.invalidState(RewriteJobRow job)
    : this._('invalidState', job);

  final String kind;
  final RewriteJobRow? job;
  bool get isUpdated => kind == 'updated';
}

/// Typed outcome of [ManualRewriteJobRepo.persistGenerationResult]. When the
/// job CAS fails, the whole transaction has already rolled back or never
/// wrote: no operation, revision, or evidence row persists.
final class PersistGenerationOutcome {
  const PersistGenerationOutcome._(
    this.kind, {
    this.job,
    this.operationIds = const [],
  });

  const PersistGenerationOutcome.persisted(
    RewriteJobRow job,
    List<String> operationIds,
  ) : this._('persisted', job: job, operationIds: operationIds);
  const PersistGenerationOutcome.notFound() : this._('jobNotFound');
  const PersistGenerationOutcome.staleVersion(RewriteJobRow job)
    : this._('staleVersion', job: job);
  const PersistGenerationOutcome.cancelled(RewriteJobRow job)
    : this._('jobCancelled', job: job);
  const PersistGenerationOutcome.failed(RewriteJobRow job)
    : this._('jobFailed', job: job);
  const PersistGenerationOutcome.notGenerating(RewriteJobRow job)
    : this._('jobNotGenerating', job: job);

  final String kind;
  final RewriteJobRow? job;
  final List<String> operationIds;
  bool get isPersisted => kind == 'persisted';
}

/// Typed outcome of per-operation decision/edit mutations.
final class RewriteOperationMutationOutcome {
  const RewriteOperationMutationOutcome._(this.kind, [this.operation]);

  const RewriteOperationMutationOutcome.updated(RewriteOperationRow operation)
    : this._('updated', operation);
  const RewriteOperationMutationOutcome.notFound()
    : this._('operationNotFound');
  const RewriteOperationMutationOutcome.staleRevision(
    RewriteOperationRow operation,
  ) : this._('staleRevision', operation);
  const RewriteOperationMutationOutcome.staleDecision(
    RewriteOperationRow operation,
  ) : this._('staleDecision', operation);
  const RewriteOperationMutationOutcome.notReviewable(
    RewriteOperationRow operation,
  ) : this._('notReviewable', operation);

  final String kind;
  final RewriteOperationRow? operation;
  bool get isUpdated => kind == 'updated';
}

/// One operation row joined with its current immutable snapshot and evidence
/// aggregate. Read-side view only; mutations go through the CAS methods.
final class ManualRewriteOperationView {
  const ManualRewriteOperationView({
    required this.operation,
    required this.currentSnapshotJson,
    required this.evidenceCount,
  });

  final RewriteOperationRow operation;
  final String currentSnapshotJson;
  final int evidenceCount;
}

/// Read-side aggregate consumed by the review surface: job, operations with
/// their current-revision snapshots, and evidence counts.
final class ManualRewriteJobSnapshot {
  const ManualRewriteJobSnapshot({required this.job, required this.operations});

  final RewriteJobRow job;

  /// Ordered by operation id.
  final List<ManualRewriteOperationView> operations;
}

/// Owns the durable Phase-4 rewrite job/review lifecycle: idempotent job
/// creation, named state transitions, generation persistence, and strict
/// per-operation CAS mutations.
///
/// Hard boundaries: this repository never writes characters, character
/// revisions, canon transitions, fact references, facts, or trackers, never
/// invokes an LLM, and never imports the guarded apply repository. Its
/// validation is advisory; the apply repository remains authoritative.
///
/// Every mutation runs in a single [AppDatabase.transaction]; 0-row CAS
/// writes return typed conflict outcomes instead of throwing.
class ManualRewriteJobRepo {
  ManualRewriteJobRepo({
    required AppDatabase db,
    required LedgerRawTrackerStateReader rawTrackerStateReader,
    SessionLorebookEvolutionRepo? lorebookEvolutionRepo,
  }) : _db = db,
       _rawTrackerStateReader = rawTrackerStateReader,
       _characters = CharacterRepo(db),
       _lorebookEvolutionRepo =
           lorebookEvolutionRepo ?? SessionLorebookEvolutionRepo(db) {
    if (!identical(rawTrackerStateReader.db, db)) {
      throw ArgumentError.value(
        rawTrackerStateReader,
        'rawTrackerStateReader',
        'must use the same AppDatabase',
      );
    }
  }

  final AppDatabase _db;
  final LedgerRawTrackerStateReader _rawTrackerStateReader;
  final CharacterRepo _characters;
  final SessionLorebookEvolutionRepo _lorebookEvolutionRepo;

  /// Idempotent job creation: an existing job with the same [requestKey]
  /// wins, then any still-active (generating/pending) job for the
  /// session/character pair blocks creating a second, otherwise a new
  /// `generating` job at version 1 is inserted.
  Future<CreateRewriteJobOutcome> createOrGet({
    String? requestKey,
    required String chatSessionId,
    required String characterId,
    required String requestJson,
    String canonStamp = '',
    int basisRevision = 0,
    String basisRevisionHash = '',
  }) => _db.transaction(() async {
    final jobs = _db.rewriteJobs;
    if (requestKey != null) {
      final keyed = await (_db.select(
        jobs,
      )..where((t) => t.requestKey.equals(requestKey))).getSingleOrNull();
      if (keyed != null) return CreateRewriteJobOutcome.existing(keyed);
    }
    final active =
        await (_db.select(jobs)
              ..where(
                (t) =>
                    t.chatSessionId.equals(chatSessionId) &
                    t.characterId.equals(characterId) &
                    t.status.isIn(const ['generating', 'pending']),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)])
              ..limit(1))
            .getSingleOrNull();
    if (active != null) {
      return CreateRewriteJobOutcome.activeJobConflict(active);
    }

    final now = currentTimestampSeconds();
    final id = 'rewrite-job-${generateId()}';
    final companion = RewriteJobsCompanion.insert(
      id: id,
      chatSessionId: chatSessionId,
      characterId: characterId,
      status: const Value('generating'),
      requestJson: Value(requestJson),
      basisRevision: Value(basisRevision),
      basisRevisionHash: Value(basisRevisionHash),
      canonStamp: Value(canonStamp),
      requestKey: Value(requestKey),
      version: const Value(1),
      createdAt: Value(now),
      updatedAt: Value(now),
    );
    if (requestKey != null) {
      // The unique index closes the residual two-inserter race: ON CONFLICT
      // keeps the first keyed row and suppresses ours.
      await _db
          .into(jobs)
          .insert(companion, onConflict: DoNothing(target: [jobs.requestKey]));
      final row = await (_db.select(
        jobs,
      )..where((t) => t.requestKey.equals(requestKey))).getSingle();
      return row.id == id
          ? CreateRewriteJobOutcome.created(row)
          : CreateRewriteJobOutcome.existing(row);
    }
    await _db.into(jobs).insert(companion);
    final row = await (_db.select(
      jobs,
    )..where((t) => t.id.equals(id))).getSingle();
    return CreateRewriteJobOutcome.created(row);
  });

  /// `generating → pending` for a generation attempt that produced no
  /// operations to persist (persistGenerationResult performs its own CAS).
  Future<RewriteJobTransitionOutcome> markPendingByPersist({
    required String jobId,
    required int expectedVersion,
  }) => _transition(
    jobId: jobId,
    expectedVersion: expectedVersion,
    fromStatuses: const ['generating'],
    toStatus: 'pending',
  );

  /// `generating → failed` with a mandatory durable reason.
  Future<RewriteJobTransitionOutcome> markFailed({
    required String jobId,
    required int expectedVersion,
    required String statusReason,
  }) {
    if (statusReason.trim().isEmpty) {
      throw ArgumentError.value(
        statusReason,
        'statusReason',
        'must not be empty',
      );
    }
    return _transition(
      jobId: jobId,
      expectedVersion: expectedVersion,
      fromStatuses: const ['generating'],
      toStatus: 'failed',
      statusReason: statusReason,
    );
  }

  /// `generating|pending|failed → cancelled` with a durable reason. Cancelled
  /// is terminal: retry only clears it for `failed` jobs.
  Future<RewriteJobTransitionOutcome> cancel({
    required String jobId,
    required int expectedVersion,
    String reason = 'userCancelled',
  }) => _transition(
    jobId: jobId,
    expectedVersion: expectedVersion,
    fromStatuses: const ['generating', 'pending', 'failed'],
    toStatus: 'cancelled',
    statusReason: reason,
  );

  /// `failed → generating`, clearing the durable failure reason.
  Future<RewriteJobTransitionOutcome> retry({
    required String jobId,
    required int expectedVersion,
  }) async {
    final job = await (_db.select(
      _db.rewriteJobs,
    )..where((row) => row.id.equals(jobId))).getSingleOrNull();
    if (job == null) return const RewriteJobTransitionOutcome.notFound();
    try {
      final request = jsonDecode(job.requestJson);
      if (request is Map && request['provenance'] == 'automatedEvolution') {
        return RewriteJobTransitionOutcome.invalidState(job);
      }
    } catch (_) {
      // Malformed manual request provenance remains governed by normal CAS.
    }
    return _transition(
      jobId: jobId,
      expectedVersion: expectedVersion,
      fromStatuses: const ['failed'],
      toStatus: 'generating',
      clearStatusReason: true,
    );
  }

  /// Caller-owned transaction helper for automation. It creates the same
  /// pending/reviewable aggregate as manual generation without exposing any
  /// approve, edit, retry, or apply behavior to the automated service.
  Future<RewriteJobRow> insertPendingInTransaction({
    required String jobId,
    required String chatSessionId,
    required String characterId,
    required String requestJson,
    required String requestKey,
    required int basisRevision,
    required String basisRevisionHash,
    required String canonStamp,
    required List<ManualRewriteOperationDraft> operations,
    required int now,
  }) async {
    if (operations.isEmpty) {
      throw ArgumentError.value(operations, 'operations', 'must not be empty');
    }
    await _db
        .into(_db.rewriteJobs)
        .insert(
          RewriteJobsCompanion.insert(
            id: jobId,
            chatSessionId: chatSessionId,
            characterId: characterId,
            status: const Value('pending'),
            requestJson: Value(requestJson),
            requestKey: Value(requestKey),
            basisRevision: Value(basisRevision),
            basisRevisionHash: Value(basisRevisionHash),
            canonStamp: Value(canonStamp),
            version: const Value(1),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    for (final operation in operations) {
      await _db
          .into(_db.rewriteOperations)
          .insert(
            RewriteOperationsCompanion.insert(
              id: operation.id,
              rewriteJobId: jobId,
              chatSessionId: chatSessionId,
              operationJson: Value(operation.snapshotJson),
              status: const Value('reviewable'),
              currentRevision: const Value(1),
              validationStatus: const Value('valid'),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
      await _db
          .into(_db.rewriteOperationRevisions)
          .insert(
            RewriteOperationRevisionsCompanion.insert(
              rewriteOperationId: operation.id,
              revision: 1,
              snapshotJson: operation.snapshotJson,
              createdAt: Value(now),
            ),
          );
      for (final item in operation.evidence) {
        await _db
            .into(_db.rewriteEvidenceRows)
            .insert(
              RewriteEvidenceRowsCompanion.insert(
                id: item.id,
                rewriteOperationId: operation.id,
                evidenceJson: item.evidenceJson,
                createdAt: Value(now),
              ),
            );
      }
    }
    return (_db.select(
      _db.rewriteJobs,
    )..where((row) => row.id.equals(jobId))).getSingle();
  }

  Future<RewriteJobTransitionOutcome> _transition({
    required String jobId,
    required int expectedVersion,
    required List<String> fromStatuses,
    required String toStatus,
    String? statusReason,
    bool clearStatusReason = false,
  }) => _db.transaction(() async {
    final jobs = _db.rewriteJobs;
    final changed =
        await (_db.update(jobs)..where(
              (t) =>
                  t.id.equals(jobId) &
                  t.version.equals(expectedVersion) &
                  t.status.isIn(fromStatuses),
            ))
            .write(
              RewriteJobsCompanion(
                status: Value(toStatus),
                statusReason: clearStatusReason
                    ? const Value<String?>(null)
                    : statusReason != null
                    ? Value(statusReason)
                    : const Value.absent(),
                version: Value(expectedVersion + 1),
                updatedAt: Value(currentTimestampSeconds()),
              ),
            );
    if (changed == 1) {
      final job = await (_db.select(
        jobs,
      )..where((t) => t.id.equals(jobId))).getSingle();
      return RewriteJobTransitionOutcome.updated(job);
    }
    final job = await (_db.select(
      jobs,
    )..where((t) => t.id.equals(jobId))).getSingleOrNull();
    if (job == null) return const RewriteJobTransitionOutcome.notFound();
    if (job.version != expectedVersion) {
      return RewriteJobTransitionOutcome.staleVersion(job);
    }
    return RewriteJobTransitionOutcome.invalidState(job);
  });

  /// Interlocked generation persistence: the job CAS `generating → pending`
  /// runs first, so a concurrent cancel/fail leaves this a 0-row write and
  /// the transaction returns a typed conflict with nothing persisted. Each
  /// operation is inserted reviewable at immutable revision 1 with advisory
  /// validation and its revision-1 snapshot and evidence rows.
  Future<PersistGenerationOutcome> persistGenerationResult(
    String jobId, {
    required int expectedVersion,
    required List<ManualRewriteOperationDraft> operations,
  }) => _db.transaction(() async {
    final jobs = _db.rewriteJobs;
    final changed =
        await (_db.update(jobs)..where(
              (t) =>
                  t.id.equals(jobId) &
                  t.version.equals(expectedVersion) &
                  t.status.equals('generating'),
            ))
            .write(
              RewriteJobsCompanion(
                status: const Value('pending'),
                version: Value(expectedVersion + 1),
                updatedAt: Value(currentTimestampSeconds()),
              ),
            );
    if (changed != 1) {
      final job = await (_db.select(
        jobs,
      )..where((t) => t.id.equals(jobId))).getSingleOrNull();
      if (job == null) return const PersistGenerationOutcome.notFound();
      if (job.version != expectedVersion) {
        return PersistGenerationOutcome.staleVersion(job);
      }
      return switch (job.status) {
        'cancelled' => PersistGenerationOutcome.cancelled(job),
        'failed' => PersistGenerationOutcome.failed(job),
        _ => PersistGenerationOutcome.notGenerating(job),
      };
    }
    final job = await (_db.select(
      jobs,
    )..where((t) => t.id.equals(jobId))).getSingle();
    final now = currentTimestampSeconds();
    final ids = <String>[];
    for (final draft in operations) {
      final validation = await _validateAdvisory(job, draft.snapshotJson);
      await _db
          .into(_db.rewriteOperations)
          .insert(
            RewriteOperationsCompanion.insert(
              id: draft.id,
              rewriteJobId: jobId,
              chatSessionId: job.chatSessionId,
              operationJson: Value(draft.snapshotJson),
              status: const Value('reviewable'),
              currentRevision: const Value(1),
              validationStatus: Value(validation),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
      await _db
          .into(_db.rewriteOperationRevisions)
          .insert(
            RewriteOperationRevisionsCompanion.insert(
              rewriteOperationId: draft.id,
              revision: 1,
              snapshotJson: draft.snapshotJson,
              createdAt: Value(now),
            ),
          );
      for (final item in draft.evidence) {
        await _db
            .into(_db.rewriteEvidenceRows)
            .insert(
              RewriteEvidenceRowsCompanion.insert(
                id: item.id,
                rewriteOperationId: draft.id,
                evidenceJson: item.evidenceJson,
                createdAt: Value(now),
              ),
            );
      }
      ids.add(draft.id);
    }
    return PersistGenerationOutcome.persisted(job, ids);
  });

  /// Strict reviewer-decision CAS: id + current revision + expected decision
  /// + `status='reviewable'` + unapplied. Both approve and reject bind the
  /// decision to the current immutable revision and bump the job version.
  Future<RewriteOperationMutationOutcome> setDecision({
    required String operationId,
    required int expectedCurrentRevision,
    required String expectedDecision,
    required String decision,
  }) {
    if (decision != 'approved' && decision != 'rejected') {
      throw ArgumentError.value(
        decision,
        'decision',
        'must be approved or rejected',
      );
    }
    return _db.transaction(() async {
      final ops = _db.rewriteOperations;
      final changed =
          await (_db.update(ops)..where(
                (t) =>
                    t.id.equals(operationId) &
                    t.currentRevision.equals(expectedCurrentRevision) &
                    t.decision.equals(expectedDecision) &
                    t.status.equals('reviewable') &
                    t.appliedCharacterRevision.equals(0),
              ))
              .write(
                RewriteOperationsCompanion(
                  decision: Value(decision),
                  // The decision binds the revision it reviewed; the CAS
                  // above guarantees that is still [expectedCurrentRevision].
                  decisionRevision: Value(expectedCurrentRevision),
                  updatedAt: Value(currentTimestampSeconds()),
                ),
              );
      if (changed == 1) {
        final op = await (_db.select(
          ops,
        )..where((t) => t.id.equals(operationId))).getSingle();
        await _bumpJobVersion(op.rewriteJobId);
        return RewriteOperationMutationOutcome.updated(op);
      }
      return _diagnoseOperation(
        operationId,
        expectedCurrentRevision,
        expectedDecision,
      );
    });
  }

  /// Reviewer edit: appends immutable revision `current+1` (old revisions are
  /// never updated), CAS-moves the operation pointer to it with decision and
  /// validation reset to `pending`, then advisory-revalidates the NEW
  /// revision only and bumps the job version.
  Future<RewriteOperationMutationOutcome> editAndRevalidate({
    required String operationId,
    required int expectedCurrentRevision,
    required String newSnapshotJson,
    List<ManualRewriteEvidenceDraft> evidence = const [],
  }) => _db.transaction(() async {
    final ops = _db.rewriteOperations;
    final op = await (_db.select(
      ops,
    )..where((t) => t.id.equals(operationId))).getSingleOrNull();
    if (op == null) return const RewriteOperationMutationOutcome.notFound();
    if (op.currentRevision != expectedCurrentRevision) {
      return RewriteOperationMutationOutcome.staleRevision(op);
    }
    if (op.status != 'reviewable' || op.appliedCharacterRevision != 0) {
      return RewriteOperationMutationOutcome.notReviewable(op);
    }
    final newRevision = expectedCurrentRevision + 1;
    final now = currentTimestampSeconds();
    await _db
        .into(_db.rewriteOperationRevisions)
        .insert(
          RewriteOperationRevisionsCompanion.insert(
            rewriteOperationId: operationId,
            revision: newRevision,
            snapshotJson: newSnapshotJson,
            createdAt: Value(now),
          ),
        );
    final changed =
        await (_db.update(ops)..where(
              (t) =>
                  t.id.equals(operationId) &
                  t.currentRevision.equals(expectedCurrentRevision) &
                  t.status.equals('reviewable') &
                  t.appliedCharacterRevision.equals(0),
            ))
            .write(
              RewriteOperationsCompanion(
                operationJson: Value(newSnapshotJson),
                currentRevision: Value(newRevision),
                decision: const Value('pending'),
                decisionRevision: const Value(0),
                validationStatus: const Value('pending'),
                updatedAt: Value(now),
              ),
            );
    if (changed != 1) {
      // The pre-check and this CAS share one transaction, so a 0-row write
      // is an impossible internal race; rolling back also discards the new
      // revision row above.
      throw StateError('Operation CAS changed inside edit transaction.');
    }
    for (final item in evidence) {
      await _db
          .into(_db.rewriteEvidenceRows)
          .insert(
            RewriteEvidenceRowsCompanion.insert(
              id: item.id,
              rewriteOperationId: operationId,
              evidenceJson: item.evidenceJson,
              createdAt: Value(now),
            ),
          );
    }
    final job = await (_db.select(
      _db.rewriteJobs,
    )..where((t) => t.id.equals(op.rewriteJobId))).getSingle();
    final validation = await _validateAdvisory(job, newSnapshotJson);
    final validated =
        await (_db.update(ops)..where(
              (t) =>
                  t.id.equals(operationId) &
                  t.currentRevision.equals(newRevision) &
                  t.decision.equals('pending') &
                  t.validationStatus.equals('pending'),
            ))
            .write(
              RewriteOperationsCompanion(validationStatus: Value(validation)),
            );
    if (validated != 1) {
      throw StateError('Revalidation target changed inside edit transaction.');
    }
    await _bumpJobVersion(op.rewriteJobId);
    final updated = await (_db.select(
      ops,
    )..where((t) => t.id.equals(operationId))).getSingle();
    return RewriteOperationMutationOutcome.updated(updated);
  });

  Future<RewriteOperationMutationOutcome> _diagnoseOperation(
    String operationId,
    int expectedCurrentRevision,
    String expectedDecision,
  ) async {
    final op = await (_db.select(
      _db.rewriteOperations,
    )..where((t) => t.id.equals(operationId))).getSingleOrNull();
    if (op == null) return const RewriteOperationMutationOutcome.notFound();
    if (op.currentRevision != expectedCurrentRevision) {
      return RewriteOperationMutationOutcome.staleRevision(op);
    }
    if (op.decision != expectedDecision) {
      return RewriteOperationMutationOutcome.staleDecision(op);
    }
    return RewriteOperationMutationOutcome.notReviewable(op);
  }

  Future<void> _bumpJobVersion(String jobId) async {
    final jobs = _db.rewriteJobs;
    final job = await (_db.select(
      jobs,
    )..where((t) => t.id.equals(jobId))).getSingle();
    await (_db.update(jobs)..where((t) => t.id.equals(jobId))).write(
      RewriteJobsCompanion(
        version: Value(job.version + 1),
        updatedAt: Value(currentTimestampSeconds()),
      ),
    );
  }

  /// Advisory-only validation against live card or session-overlay content.
  /// Guarded apply revalidates everything; an `invalid` result here only marks
  /// the durable operation row.
  Future<String> _validateAdvisory(
    RewriteJobRow job,
    String snapshotJson,
  ) async {
    final snapshot = _decodeSnapshot(snapshotJson);
    if (snapshot == null) return 'invalid';
    if (snapshot case LorebookRewriteOperationSnapshot lore) {
      final overlays = await _lorebookEvolutionRepo.getByTargets(
        sessionId: job.chatSessionId,
        targets: [(lore.lorebookId, lore.entryId)],
      );
      final current =
          overlays['${lore.lorebookId}\u0000${lore.entryId}']?.content ??
          lore.baseContent;
      if (CardCanonicalizer.scalarSha256(current) != lore.expectedContentHash) {
        return 'invalid';
      }
      return _validLorebookPatches(current, lore.patches) ? 'valid' : 'invalid';
    }
    final parsed = snapshot as CardRewriteOperationSnapshot;
    final character = await _characters.getById(job.characterId);
    if (character == null) return 'invalid';
    final values = <CardRewriteField, String?>{
      CardRewriteField.description: character.description,
      CardRewriteField.personality: character.personality,
      CardRewriteField.scenario: character.scenario,
      CardRewriteField.systemPrompt: character.systemPrompt,
      CardRewriteField.postHistoryInstructions:
          character.postHistoryInstructions,
      CardRewriteField.creatorNotes: character.creatorNotes,
    };
    final validation = AnchoredScalarPatchValidator.validate(
      patches: parsed.patches,
      currentCardValues: values,
    );
    if (!validation.isValid) return 'invalid';
    if (parsed.transition.affectedTrackerKeys.isNotEmpty) {
      final controls = (await _rawTrackerStateReader.read(
        job.chatSessionId,
      )).manualControls;
      final blocked = parsed.transition.affectedTrackerKeys.any(
        (key) => controls.any(
          (control) =>
              control.name == 'canon_override:$key' ||
              control.name == 'canon_lock:$key',
        ),
      );
      if (blocked) return 'invalid';
    }
    return 'valid';
  }

  static RewriteOperationSnapshot? _decodeSnapshot(String source) {
    try {
      return RewriteOperationSnapshotCodec.tryDecode(jsonDecode(source));
    } catch (_) {
      return null;
    }
  }

  static bool _validLorebookPatches(
    String content,
    List<LorebookAnchoredPatch> patches,
  ) {
    var current = content;
    final anchors = <String>{};
    for (final patch in patches) {
      if (!anchors.add(patch.anchorSha256) ||
          CardCanonicalizer.scalarSha256(patch.anchor) != patch.anchorSha256 ||
          !AnchoredScalarPatchValidator.preservesMacroTokens(
            patch.anchor,
            patch.value,
          ) ||
          _occurrences(current, patch.anchor) != 1) {
        return false;
      }
      current = current.replaceFirst(patch.anchor, patch.value);
    }
    return true;
  }

  static int _occurrences(String value, String anchor) {
    if (anchor.isEmpty) return value.isEmpty ? 1 : 0;
    var count = 0;
    var from = 0;
    while (true) {
      final index = value.indexOf(anchor, from);
      if (index == -1) return count;
      count++;
      from = index + anchor.length;
    }
  }

  /// Read-side aggregate watcher keyed by job id: job row plus each operation
  /// joined with its current immutable revision snapshot and evidence count.
  Stream<ManualRewriteJobSnapshot?> watchJob(String jobId) {
    final jobs = _db.rewriteJobs;
    final ops = _db.rewriteOperations;
    final revisions = _db.rewriteOperationRevisions;
    final evidence = _db.rewriteEvidenceRows;
    final evidenceCount = evidence.id.count();
    final query = _db.select(jobs).join([
      leftOuterJoin(ops, ops.rewriteJobId.equalsExp(jobs.id)),
      leftOuterJoin(
        revisions,
        revisions.rewriteOperationId.equalsExp(ops.id) &
            revisions.revision.equalsExp(ops.currentRevision),
      ),
      leftOuterJoin(evidence, evidence.rewriteOperationId.equalsExp(ops.id)),
    ]);
    query
      ..where(jobs.id.equals(jobId))
      ..addColumns([evidenceCount])
      ..groupBy([ops.id]);
    return query.watch().map((rows) {
      if (rows.isEmpty) return null;
      final views = <ManualRewriteOperationView>[];
      for (final row in rows) {
        final operation = row.readTableOrNull(ops);
        if (operation == null) continue;
        views.add(
          ManualRewriteOperationView(
            operation: operation,
            currentSnapshotJson:
                row.readTableOrNull(revisions)?.snapshotJson ?? '',
            evidenceCount: row.read(evidenceCount) ?? 0,
          ),
        );
      }
      views.sort((a, b) => a.operation.id.compareTo(b.operation.id));
      return ManualRewriteJobSnapshot(
        job: rows.first.readTable(jobs),
        operations: views,
      );
    });
  }

  /// Read-only session history for review navigation. The durable job rows
  /// already represent both manual rewrites and automated evolution proposals.
  Stream<List<RewriteJobRow>> watchJobsBySessionId(String sessionId) {
    return (_db.select(_db.rewriteJobs)
          ..where((row) => row.chatSessionId.equals(sessionId))
          ..orderBy([
            (row) => OrderingTerm.desc(row.updatedAt),
            (row) => OrderingTerm.desc(row.id),
          ]))
        .watch();
  }
}
