import 'dart:convert';

import 'package:drift/drift.dart';

import '../../models/tracker.dart';
import '../../models/tracker_snapshot.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';

/// Repository for the `tracker_snapshots` table.
///
/// Stores immutable per-(message, swipe, agent-swipe) tracker-state snapshots.
/// The storage model is the core of the rollback design (mirrors
/// Marinara-Engine's `game_state_snapshots`):
///
/// - **Write**: each generation/clean writes a snapshot for its anchor
///   `(messageId, swipeId, agentSwipeId)`. Re-runs replace (dedupe by PK).
/// - **Read**: `getLatestCommitted(sessionId)` returns the most recent
///   `committed=1` snapshot; `getByAnchor` returns the exact anchor's snapshot.
///   `getLatestExcludingMessage` skips a regenerating message's rows.
/// - **Rollback**: delete a message's rows (`deleteForMessage`) — the previous
///   committed snapshot becomes "latest" by definition. No explicit restore.
/// - **Branch**: `copyForSessionBranch` re-keys the sliced message range into
///   a new `sessionId`, preserving `(messageId, swipeId, agentSwipeId)` so
///   anchors stay aligned (messages are not re-id'd on branch).
class TrackerSnapshotRepo {
  final AppDatabase db;

  const TrackerSnapshotRepo(this.db);

  /// Upsert a snapshot for the anchor `(sessionId, messageId, swipeId,
  /// agentSwipeId)`. Re-runs replace the prior snapshot for the same anchor
  /// (dedupe by PK) so duplicates never accumulate.
  Future<void> upsert(TrackerSnapshot snapshot) {
    final now = snapshot.createdAt == 0
        ? currentTimestampSeconds()
        : snapshot.createdAt;
    return db
        .into(db.trackerSnapshots)
        .insertOnConflictUpdate(
          TrackerSnapshotRow(
            sessionId: snapshot.sessionId,
            messageId: snapshot.messageId,
            swipeId: snapshot.swipeId,
            agentSwipeId: snapshot.agentSwipeId,
            trackersJson: jsonEncode(
              snapshot.trackers
                  .where((t) => t.scope != 'ledger_diagnostic')
                  .map((t) => t.toJson())
                  .toList(),
            ),
            committed: snapshot.committed ? 1 : 0,
            createdAt: now,
          ),
        );
  }

  /// Convenience: upsert from raw fields (avoids constructing a
  /// [TrackerSnapshot] at call sites that only have the tracker list).
  Future<void> upsertTrackers({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required List<Tracker> trackers,
    bool committed = false,
  }) {
    return upsert(
      TrackerSnapshot(
        sessionId: sessionId,
        messageId: messageId,
        swipeId: swipeId,
        agentSwipeId: agentSwipeId,
        trackers: trackers,
        committed: committed,
      ),
    );
  }

  /// Fetch the exact snapshot for `(sessionId, messageId, swipeId,
  /// agentSwipeId)`, or `null` if none exists. Used by the read path when
  /// navigating swipes (lazy state swap at read time).
  Future<TrackerSnapshot?> getByAnchor({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
  }) async {
    final row =
        await (db.select(db.trackerSnapshots)
              ..where((t) => t.sessionId.equals(sessionId))
              ..where((t) => t.messageId.equals(messageId))
              ..where((t) => t.swipeId.equals(swipeId))
              ..where((t) => t.agentSwipeId.equals(agentSwipeId)))
            .getSingleOrNull();
    return row == null ? null : _rowToModel(row);
  }

  /// Fetch the latest committed snapshot for [sessionId] (the accepted state
  /// the next generation should build on). Returns `null` if there are no
  /// committed snapshots (e.g. a brand-new session).
  Future<TrackerSnapshot?> getLatestCommitted(String sessionId) async {
    final rows =
        await (db.select(db.trackerSnapshots)
              ..where((t) => t.sessionId.equals(sessionId))
              ..where((t) => t.committed.equals(1))
              ..orderBy(_latestFirst)
              ..limit(1))
            .get();
    return rows.isEmpty ? null : _rowToModel(rows.first);
  }

  /// Fetch the latest committed snapshot for [sessionId], excluding any rows
  /// tied to [excludeMessageId]. Used during regen so the base state does not
  /// read the regenerating message's own (stale) snapshot.
  Future<TrackerSnapshot?> getLatestCommittedExcludingMessage(
    String sessionId,
    String excludeMessageId,
  ) async {
    final rows =
        await (db.select(db.trackerSnapshots)
              ..where((t) => t.sessionId.equals(sessionId))
              ..where((t) => t.committed.equals(1))
              ..where((t) => t.messageId.equals(excludeMessageId).not())
              ..orderBy(_latestFirst)
              ..limit(1))
            .get();
    return rows.isEmpty ? null : _rowToModel(rows.first);
  }

