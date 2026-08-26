import 'dart:async';

import 'package:dio/dio.dart';

import '../../db/app_db.dart';
import '../../db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import '../../db/repositories/ledger_reconciliation_run_repo.dart';
import '../../db/repositories/reconciliation_replacement_repo.dart';
import '../../db/repositories/reconciliation_state_codec.dart';
import '../../db/repositories/tracker_snapshot_repo.dart';
import '../studio_ledger_reconciliation.dart';
import 'ledger_canon_authority.dart';

final class LedgerReplacementBasisResolver {
  factory LedgerReplacementBasisResolver({
    required LedgerReconciliationCheckpointRepo reconciliationCheckpointRepo,
    required LedgerReconciliationRunRepo reconciliationRunRepo,
    required ReconciliationReplacementRepo replacementRepo,
    required TrackerSnapshotRepo snapshotRepo,
    required LedgerCanonAuthority canonAuthority,
  }) => LedgerReplacementBasisResolver._(
    reconciliationCheckpointRepo,
    reconciliationRunRepo,
    replacementRepo,
    snapshotRepo,
    canonAuthority,
  );

  const LedgerReplacementBasisResolver._(
    this._reconciliationCheckpointRepo,
    this._reconciliationRunRepo,
    this._replacementRepo,
    this._snapshotRepo,
    this._canonAuthority,
  );

  final LedgerReconciliationCheckpointRepo _reconciliationCheckpointRepo;
  final LedgerReconciliationRunRepo _reconciliationRunRepo;
  final ReconciliationReplacementRepo _replacementRepo;
  final TrackerSnapshotRepo _snapshotRepo;
  final LedgerCanonAuthority _canonAuthority;

  Future<LedgerReplacementBasis> prepare({
    required String sessionId,
    required String expectedRunId,
    required CancelToken token,
    required FutureOr<bool> Function()? isStillCurrent,
  }) async {
    if (token.isCancelled ||
        await _canonAuthority.passesCurrentnessGuard(isStillCurrent) == false) {
      return const LedgerReplacementBasisFailure('Replacement was cancelled');
    }
    if (await _reconciliationRunRepo.validateChain(sessionId)
        is! ReconciliationRunValid) {
      return const LedgerReplacementBasisFailure(
        'Reconciliation history failed integrity validation',
      );
    }
    final head = await _reconciliationRunRepo.getHead(sessionId);
    if (head == null || head.id != expectedRunId) {
      return const LedgerReplacementBasisFailure(
        'The selected reconciliation is no longer the latest commit',
      );
    }
    final validated = await _reconciliationRunRepo.validateEffect(head);
    if (validated is! ReconciliationEffectValid) {
      return LedgerReplacementBasisFailure(
        validated is ReconciliationEffectInvalid
            ? validated.reason
            : 'Exact reconciliation effect is unavailable',
      );
    }
    if (!await _reconciliationRunRepo.currentStateMatches(
      sessionId,
      validated.after,
    )) {
      return const LedgerReplacementBasisFailure(
        'Current Ledger or knowledge state changed after this commit',
      );
    }
    final messages = await _reconciliationRunRepo.reconstructSelectedMessages(
      head,
    );
    if (messages == null || messages.isEmpty) {
      return const LedgerReplacementBasisFailure(
        'The committed message range no longer matches the transcript',
      );
    }
    final plan = LedgerReconciliationPlan(
      messages: messages,
      endMessage: messages.last,
      rangeHash: computeLedgerReconciliationRangeHash(messages),
    );
    final checkpoint = await _reconciliationCheckpointRepo.get(sessionId);
    if (!_checkpointMatchesPlan(checkpoint, plan)) {
      return const LedgerReplacementBasisFailure(
        'Reconciliation checkpoint does not match the latest commit',
      );
    }
    if (await _replacementRepo.hasAppliedDependency(
      sessionId: sessionId,
      reconciliationRunId: head.id,
    )) {
      return const LedgerReplacementBasisFailure(
        'An applied Card Rewriter proposal depends on this reconciliation',
      );
    }
    final currentCanon = await _canonAuthority.loadReadOnly(sessionId);
    final decoded = ReconciliationStateCodec.decode(
      sessionId: sessionId,
      ledgerJson: validated.before.ledgerJson,
      knowledgeJson: validated.before.knowledgeJson,
    );
    final beforeCanon = await _canonAuthority
        .loadReadOnlyFromReconciliationState(
          sessionId: sessionId,
          sourceCharacter: currentCanon.source,
          ledgerTrackers: decoded.trackers,
          knowledgeFacts: decoded.knowledgeFacts,
        );
    final beforeContext = beforeCanon.context;
    if (beforeContext.stamp.identity != head.effectiveCanonStamp ||
        beforeContext.effectiveRevision.number != head.effectiveCanonRevision ||
        beforeContext.effectiveRevision.hash != head.effectiveCanonHash) {
      return const LedgerReplacementBasisFailure(
        'The saved before-state no longer matches the commit canon',
      );
    }
    final endpointSnapshot = await _snapshotRepo.getByAnchor(
      sessionId: sessionId,
      messageId: plan.endMessage.id,
      swipeId: plan.endMessage.swipeId,
      agentSwipeId: plan.endMessage.agentSwipeId,
    );
    if (endpointSnapshot == null || !endpointSnapshot.committed) {
      return const LedgerReplacementBasisFailure(
        'The reconciliation endpoint snapshot is not committed',
      );
    }
    return LedgerReplacementBasisReady(
      head: head,
      effect: validated,
      plan: plan,
      beforeCanon: beforeCanon,
      currentCanon: currentCanon,
    );
  }

