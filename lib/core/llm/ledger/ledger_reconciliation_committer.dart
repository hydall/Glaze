import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../db/repositories/character_knowledge_fact_repo.dart';
import '../../db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import '../../db/repositories/ledger_reconciliation_lease_repo.dart';
import '../../db/repositories/ledger_reconciliation_run_repo.dart';
import '../../db/repositories/reconciliation_replacement_repo.dart';
import '../../db/repositories/tracker_repo.dart';
import '../../db/repositories/tracker_snapshot_repo.dart';
import '../../models/knowledge_cleanup.dart';
import '../../models/studio_ledger_export.dart';
import '../../models/tracker.dart';
import '../../utils/cast_helpers.dart';
import '../../utils/time_helpers.dart';
import '../studio_ledger_reconciliation.dart';
import 'ledger_canon_authority.dart';
import 'ledger_op_applier.dart';
import 'ledger_replacement_basis_resolver.dart';

final class LedgerReconciliationCommitRequest {
  LedgerReconciliationCommitRequest({
    required this.sessionId,
    required this.leaseOwnerId,
    required this.plan,
    required this.canon,
    required this.promptTrackers,
    required this.export,
    required this.cleanupOps,
    required this.allowedCleanupFactIds,
    required this.token,
    required this.isStillCurrent,
    required this.replacement,
  }) : anchors = plan.messages
           .map(
             (message) => ReconciliationAnchor(
               messageId: message.id,
               swipeId: message.swipeId,
               agentSwipeId: message.agentSwipeId,
               role: message.role,
               contentHash: computeHash(message.content),
             ),
           )
           .toList(growable: false),
       canonicalResult = <String, dynamic>{
         'cleanupOps': cleanupOps.map(_cleanupOpJson).toList(growable: false),
         'export': jsonDecode(jsonEncode(export.toJson())),
       },
       intendedOps = <String>[
         ...export.ops.map((op) => 'tracker:${op.op}:${op.key}'),
         ...cleanupOps.map(_cleanupOpMetadata),
       ];

  final String sessionId;
  final String leaseOwnerId;
  final LedgerReconciliationPlan plan;
  final LedgerCanonContext canon;
  final List<Tracker> promptTrackers;
  final StudioLedgerExport export;
  final List<KnowledgeCleanupOp> cleanupOps;
  final Set<String> allowedCleanupFactIds;
  final CancelToken token;
  final FutureOr<bool> Function()? isStillCurrent;
  final LedgerReplacementBasisReady? replacement;
  final List<ReconciliationAnchor> anchors;
  final Map<String, dynamic> canonicalResult;
  final List<String> intendedOps;
}

final class LedgerReconciliationCommitResult {
  const LedgerReconciliationCommitResult({
    required this.opsApplied,
    required this.replayed,
  });

  final int opsApplied;
  final bool replayed;
}

final class LedgerReconciliationCommitter {
  factory LedgerReconciliationCommitter({
    required TrackerRepo trackerRepo,
    required TrackerSnapshotRepo snapshotRepo,
    required CharacterKnowledgeFactRepo knowledgeFactRepo,
    required LedgerReconciliationCheckpointRepo reconciliationCheckpointRepo,
    required LedgerReconciliationRunRepo reconciliationRunRepo,
    required LedgerReconciliationLeaseRepo reconciliationLeaseRepo,
    required ReconciliationReplacementRepo replacementRepo,
    required LedgerCanonAuthority canonAuthority,
    required LedgerReplacementBasisResolver replacementBasisResolver,
    required LedgerOpApplier opApplier,
  }) => LedgerReconciliationCommitter._(
    trackerRepo,
    snapshotRepo,
    knowledgeFactRepo,
    reconciliationCheckpointRepo,
    reconciliationRunRepo,
    reconciliationLeaseRepo,
    replacementRepo,
    canonAuthority,
    replacementBasisResolver,
    opApplier,
  );

  const LedgerReconciliationCommitter._(
    this._trackerRepo,
    this._snapshotRepo,
    this._knowledgeFactRepo,
    this._reconciliationCheckpointRepo,
    this._reconciliationRunRepo,
    this._reconciliationLeaseRepo,
    this._replacementRepo,
    this._canonAuthority,
    this._replacementBasisResolver,
    this._opApplier,
  );

  final TrackerRepo _trackerRepo;
  final TrackerSnapshotRepo _snapshotRepo;
  final CharacterKnowledgeFactRepo _knowledgeFactRepo;
  final LedgerReconciliationCheckpointRepo _reconciliationCheckpointRepo;
  final LedgerReconciliationRunRepo _reconciliationRunRepo;
  final LedgerReconciliationLeaseRepo _reconciliationLeaseRepo;
  final ReconciliationReplacementRepo _replacementRepo;
  final LedgerCanonAuthority _canonAuthority;
  final LedgerReplacementBasisResolver _replacementBasisResolver;
  final LedgerOpApplier _opApplier;

