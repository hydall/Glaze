import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/features/chat/services/agentic_snapshots_service.dart';

void main() {
  late AppDatabase db;
  late TrackerSnapshotRepo snapshotRepo;
  late AgenticSnapshotsService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    snapshotRepo = TrackerSnapshotRepo(db);
    service = AgenticSnapshotsService(snapshotRepo);
  });

  tearDown(() => db.close());

  Future<void> seedSnapshot({
    required String sessionId,
    required String messageId,
    required int createdAt,
    required List<Tracker> trackers,
    bool committed = true,
    int swipeId = 0,
    int agentSwipeId = 0,
  }) {
    return snapshotRepo.upsert(
      TrackerSnapshot(
        sessionId: sessionId,
        messageId: messageId,
        swipeId: swipeId,
        agentSwipeId: agentSwipeId,
        trackers: trackers,
        committed: committed,
        createdAt: createdAt,
      ),
    );
  }

  test('loads tentative snapshots without mutating them', () async {
    await seedSnapshot(
      sessionId: 'session',
      messageId: 'message',
      createdAt: 1,
      trackers: const [],
      committed: false,
    );
    await seedSnapshot(
      sessionId: 'session',
      messageId: 'message',
      createdAt: 2,
      trackers: const [],
      committed: false,
      agentSwipeId: 1,
    );
    final snapshots = await service.loadSnapshots('session');
    expect(
      snapshots.singleWhere((item) => item.agentSwipeId == 0).committed,
      isFalse,
    );
    expect(
      snapshots.singleWhere((item) => item.agentSwipeId == 1).committed,
      isFalse,
    );
  });
}