  Future<bool> isReconciliationBasisCurrent({
    required String sessionId,
    required LedgerCanonContext canon,
    required LedgerReplacementBasisReady? replacement,
  }) async {
    if (replacement == null) {
      return _canonAuthority.isStillCurrent(sessionId, canon);
    }
    return replacementBasisStillCurrent(replacement);
  }

  Future<bool> replacementBasisStillCurrent(
    LedgerReplacementBasisReady basis,
  ) async {
    final head = await _reconciliationRunRepo.getHead(basis.head.sessionId);
    final snapshot = await _snapshotRepo.getByAnchor(
      sessionId: basis.head.sessionId,
      messageId: basis.plan.endMessage.id,
      swipeId: basis.plan.endMessage.swipeId,
      agentSwipeId: basis.plan.endMessage.agentSwipeId,
    );
    return head?.id == basis.head.id &&
        head?.chainHash == basis.head.chainHash &&
        snapshot?.committed == true &&
        await _reconciliationRunRepo.currentStateMatches(
          basis.head.sessionId,
          basis.effect.after,
        ) &&
        await _canonAuthority.isStillCurrent(
          basis.head.sessionId,
          basis.currentCanon,
        );
  }

  Future<void> throwIfReplacementStale(
    LedgerReplacementBasisReady basis, {
    required CancelToken token,
    required FutureOr<bool> Function()? isStillCurrent,
  }) async {
    if (token.isCancelled ||
        await _canonAuthority.passesCurrentnessGuard(isStillCurrent) == false ||
        !await replacementBasisStillCurrent(basis)) {
      throw const LedgerCommitStale();
    }
    final messages = await _reconciliationRunRepo.reconstructSelectedMessages(
      basis.head,
    );
    final checkpoint = await _reconciliationCheckpointRepo.get(
      basis.head.sessionId,
    );
    if (messages == null || !_checkpointMatchesPlan(checkpoint, basis.plan)) {
      throw const LedgerCommitStale();
    }
    final validated = await _reconciliationRunRepo.validateEffect(basis.head);
    if (validated is! ReconciliationEffectValid ||
        validated.before.hash != basis.effect.before.hash ||
        validated.after.hash != basis.effect.after.hash ||
        await _replacementRepo.hasAppliedDependency(
          sessionId: basis.head.sessionId,
          reconciliationRunId: basis.head.id,
        )) {
      throw const LedgerCommitStale();
    }
  }

  bool _checkpointMatchesPlan(
    LedgerReconciliationCheckpoint? checkpoint,
    LedgerReconciliationPlan plan,
  ) {
    if (checkpoint == null ||
        checkpoint.startMessageId != plan.startMessageId ||
        checkpoint.endMessageId != plan.endMessage.id ||
        checkpoint.endSwipeId != plan.endMessage.swipeId ||
        checkpoint.endAgentSwipeId != plan.endMessage.agentSwipeId ||
        checkpoint.rangeHash != plan.rangeHash ||
        checkpoint.messageIds.length != plan.messageIds.length) {
      return false;
    }
    for (var i = 0; i < checkpoint.messageIds.length; i++) {
      if (checkpoint.messageIds[i] != plan.messageIds[i]) return false;
    }
    return true;
  }
}

sealed class LedgerReplacementBasis {
  const LedgerReplacementBasis();
}

final class LedgerReplacementBasisReady extends LedgerReplacementBasis {
  const LedgerReplacementBasisReady({
    required this.head,
    required this.effect,
    required this.plan,
    required this.beforeCanon,
    required this.currentCanon,
  });

  final LedgerReconciliationSuccessfulRunRow head;
  final ReconciliationEffectValid effect;
  final LedgerReconciliationPlan plan;
  final LedgerCanonContext beforeCanon;
  final LedgerCanonContext currentCanon;
}

final class LedgerReplacementBasisFailure extends LedgerReplacementBasis {
  const LedgerReplacementBasisFailure(this.reason);

  final String reason;
}
