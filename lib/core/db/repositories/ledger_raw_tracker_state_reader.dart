import '../../models/ledger_raw_tracker_state.dart';
import '../../models/tracker.dart';
import '../app_db.dart';
import 'tracker_repo.dart';
import 'tracker_snapshot_repo.dart';

/// Ref-free snapshot-first Ledger reader for transaction-fenced canon reads.
///
/// It opens no transaction itself. Calls made inside an existing
/// [AppDatabase.transaction] use that transaction's database connection.
final class LedgerRawTrackerStateReader {
  LedgerRawTrackerStateReader(this.db)
    : _trackers = TrackerRepo(db),
      _snapshots = TrackerSnapshotRepo(db);

  final AppDatabase db;
  final TrackerRepo _trackers;
  final TrackerSnapshotRepo _snapshots;

  Future<LedgerRawTrackerState> read(String sessionId) async {
    final snapshot = await _snapshots.getLatestCommitted(sessionId);
    final controls = await _trackers.getLiveCanonControls(sessionId);
    final committed = snapshot?.trackers
        .where((tracker) => tracker.scope == 'ledger')
        .toList(growable: true);
    if (committed != null) {
      final names = committed.map((tracker) => tracker.name).toSet();
      final liveClock = await _trackers.getCompleteGameTime(sessionId);
      committed.addAll(
        liveClock.where((tracker) => !names.contains(tracker.name)),
      );
    }
    final bootstrap = snapshot == null
        ? await _trackers.getInitialGameTimeSeed(sessionId)
        : const <Tracker>[];
    return LedgerRawTrackerState(
      committedTrackers: committed ?? bootstrap,
      manualControls: controls,
    );
  }
}