  Future<LedgerReconciliationCommitResult> commit(
    LedgerReconciliationCommitRequest request,
  ) async {
    var opsApplied = 0;
    var replayed = false;
    final plan = request.plan;
    final replacement = request.replacement;
    final target = LedgerTarget.fromMessage(plan.endMessage);
    await _trackerRepo.db.transaction(() async {
      if (!await _reconciliationLeaseRepo.ownsLiveLeaseInTransaction(
        sessionId: request.sessionId,
        ownerId: request.leaseOwnerId,
      )) {
        throw const LedgerCommitStale();
      }
      if (replacement == null) {
        await _canonAuthority.throwIfCommitStale(
          sessionId: request.sessionId,
          canon: request.canon,
          token: request.token,
          isStillCurrent: request.isStillCurrent,
          target: target,
          requireCommittedSnapshot: true,
        );
      } else {
        await _replacementBasisResolver.throwIfReplacementStale(
          replacement,
          token: request.token,
          isStillCurrent: request.isStillCurrent,
        );
      }
      final manifestRefs = await _reconciliationRunRepo
          .readAcceptedManifestRefs(
            sessionId: request.sessionId,
            anchors: request.anchors,
          );
      final beforeState =
          replacement?.effect.before ??
          await _reconciliationRunRepo.captureState(request.sessionId);
      final candidate = LedgerReconciliationRun(
        id: '',
        sessionId: request.sessionId,
        ordinal: 1,
        anchors: request.anchors,
        acceptedManifestRefs: manifestRefs,
        effectiveCanonStamp: request.canon.context.stamp.identity,
        effectiveCanonRevision: request.canon.context.effectiveRevision.number,
        effectiveCanonHash: request.canon.context.effectiveRevision.hash,
        canonicalResult: request.canonicalResult,
        predecessorChainHash: '',
        contractVersion: 1,
        opsApplied: request.intendedOps,
        createdAt: currentTimestampSeconds(),
      );
      // The ID covers immutable candidate content, so a canon change appends
      // rather than colliding with an earlier identical plan/LLM output.
      final draft = LedgerReconciliationRun(
        id: 'reconciliation-${candidate.contentHash}',
        sessionId: candidate.sessionId,
        ordinal: candidate.ordinal,
        anchors: candidate.anchors,
        acceptedManifestRefs: candidate.acceptedManifestRefs,
        effectiveCanonStamp: candidate.effectiveCanonStamp,
        effectiveCanonRevision: candidate.effectiveCanonRevision,
        effectiveCanonHash: candidate.effectiveCanonHash,
        canonicalResult: candidate.canonicalResult,
        predecessorChainHash: candidate.predecessorChainHash,
        contractVersion: candidate.contractVersion,
        opsApplied: candidate.opsApplied,
        createdAt: candidate.createdAt,
      );
      if (replacement != null &&
          draft.manifestsJson != replacement.head.acceptedManifestRefsJson) {
        throw const LedgerCommitStale();
      }
      if (replacement != null &&
          draft.contentHash == replacement.head.contentHash) {
        replayed = true;
        return;
      }
      if (replacement != null) {
        await _replacementRepo.resetDownstreamInTransaction(
          sessionId: request.sessionId,
          reconciliationRunId: replacement.head.id,
          now: candidate.createdAt,
        );
        final invalidated = await _reconciliationRunRepo
            .invalidateLatestForReplacement(
              sessionId: request.sessionId,
              expectedRunId: replacement.head.id,
              expectedChainHash: replacement.head.chainHash,
              createdAt: candidate.createdAt,
            );
        if (invalidated is! ReconciliationHeadInvalidated) {
          throw const LedgerCommitStale();
        }
        await _knowledgeFactRepo.deleteCleanupJournalsForExactRange(
          sessionId: request.sessionId,
          endpointMessageId: plan.endMessage.id,
          messageIds: plan.messageIds,
        );
        await _trackerRepo.restoreLedgerRowsExact(
          request.sessionId,
          replacement.effect.before.ledgerJson,
        );
        await _knowledgeFactRepo.restoreSessionRowsExact(
          request.sessionId,
          replacement.effect.before.knowledgeJson,
        );
        if (!await _reconciliationRunRepo.currentStateMatches(
          request.sessionId,
          replacement.effect.before,
        )) {
          throw StateError(
            'Exact reconciliation before-state was not restored',
          );
        }
      }
      final append = await _reconciliationRunRepo.appendCandidate(draft);
      if (append is ReconciliationRunIdempotent) {
        replayed = true;
        return;
      }
      if (append is! ReconciliationRunAppended) {
        final reason = switch (append) {
          ReconciliationRunMalformed(:final reason) => reason,
          ReconciliationRunChainGap(:final reason) => reason,
          ReconciliationRunConcurrencyConflict(:final reason) => reason,
          ReconciliationRunConflict(:final reason) => reason,
          _ => append.runtimeType.toString(),
        };
        throw StateError('Unable to append reconciliation run: $reason');
      }
      await _trackerRepo.replaceLedgerState(
        request.sessionId,
        _canonAuthority.stampTrackers(request.canon, request.promptTrackers),
      );
      for (final op in request.export.ops) {
        await _canonAuthority.throwIfCommitStale(
          sessionId: request.sessionId,
          canon: request.canon,
          token: request.token,
          isStillCurrent: request.isStillCurrent,
          target: target,
          checkCanon: replacement == null,
        );
        await _opApplier.applyOp(
          op: op,
          sessionId: request.sessionId,
          messageId: plan.endMessage.id,
          swipeId: plan.endMessage.swipeId,
          agentSwipeId: plan.endMessage.agentSwipeId,
          trackerRepo: _trackerRepo,
          basisRevisionNumber: request.canon.context.effectiveRevision.number,
          basisRevisionHash: request.canon.context.effectiveRevision.hash,
        );
        opsApplied++;
      }
      await _canonAuthority.throwIfCommitStale(
        sessionId: request.sessionId,
        canon: request.canon,
        token: request.token,
        isStillCurrent: request.isStillCurrent,
        target: target,
        checkCanon: replacement == null,
      );
      opsApplied += await _knowledgeFactRepo.applyReconciliationCleanup(
        sessionId: request.sessionId,
        ops: request.cleanupOps,
        allowedFactIds: request.allowedCleanupFactIds,
        endpointMessageId: plan.endMessage.id,
        messageIds: plan.messageIds,
      );
      await _canonAuthority.throwIfCommitStale(
        sessionId: request.sessionId,
        canon: request.canon,
        token: request.token,
        isStillCurrent: request.isStillCurrent,
        target: target,
        checkCanon: false,
      );
      final updated = await _trackerRepo.getBySessionId(request.sessionId);
      final afterState = await _reconciliationRunRepo.captureState(
        request.sessionId,
      );
      final appendedRun = await _reconciliationRunRepo.getByContentHash(
        request.sessionId,
        draft.contentHash,
      );
      if (appendedRun == null) {
        throw StateError('Appended reconciliation run is unavailable');
      }
      await _reconciliationRunRepo.recordEffect(
        runId: appendedRun.id,
        sessionId: request.sessionId,
        before: beforeState,
        after: afterState,
        createdAt: candidate.createdAt,
      );
      await _canonAuthority.throwIfCommitStale(
        sessionId: request.sessionId,
        canon: request.canon,
        token: request.token,
        isStillCurrent: request.isStillCurrent,
        target: target,
        checkCanon: false,
      );
      await _snapshotRepo.upsertTrackers(
        sessionId: request.sessionId,
        messageId: plan.endMessage.id,
        swipeId: plan.endMessage.swipeId,
        agentSwipeId: plan.endMessage.agentSwipeId,
        trackers: updated,
        committed: true,
      );
      await _throwIfReconciliationAborted(request);
      await _reconciliationCheckpointRepo.upsert(
        LedgerReconciliationCheckpoint(
          sessionId: request.sessionId,
          startMessageId: plan.startMessageId,
          endMessageId: plan.endMessage.id,
          endSwipeId: plan.endMessage.swipeId,
          endAgentSwipeId: plan.endMessage.agentSwipeId,
          messageIds: plan.messageIds,
          rangeHash: plan.rangeHash,
        ),
      );
      await _canonAuthority.throwIfCommitStale(
        sessionId: request.sessionId,
        canon: request.canon,
        token: request.token,
        isStillCurrent: request.isStillCurrent,
        target: target,
        checkCanon: false,
      );
    });
    return LedgerReconciliationCommitResult(
      opsApplied: opsApplied,
      replayed: replayed,
    );
  }

  Future<void> _throwIfReconciliationAborted(
    LedgerReconciliationCommitRequest request,
  ) async {
    if (request.token.isCancelled ||
        await _canonAuthority.passesCurrentnessGuard(request.isStillCurrent) ==
            false) {
      throw const LedgerCommitStale();
    }
  }
}

Map<String, dynamic> _cleanupOpJson(KnowledgeCleanupOp op) => {
  'type': op.type.name,
  if (op.factId.isNotEmpty) 'factId': op.factId,
  if (op.fromKey.isNotEmpty) 'fromKey': op.fromKey,
  if (op.toKey.isNotEmpty) 'toKey': op.toKey,
  if (op.canonicalName.isNotEmpty) 'canonicalName': op.canonicalName,
};

String _cleanupOpMetadata(KnowledgeCleanupOp op) => switch (op.type) {
  KnowledgeCleanupOpType.retract => 'cleanup:retract:${op.factId}',
  KnowledgeCleanupOpType.renameEntity =>
    'cleanup:rename:${op.fromKey}:${op.toKey}:${op.canonicalName}',
};
