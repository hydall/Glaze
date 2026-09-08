import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/tracker_repo.dart';
import '../../../core/db/repositories/tracker_snapshot_repo.dart';
import '../../../core/models/tracker_snapshot.dart';
import '../../../core/state/db_provider.dart';

final agenticSnapshotsServiceProvider = Provider<AgenticSnapshotsService>((
  ref,
) {
  return AgenticSnapshotsService(
    ref.watch(trackerSnapshotRepoProvider),
    ref.watch(trackerRepoProvider),
  );
});

class AgenticSnapshotRollbackResult {
  const AgenticSnapshotRollbackResult({
    required this.deletedMessageId,
    required this.fallbackMessageId,
  });

  final String deletedMessageId;
  final String? fallbackMessageId;
}

class AgenticSnapshotsService {
  const AgenticSnapshotsService(this._snapshotRepo, this._trackerRepo);

  final TrackerSnapshotRepo _snapshotRepo;
  final TrackerRepo _trackerRepo;

  Future<List<TrackerSnapshot>> loadSnapshots(String sessionId) {
    return _snapshotRepo.getBySessionId(sessionId);
  }

  Future<void> commitSnapshot({
    required String sessionId,
    required TrackerSnapshot snapshot,
  }) {
    return _snapshotRepo.commit(
      sessionId: sessionId,
      messageId: snapshot.messageId,
      swipeId: snapshot.swipeId,
      agentSwipeId: snapshot.agentSwipeId,
    );
  }

  Future<AgenticSnapshotRollbackResult> rollback({
    required String sessionId,
    required String messageId,
  }) async {
    await _snapshotRepo.deleteForMessage(sessionId, messageId);
    final fallback = await _snapshotRepo.getLatestCommitted(sessionId);
    if (fallback != null) {
      await _trackerRepo.replaceForSession(sessionId, fallback.trackers);
    }
    return AgenticSnapshotRollbackResult(
      deletedMessageId: messageId,
      fallbackMessageId: fallback?.messageId,
    );
  }
}
