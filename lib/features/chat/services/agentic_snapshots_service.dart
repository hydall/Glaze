import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/tracker_snapshot_repo.dart';
import '../../../core/models/tracker_snapshot.dart';
import '../../../core/state/db_provider.dart';

final agenticSnapshotsServiceProvider = Provider<AgenticSnapshotsService>((
  ref,
) {
  return AgenticSnapshotsService(ref.watch(trackerSnapshotRepoProvider));
});

class AgenticSnapshotsService {
  const AgenticSnapshotsService(this._snapshotRepo);

  final TrackerSnapshotRepo _snapshotRepo;

  Future<List<TrackerSnapshot>> loadSnapshots(String sessionId) {
    return _snapshotRepo.getBySessionId(sessionId);
  }
}
