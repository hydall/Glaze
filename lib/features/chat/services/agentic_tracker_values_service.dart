import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import '../../../core/db/repositories/tracker_repo.dart';
import '../../../core/db/repositories/tracker_snapshot_repo.dart';
import '../../../core/models/tracker.dart';
import '../../../core/state/db_provider.dart';

final agenticTrackerValuesServiceProvider =
    Provider<AgenticTrackerValuesService>((ref) {
      return AgenticTrackerValuesService(
        ref.watch(trackerRepoProvider),
        ref.watch(trackerSnapshotRepoProvider),
        ref.watch(ledgerReconciliationCheckpointRepoProvider),
      );
    });

class AgenticTrackerValuesService {
  const AgenticTrackerValuesService(
    this._trackerRepo,
    this._trackerSnapshotRepo,
    this._reconciliationCheckpointRepo,
  );

  final TrackerRepo _trackerRepo;
  final TrackerSnapshotRepo _trackerSnapshotRepo;
  final LedgerReconciliationCheckpointRepo _reconciliationCheckpointRepo;

  Future<void> purgeSession(String sessionId) async {
    await _trackerRepo.clearForSession(sessionId);
    await _trackerSnapshotRepo.deleteBySessionId(sessionId);
    await _reconciliationCheckpointRepo.deleteBySessionId(sessionId);
  }

  Future<void> editValue({
    required String sessionId,
    required Tracker tracker,
    required String value,
  }) {
    if (_isCanonControl(tracker.name)) {
      return _trackerRepo.upsertValue(
        sessionId,
        tracker.name,
        value,
        scope: tracker.scope,
        provenance: tracker.provenance,
      );
    }
    return setCanonOverride(
      sessionId: sessionId,
      trackerName: tracker.name,
      value: value,
    );
  }

  Future<void> deleteTracker({
    required String sessionId,
    required String trackerName,
  }) {
    return _trackerRepo.delete(sessionId, trackerName);
  }

  Future<void> toggleCanonLock({
    required String sessionId,
    required String trackerName,
    required bool isLocked,
  }) {
    final lockName = 'canon_lock:$trackerName';
    if (isLocked) {
      return _trackerRepo.delete(sessionId, lockName);
    }
    return _trackerRepo.upsertValue(
      sessionId,
      lockName,
      'true',
      scope: 'ledger',
      provenance: 'manual',
    );
  }

  Future<void> setCanonOverride({
    required String sessionId,
    required String trackerName,
    required String value,
  }) {
    return _trackerRepo.upsertValue(
      sessionId,
      'canon_override:$trackerName',
      value,
      scope: 'ledger',
      provenance: 'manual',
    );
  }

  Future<void> removeCanonOverride({
    required String sessionId,
    required String trackerName,
  }) {
    return _trackerRepo.delete(sessionId, 'canon_override:$trackerName');
  }

  bool _isCanonControl(String name) =>
      name.startsWith('canon_lock:') || name.startsWith('canon_override:');
}
