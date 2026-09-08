import 'dart:convert';

import 'package:drift/drift.dart';

import '../../utils/time_helpers.dart';
import '../app_db.dart';

class LedgerReconciliationCheckpoint {
  final String sessionId;
  final String startMessageId;
  final String endMessageId;
  final int endSwipeId;
  final int endAgentSwipeId;
  final List<String> messageIds;
  final String rangeHash;

  const LedgerReconciliationCheckpoint({
    required this.sessionId,
    required this.startMessageId,
    required this.endMessageId,
    required this.endSwipeId,
    required this.endAgentSwipeId,
    required this.messageIds,
    required this.rangeHash,
  });
}

class LedgerReconciliationCheckpointRepo {
  final AppDatabase db;

  const LedgerReconciliationCheckpointRepo(this.db);

  Future<LedgerReconciliationCheckpoint?> get(String sessionId) async {
    final row = await (db.select(
      db.ledgerReconciliationCheckpoints,
    )..where((table) => table.sessionId.equals(sessionId))).getSingleOrNull();
    if (row == null) return null;
    return LedgerReconciliationCheckpoint(
      sessionId: row.sessionId,
      startMessageId: row.startMessageId,
      endMessageId: row.endMessageId,
      endSwipeId: row.endSwipeId,
      endAgentSwipeId: row.endAgentSwipeId,
      messageIds: (jsonDecode(row.messageIdsJson) as List)
          .whereType<String>()
          .toList(growable: false),
      rangeHash: row.rangeHash,
    );
  }

  Future<void> upsert(LedgerReconciliationCheckpoint checkpoint) {
    return db
        .into(db.ledgerReconciliationCheckpoints)
        .insertOnConflictUpdate(
          LedgerReconciliationCheckpointsCompanion.insert(
            sessionId: checkpoint.sessionId,
            startMessageId: checkpoint.startMessageId,
            endMessageId: checkpoint.endMessageId,
            endSwipeId: Value(checkpoint.endSwipeId),
            endAgentSwipeId: Value(checkpoint.endAgentSwipeId),
            messageIdsJson: Value(jsonEncode(checkpoint.messageIds)),
            rangeHash: Value(checkpoint.rangeHash),
            reviewedAt: Value(currentTimestampSeconds()),
          ),
        );
  }

  Future<void> deleteForMessages(
    String sessionId,
    Set<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return;
    final checkpoint = await get(sessionId);
    if (checkpoint == null || !checkpoint.messageIds.any(messageIds.contains)) {
      return;
    }
    await deleteBySessionId(sessionId);
  }

  Future<void> deleteBySessionId(String sessionId) {
    return (db.delete(
      db.ledgerReconciliationCheckpoints,
    )..where((table) => table.sessionId.equals(sessionId))).go();
  }

  Future<void> copyForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
    required Set<String> messageIds,
  }) async {
    final checkpoint = await get(fromSessionId);
    if (checkpoint == null ||
        !messageIds.contains(checkpoint.startMessageId) ||
        !messageIds.contains(checkpoint.endMessageId) ||
        !checkpoint.messageIds.every(messageIds.contains)) {
      return;
    }
    await upsert(
      LedgerReconciliationCheckpoint(
        sessionId: toSessionId,
        startMessageId: checkpoint.startMessageId,
        endMessageId: checkpoint.endMessageId,
        endSwipeId: checkpoint.endSwipeId,
        endAgentSwipeId: checkpoint.endAgentSwipeId,
        messageIds: checkpoint.messageIds,
        rangeHash: checkpoint.rangeHash,
      ),
    );
  }
}
