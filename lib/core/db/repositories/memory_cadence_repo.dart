import 'package:drift/drift.dart';

import '../../models/memory_graph.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';

class MemoryCadenceRepo {
  final AppDatabase db;

  const MemoryCadenceRepo(this.db);

  Future<MemoryCadence> get(String sessionId) async {
    final row = await (db.select(db.memoryCadenceRows)
          ..where((row) => row.chatSessionId.equals(sessionId)))
        .getSingleOrNull();
    if (row != null) {
      return MemoryCadence(
        chatSessionId: row.chatSessionId,
        assistantMessagesSinceLastRun: row.assistantMessagesSinceLastRun,
        lastRunMessageIndex: row.lastRunMessageIndex,
        lastRunAt: row.lastRunAt,
        lastRunKind: row.lastRunKind,
      );
    }
    final fresh = MemoryCadence(chatSessionId: sessionId);
    await _upsert(fresh);
    return fresh;
  }

  Future<void> incrementAssistant(String sessionId) async {
    final current = await get(sessionId);
    await _upsert(MemoryCadence(
      chatSessionId: sessionId,
      assistantMessagesSinceLastRun: current.assistantMessagesSinceLastRun + 1,
      lastRunMessageIndex: current.lastRunMessageIndex,
      lastRunAt: current.lastRunAt,
      lastRunKind: current.lastRunKind,
    ));
  }

  Future<void> reset(String sessionId, String kind) {
    return _upsert(MemoryCadence(
      chatSessionId: sessionId,
      assistantMessagesSinceLastRun: 0,
      lastRunMessageIndex: 0,
      lastRunAt: currentTimestampSeconds(),
      lastRunKind: kind,
    ));
  }

  Future<bool> shouldRun(
    String sessionId,
    String kind,
    int interval,
  ) async {
    final current = await get(sessionId);
    return current.assistantMessagesSinceLastRun >= interval;
  }

  Future<void> _upsert(MemoryCadence cadence) {
    return db.into(db.memoryCadenceRows).insertOnConflictUpdate(
      MemoryCadenceRowsCompanion.insert(
        chatSessionId: cadence.chatSessionId,
        assistantMessagesSinceLastRun:
            Value(cadence.assistantMessagesSinceLastRun),
        lastRunMessageIndex: Value(cadence.lastRunMessageIndex),
        lastRunAt: Value(cadence.lastRunAt),
        lastRunKind: Value(cadence.lastRunKind),
      ),
    );
  }
}