  /// Fetch the latest snapshot (committed or not) for [sessionId]. Used when
  /// the UI wants to show the most recent tracker state regardless of commit
  /// status (e.g. the "Tracker values" tab in the ops log).
  Future<TrackerSnapshot?> getLatest(String sessionId) async {
    final rows =
        await (db.select(db.trackerSnapshots)
              ..where((t) => t.sessionId.equals(sessionId))
              ..orderBy(_latestFirst)
              ..limit(1))
            .get();
    return rows.isEmpty ? null : _rowToModel(rows.first);
  }

  /// All snapshots for a session (for sync + backup + debugging).
  Future<List<TrackerSnapshot>> getBySessionId(String sessionId) {
    return (db.select(db.trackerSnapshots)
          ..where((t) => t.sessionId.equals(sessionId))
          ..orderBy(_latestFirst))
        .get()
        .then((rows) => rows.map(_rowToModel).toList());
  }

  /// All distinct session IDs that have at least one snapshot (for sync
  /// manifest building).
  Future<List<String>> getAllSessionIds() async {
    final rows = await db
        .customSelect('SELECT DISTINCT session_id FROM tracker_snapshots')
        .get();
    return rows.map((r) => r.read<String>('session_id')).toList();
  }

  /// Mark the snapshot at the anchor as committed. Called when the user sends
  /// a follow-up message — the previous assistant turn's snapshot becomes the
  /// accepted base for the next generation.
  Future<void> commit({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
  }) {
    return (db.update(db.trackerSnapshots)
          ..where((t) => t.sessionId.equals(sessionId))
          ..where((t) => t.messageId.equals(messageId))
          ..where((t) => t.swipeId.equals(swipeId))
          ..where((t) => t.agentSwipeId.equals(agentSwipeId)))
        .write(const TrackerSnapshotsCompanion(committed: Value(1)));
  }

  /// Marks and returns the latest snapshot for [sessionId] as committed.
  /// Callers that maintain another provenance-anchored store can use the exact
  /// returned anchor instead of guessing by timestamp.
  Future<TrackerSnapshot?> commitLatest(String sessionId) async {
    final latest = await getLatest(sessionId);
    if (latest == null) return null;
    await commit(
      sessionId: sessionId,
      messageId: latest.messageId,
      swipeId: latest.swipeId,
      agentSwipeId: latest.agentSwipeId,
    );
    return latest;
  }

  /// Delete all snapshots for a message (across all swipes/agent-swipes).
  /// Rollback is emergent: `getLatestCommitted` naturally falls back to the
  /// previous message's committed snapshot.
  Future<void> deleteForMessage(String sessionId, String messageId) {
    return deleteForMessages(sessionId, {messageId});
  }

  /// Deletes snapshots for multiple messages with one database statement.
  Future<void> deleteForMessages(String sessionId, Set<String> messageIds) {
    if (messageIds.isEmpty) return Future.value();
    return (db.delete(db.trackerSnapshots)
          ..where((t) => t.sessionId.equals(sessionId))
          ..where((t) => t.messageId.isIn(messageIds)))
        .go();
  }

  /// Delete one snapshot at an exact anchor (e.g. when a single agent-swipe
  /// is removed). After deletion, the read path falls back to the parent
  /// agent-swipe's snapshot (see read-path parent-fallback).
  Future<void> deleteAnchor({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
  }) {
    return (db.delete(db.trackerSnapshots)
          ..where((t) => t.sessionId.equals(sessionId))
          ..where((t) => t.messageId.equals(messageId))
          ..where((t) => t.swipeId.equals(swipeId))
          ..where((t) => t.agentSwipeId.equals(agentSwipeId)))
        .go();
  }

  Future<void> deleteSwipe({
    required String sessionId,
    required String messageId,
    required int swipeId,
  }) {
    return (db.delete(db.trackerSnapshots)
          ..where((t) => t.sessionId.equals(sessionId))
          ..where((t) => t.messageId.equals(messageId))
          ..where((t) => t.swipeId.equals(swipeId)))
        .go();
  }

