import 'package:freezed_annotation/freezed_annotation.dart';

import 'tracker.dart';

part 'tracker_snapshot.freezed.dart';
part 'tracker_snapshot.g.dart';

/// Immutable tracker-state snapshot anchored at a specific
/// `(sessionId, messageId, swipeId, agentSwipeId)`.
///
/// Mirrors Marinara-Engine's `game_state_snapshots` model: each swipe of each
/// message owns its own tracker state, so rollback is emergent — delete the
/// rows for a message and the previous message's committed snapshot naturally
/// becomes "latest". The `committed` flag separates accepted state (user sent
/// a follow-up) from tentative/regen state.
@freezed
abstract class TrackerSnapshot with _$TrackerSnapshot {
  const factory TrackerSnapshot({
    required String sessionId,
    required String messageId,
    @Default(0) int swipeId,
    @Default(0) int agentSwipeId,
    @Default([]) List<Tracker> trackers,
    @Default(false) bool committed,
    @Default(0) int createdAt,
  }) = _TrackerSnapshot;

  factory TrackerSnapshot.fromJson(Map<String, dynamic> json) =>
      _$TrackerSnapshotFromJson(json);
}
