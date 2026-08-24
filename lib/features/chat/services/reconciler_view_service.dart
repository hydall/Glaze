import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_db.dart';
import '../../../core/db/repositories/chat_repo.dart';
import '../../../core/db/repositories/ledger_debug_run_repo.dart';
import '../../../core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import '../../../core/db/repositories/ledger_reconciliation_run_repo.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/state/db_provider.dart';

enum ReconciliationRunViewStatus { current, invalidated, stale, chainCorrupt }

final class ReconciliationRunView {
  const ReconciliationRunView({
    required this.row,
    required this.messageIds,
    required this.firstMessageOrdinal,
    required this.lastMessageOrdinal,
    required this.status,
    required this.invalidation,
    required this.effect,
  });

  final LedgerReconciliationSuccessfulRunRow row;
  final List<String> messageIds;
  final int? firstMessageOrdinal;
  final int? lastMessageOrdinal;
  final ReconciliationRunViewStatus status;
  final LedgerReconciliationRunInvalidationRow? invalidation;
  final LedgerReconciliationEffectRow? effect;

  bool get isCurrent => status == ReconciliationRunViewStatus.current;

  List<String> get approximateOperations {
    try {
      final decoded = jsonDecode(row.opsAppliedJson);
      return decoded is List
          ? decoded.whereType<String>().toList(growable: false)
          : const [];
    } catch (_) {
      return const [];
    }
  }
}

final class ReconcilerViewSnapshot {
  const ReconcilerViewSnapshot({
    required this.integrity,
    required this.runs,
    required this.debugRuns,
    required this.checkpoint,
  });

  final ReconciliationRunIntegrity integrity;
  final List<ReconciliationRunView> runs;
  final List<LedgerDebugRunRow> debugRuns;
  final LedgerReconciliationCheckpoint? checkpoint;

  bool get chainIsValid => integrity is ReconciliationRunValid;
}

class ReconcilerViewService {
  const ReconcilerViewService({
    required LedgerReconciliationRunRepo runRepo,
    required LedgerDebugRunRepo debugRepo,
    required LedgerReconciliationCheckpointRepo checkpointRepo,
    required ChatRepo chatRepo,
  }) : this._(runRepo, debugRepo, checkpointRepo, chatRepo);

  const ReconcilerViewService._(
    this._runRepo,
    this._debugRepo,
    this._checkpointRepo,
    this._chatRepo,
  );

  final LedgerReconciliationRunRepo _runRepo;
  final LedgerDebugRunRepo _debugRepo;
  final LedgerReconciliationCheckpointRepo _checkpointRepo;
  final ChatRepo _chatRepo;

  Future<ReconcilerViewSnapshot> load(String sessionId) async {
    final values = await Future.wait<Object?>([
      _runRepo.readPhysicalSession(sessionId),
      _runRepo.readSession(sessionId),
      _runRepo.readInvalidations(sessionId),
      _runRepo.validateChain(sessionId),
      _debugRepo.recentForSession(sessionId, limit: 50),
      _checkpointRepo.get(sessionId),
      _chatRepo.getById(sessionId),
      _runRepo.readEffects(sessionId),
    ]);
    final physical = values[0] as List<LedgerReconciliationSuccessfulRunRow>;
    final logical = values[1] as List<LedgerReconciliationSuccessfulRunRow>;
    final invalidations =
        values[2] as List<LedgerReconciliationRunInvalidationRow>;
    final integrity = values[3] as ReconciliationRunIntegrity;
    final debugRows = (values[4] as List<LedgerDebugRunRow>)
        .where((row) => row.kind == LedgerDebugRunKind.reconciliation.name)
        .toList(growable: false);
    final checkpoint = values[5] as LedgerReconciliationCheckpoint?;
    final session = values[6] as ChatSession?;
    final effects = {
      for (final effect in values[7] as List<LedgerReconciliationEffectRow>)
        effect.runId: effect,
    };
    final messageOrdinals = <String, int>{
      if (session != null)
        for (final entry in session.messages.indexed) entry.$2.id: entry.$1 + 1,
    };
    final logicalIds = logical.map((row) => row.id).toSet();
    final invalidationByRun = {for (final row in invalidations) row.runId: row};

    return ReconcilerViewSnapshot(
      integrity: integrity,
      checkpoint: checkpoint,
      debugRuns: debugRows,
      runs: [
        for (final row in physical)
          _toRunView(
            row,
            messageOrdinals: messageOrdinals,
            logicalIds: logicalIds,
            invalidation: invalidationByRun[row.id],
            chainIsValid: integrity is ReconciliationRunValid,
            effect: effects[row.id],
          ),
      ],
    );
  }

  ReconciliationRunView _toRunView(
    LedgerReconciliationSuccessfulRunRow row, {
    required Map<String, int> messageOrdinals,
    required Set<String> logicalIds,
    required LedgerReconciliationRunInvalidationRow? invalidation,
    required bool chainIsValid,
    required LedgerReconciliationEffectRow? effect,
  }) {
    final messageIds = _decodeMessageIds(row.anchorsJson);
    final ordinals = messageIds
        .map((id) => messageOrdinals[id])
        .whereType<int>()
        .toList(growable: false);
    final hasCompleteOrdinals =
        ordinals.length == messageIds.length && ordinals.isNotEmpty;
    final status = !chainIsValid
        ? ReconciliationRunViewStatus.chainCorrupt
        : invalidation != null
        ? ReconciliationRunViewStatus.invalidated
        : logicalIds.contains(row.id)
        ? ReconciliationRunViewStatus.current
        : ReconciliationRunViewStatus.stale;
    return ReconciliationRunView(
      row: row,
      messageIds: messageIds,
      firstMessageOrdinal: hasCompleteOrdinals ? ordinals.first : null,
      lastMessageOrdinal: hasCompleteOrdinals ? ordinals.last : null,
      status: status,
      invalidation: invalidation,
      effect: effect,
    );
  }

  List<String> _decodeMessageIds(String anchorsJson) {
    try {
      final decoded = jsonDecode(anchorsJson);
      if (decoded is! List) return const [];
      return [
        for (final anchor in decoded)
          if (anchor is Map && anchor['messageId'] is String)
            anchor['messageId'] as String,
      ];
    } catch (_) {
      return const [];
    }
  }
}

final reconcilerViewServiceProvider = Provider<ReconcilerViewService>((ref) {
  return ReconcilerViewService(
    runRepo: ref.watch(ledgerReconciliationRunRepoProvider),
    debugRepo: ref.watch(ledgerDebugRunRepoProvider),
    checkpointRepo: ref.watch(ledgerReconciliationCheckpointRepoProvider),
    chatRepo: ref.watch(chatRepoProvider),
  );
});

final reconcilerViewProvider =
    FutureProvider.family<ReconcilerViewSnapshot, String>((ref, sessionId) {
      return ref.watch(reconcilerViewServiceProvider).load(sessionId);
    });
