import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/db_provider.dart';
import '../../models/ledger_raw_tracker_state.dart';
import '../../models/tracker.dart';

export '../../models/ledger_raw_tracker_state.dart';

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

  /// Snapshot-first raw state for fencing. Manual controls intentionally remain
  /// separate so the pure resolver, rather than this compatibility adapter,
  /// decides their precedence.
  Future<LedgerRawTrackerState> loadRawLedgerState(String sessionId) async {
    final trackerRepo = _ref.read(trackerRepoProvider);
    final snapshot = await _ref
        .read(trackerSnapshotRepoProvider)
        .getLatestCommitted(sessionId);
    final liveLedger = await trackerRepo.getBySessionAndScope(
      sessionId,
      'ledger',
    );
    return LedgerRawTrackerState(
      committedTrackers:
          snapshot?.trackers
              .where((tracker) => tracker.scope == 'ledger')
              .toList(growable: false) ??
          const [],
      manualControls: liveLedger
          .where(
            (tracker) =>
                tracker.name.startsWith('canon_override:') ||
                tracker.name.startsWith('canon_lock:'),
          )
          .toList(growable: false),
    );
  }

  Future<List<Tracker>> loadEffectiveLedgerTrackers(String sessionId) async {
    final state = await loadRawLedgerState(sessionId);

    final byName = <String, Tracker>{
      for (final tracker in state.committedTrackers) tracker.name: tracker,
    };

    // Manual overrides/locks are user-owned and can be newer than the latest
    // committed model snapshot. Keep them authoritative without admitting
    // uncommitted model-written rows from tracker_rows. Materialize overrides
    // at their canonical key as well: the Studio Ledger prompt only consumes
    // canonical ledger keys, while the session-state compiler also recognizes
    // the original override row.
    for (final tracker in state.manualControls) {
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
