import 'dart:async';

import 'package:dio/dio.dart';

import '../../db/repositories/character_knowledge_fact_repo.dart';
import '../../db/repositories/tracker_repo.dart';
import '../../db/repositories/tracker_snapshot_repo.dart';
import '../../models/character_knowledge_fact.dart';
import '../../models/knowledge_cleanup.dart';
import '../../models/studio_ledger_export.dart';
import '../../models/tracker.dart';
import 'ledger_canon_authority.dart';
import 'ledger_op_applier.dart';

class LedgerTurnCommitRequest {
  const LedgerTurnCommitRequest({
    required this.sessionId,
    required this.messageId,
    required this.swipeId,
    required this.agentSwipeId,
    required this.finalAssistantText,
    required this.canon,
    required this.promptTrackers,
    required this.export,
    required this.cleanupOps,
    required this.facts,
    required this.token,
    required this.isStillCurrent,
    required this.commitSnapshot,
  });

  final String sessionId;
  final String messageId;
  final int swipeId;
  final int agentSwipeId;
  final String finalAssistantText;
  final LedgerCanonContext canon;
  final List<Tracker> promptTrackers;
  final StudioLedgerExport export;
  final List<KnowledgeCleanupOp> cleanupOps;
  final List<CharacterKnowledgeFact> facts;
  final CancelToken token;
  final FutureOr<bool> Function()? isStillCurrent;
  final bool commitSnapshot;
}

class LedgerTurnCommitter {
  factory LedgerTurnCommitter({
    required TrackerRepo trackerRepo,
    required TrackerSnapshotRepo snapshotRepo,
    required CharacterKnowledgeFactRepo knowledgeFactRepo,
    required LedgerCanonAuthority canonAuthority,
    LedgerOpApplier opApplier = const LedgerOpApplier(),
  }) => LedgerTurnCommitter._(
    trackerRepo,
    snapshotRepo,
    knowledgeFactRepo,
    canonAuthority,
    opApplier,
  );

  const LedgerTurnCommitter._(
    this._trackerRepo,
    this._snapshotRepo,
    this._knowledgeFactRepo,
    this._canonAuthority,
    this._opApplier,
  );

  final TrackerRepo _trackerRepo;
  final TrackerSnapshotRepo _snapshotRepo;
  final CharacterKnowledgeFactRepo _knowledgeFactRepo;
  final LedgerCanonAuthority _canonAuthority;
  final LedgerOpApplier _opApplier;

  Future<int> commit(LedgerTurnCommitRequest request) async {
    var opsApplied = 0;
    final target = LedgerTarget(
      messageId: request.messageId,
      swipeId: request.swipeId,
      agentSwipeId: request.agentSwipeId,
      content: request.finalAssistantText,
    );
    await _trackerRepo.db.transaction(() async {
      await _canonAuthority.throwIfCommitStale(
        sessionId: request.sessionId,
        canon: request.canon,
        token: request.token,
        isStillCurrent: request.isStillCurrent,
        target: target,
      );
      // Rebuild model-owned state from committed canon before this patch.
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
          checkCanon: false,
        );
        await _opApplier.applyOp(
          op: op,
          sessionId: request.sessionId,
          messageId: request.messageId,
          swipeId: request.swipeId,
          agentSwipeId: request.agentSwipeId,
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
        checkCanon: false,
      );
      await _knowledgeFactRepo.replaceTentativeAnchor(
        sessionId: request.sessionId,
        messageId: request.messageId,
        swipeId: request.swipeId,
        agentSwipeId: request.agentSwipeId,
        facts: request.facts,
      );
      if (request.cleanupOps.isNotEmpty) {
        await _canonAuthority.throwIfCommitStale(
          sessionId: request.sessionId,
          canon: request.canon,
          token: request.token,
          isStillCurrent: request.isStillCurrent,
          target: target,
          checkCanon: false,
        );
        opsApplied += await _knowledgeFactRepo.applyReconciliationCleanup(
          sessionId: request.sessionId,
          ops: request.cleanupOps,
          endpointMessageId: null,
        );
      }
      await _canonAuthority.throwIfCommitStale(
        sessionId: request.sessionId,
        canon: request.canon,
        token: request.token,
        isStillCurrent: request.isStillCurrent,
        target: target,
        checkCanon: false,
      );
      final updatedTrackers = await _trackerRepo.getBySessionId(
        request.sessionId,
      );
      await _snapshotRepo.upsertTrackers(
        sessionId: request.sessionId,
        messageId: request.messageId,
        swipeId: request.swipeId,
        agentSwipeId: request.agentSwipeId,
        trackers: updatedTrackers,
        committed: request.commitSnapshot,
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
    return opsApplied;
  }
}