  Future<void> shiftAgentSwipeIdsAfterRemoval({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int removedAgentSwipeId,
  }) async {
    final toShift =
        await (db.select(db.trackerSnapshots)
              ..where((t) => t.sessionId.equals(sessionId))
              ..where((t) => t.messageId.equals(messageId))
              ..where((t) => t.swipeId.equals(swipeId))
              ..where(
                (t) => t.agentSwipeId.isBiggerThanValue(removedAgentSwipeId),
              ))
            .get();
    toShift.sort((a, b) => a.agentSwipeId.compareTo(b.agentSwipeId));
    for (final row in toShift) {
      await (db.update(db.trackerSnapshots)
            ..where((t) => t.sessionId.equals(sessionId))
            ..where((t) => t.messageId.equals(messageId))
            ..where((t) => t.swipeId.equals(swipeId))
            ..where((t) => t.agentSwipeId.equals(row.agentSwipeId)))
          .write(
            TrackerSnapshotsCompanion(
              agentSwipeId: Value(row.agentSwipeId - 1),
            ),
          );
    }
  }

  /// Delete all snapshots for a session. Used by `deleteSession`,
  /// `clearChat`, and `deleteByCharacterId` cascades.
  Future<void> deleteBySessionId(String sessionId) {
    return (db.delete(
      db.trackerSnapshots,
    )..where((t) => t.sessionId.equals(sessionId))).go();
  }

  /// Shift `swipeId` down by 1 for all snapshots of [messageId] with
  /// `swipeId > removedSwipeId`. Mirrors Marinara's `removeSwipe` shift so
  /// anchors stay aligned with the remaining green swipes after a middle
  /// swipe is deleted. Wrap in a transaction with the swipe deletion.
  Future<void> shiftSwipeIdsAfterRemoval({
    required String sessionId,
    required String messageId,
    required int removedSwipeId,
  }) async {
    final toShift =
        await (db.select(db.trackerSnapshots)
              ..where((t) => t.sessionId.equals(sessionId))
              ..where((t) => t.messageId.equals(messageId))
              ..where((t) => t.swipeId.isBiggerThanValue(removedSwipeId)))
            .get();
    toShift.sort((a, b) => a.swipeId.compareTo(b.swipeId));
    for (final row in toShift) {
      await (db.update(db.trackerSnapshots)
            ..where((t) => t.sessionId.equals(sessionId))
            ..where((t) => t.messageId.equals(messageId))
            ..where((t) => t.swipeId.equals(row.swipeId))
            ..where((t) => t.agentSwipeId.equals(row.agentSwipeId)))
          .write(TrackerSnapshotsCompanion(swipeId: Value(row.swipeId - 1)));
    }
  }

  /// Copy all snapshots for [messageIds] from [fromSessionId] to
  /// [toSessionId], preserving `(messageId, swipeId, agentSwipeId)`. Used by
  /// `branchSession` — messages are not re-id'd on branch, so the `sessionId`
  /// prefix in the PK is what isolates each branch's snapshots (no cross-
  /// session aliasing).
  Future<void> copyForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
    required Set<String> messageIds,
  }) async {
    if (messageIds.isEmpty) return;
    final rows =
        await (db.select(db.trackerSnapshots)
              ..where((t) => t.sessionId.equals(fromSessionId))
              ..where((t) => t.messageId.isIn(messageIds)))
            .get();
    if (rows.isEmpty) return;
    await db.batch((batch) {
      for (final row in rows) {
        batch.insert(
          db.trackerSnapshots,
          TrackerSnapshotsCompanion.insert(
            sessionId: toSessionId,
            messageId: row.messageId,
            swipeId: Value(row.swipeId),
            agentSwipeId: Value(row.agentSwipeId),
            trackersJson: Value(
              jsonEncode(
                _rowToModel(row).trackers
                    .map((tracker) => tracker.copyWith(sessionId: toSessionId))
                    .toList(),
              ),
            ),
            committed: Value(row.committed),
            createdAt: Value(row.createdAt),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  TrackerSnapshot _rowToModel(TrackerSnapshotRow row) {
    List<dynamic> raw;
    try {
      raw = jsonDecode(row.trackersJson) as List<dynamic>;
    } catch (_) {
      raw = const [];
    }
    final trackers = raw
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => Tracker.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    return TrackerSnapshot(
      sessionId: row.sessionId,
      messageId: row.messageId,
      swipeId: row.swipeId,
      agentSwipeId: row.agentSwipeId,
      trackers: trackers,
      committed: row.committed == 1,
      createdAt: row.createdAt,
    );
  }

  List<OrderingTerm Function($TrackerSnapshotsTable)> get _latestFirst => [
    (t) => OrderingTerm.desc(t.createdAt),
    (t) => OrderingTerm.desc(t.messageId),
    (t) => OrderingTerm.desc(t.swipeId),
    (t) => OrderingTerm.desc(t.agentSwipeId),
  ];
}
