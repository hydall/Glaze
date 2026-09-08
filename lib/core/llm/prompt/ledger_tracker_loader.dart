import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/db_provider.dart';
import '../../models/tracker.dart';

/// Loads effective Studio Ledger tracker rows for a session.
///
/// Merges the latest committed snapshot with live manual overrides/locks from
/// `tracker_rows`. Snapshot rows are authoritative for model-written state;
/// without a committed snapshot, only live manual controls are effective.
/// Live `canon_override:*` and `canon_lock:*` rows are user-owned and can be
/// newer than the snapshot, so they always win.
///
/// See docs/rules/database.md (INV-TS3: snapshot-first read path).
class LedgerTrackerLoader {
  final Ref _ref;

  LedgerTrackerLoader(this._ref);

  Future<List<Tracker>> loadEffectiveLedgerTrackers(String sessionId) async {
    final trackerRepo = _ref.read(trackerRepoProvider);
    final snapshot = await _ref
        .read(trackerSnapshotRepoProvider)
        .getLatestCommitted(sessionId);
    final liveLedger = await trackerRepo.getBySessionAndScope(
      sessionId,
      'ledger',
    );

    final byName = <String, Tracker>{
      if (snapshot != null)
        for (final tracker in snapshot.trackers)
          if (tracker.scope == 'ledger') tracker.name: tracker,
    };

    // Manual overrides/locks are user-owned and can be newer than the latest
    // committed model snapshot. Keep them authoritative without admitting
    // uncommitted model-written rows from tracker_rows. Materialize overrides
    // at their canonical key as well: the Studio Ledger prompt only consumes
    // canonical ledger keys, while the session-state compiler also recognizes
    // the original override row.
    for (final tracker in liveLedger) {
      if (tracker.name.startsWith('canon_override:')) {
        final overriddenName = tracker.name.substring('canon_override:'.length);
        byName[tracker.name] = tracker;
        byName[overriddenName] = tracker.copyWith(name: overriddenName);
      } else if (tracker.name.startsWith('canon_lock:')) {
        byName[tracker.name] = tracker;
      }
    }

    return byName.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }
}
