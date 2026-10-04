import 'tracker.dart';

/// Snapshot-first Ledger state with live, user-owned canon controls kept
/// separate from the committed model state.
final class LedgerRawTrackerState {
  LedgerRawTrackerState({
    required Iterable<Tracker> committedTrackers,
    required Iterable<Tracker> manualControls,
  }) : committedTrackers = List.unmodifiable(committedTrackers),
       manualControls = List.unmodifiable(manualControls);

  final List<Tracker> committedTrackers;
  final List<Tracker> manualControls;
}
