import '../../models/tracker.dart';
import '../app_db.dart';
import 'chat_repo.dart';
import 'session_canon_checkpoint_repo.dart';
import 'session_canon_rollback_repo.dart';
import 'tracker_repo.dart';
import 'tracker_snapshot_repo.dart';

/// Restores derived session state after cloud entities have finished applying.
class SyncSessionConsistencyRepo {
  const SyncSessionConsistencyRepo(this.db);

  final AppDatabase db;

  Future<void> reconcile(Set<String> sessionIds) async {
    for (final sessionId in sessionIds) {
      await db.transaction(() => _reconcileSession(sessionId));
    }
  }

  Future<void> _reconcileSession(String sessionId) async {
    final chat = await ChatRepo(db).getById(sessionId);
    if (chat == null) return;

    await SessionCanonRollbackRepo(db).reconcileInTransaction(
      sessionId: sessionId,
      survivingMessages: chat.messages,
    );
    final canonHash = (await SessionCanonCheckpointRepo(
      db,
    ).getLatest(sessionId))?.characterRevisionHash;

    final snapshots = TrackerSnapshotRepo(db);
    final all = await snapshots.getBySessionId(sessionId);
    final activeAnchors = {
      for (final message in chat.messages)
        (message.id, message.swipeId, message.agentSwipeId),
    };
    for (final snapshot in all) {
      final basisHashes = snapshot.trackers
          .map((tracker) => tracker.basisRevisionHash)
          .where((hash) => hash.isNotEmpty)
          .toSet();
      final matchesCanon =
          canonHash == null ||
          canonHash.isEmpty ||
          basisHashes.isEmpty ||
          (basisHashes.length == 1 && basisHashes.single == canonHash);
      if (!matchesCanon ||
          !activeAnchors.contains((
            snapshot.messageId,
            snapshot.swipeId,
            snapshot.agentSwipeId,
          ))) {
        await snapshots.deleteAnchor(
          sessionId: sessionId,
          messageId: snapshot.messageId,
          swipeId: snapshot.swipeId,
          agentSwipeId: snapshot.agentSwipeId,
        );
      }
    }

    List<Tracker> committedBase = const [];
    for (final message in chat.messages.reversed) {
      final snapshot = await snapshots.getByAnchor(
        sessionId: sessionId,
        messageId: message.id,
        swipeId: message.swipeId,
        agentSwipeId: message.agentSwipeId,
      );
      if (snapshot?.committed == true) {
        committedBase = snapshot!.trackers;
        break;
      }
    }

    final trackers = TrackerRepo(db);
    if (committedBase.isEmpty) {
      committedBase = await trackers.getInitialGameTimeSeed(sessionId);
      if (committedBase.isEmpty) {
        committedBase = await trackers.getCompleteGameTime(sessionId);
      }
    }
    await trackers.replaceLedgerState(sessionId, committedBase);
  }
}
