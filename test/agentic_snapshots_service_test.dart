import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/features/chat/services/agentic_snapshots_service.dart';

void main() {
  late AppDatabase db;
  late TrackerRepo trackerRepo;
  late TrackerSnapshotRepo snapshotRepo;
  late AgenticSnapshotsService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    trackerRepo = TrackerRepo(db);
    snapshotRepo = TrackerSnapshotRepo(db);
    service = AgenticSnapshotsService(snapshotRepo, trackerRepo);
  });

  tearDown(() => db.close());

  Tracker tracker(String sessionId, String name, String value) {
    return Tracker(
      sessionId: sessionId,
      name: name,
      value: value,
      scope: 'ledger',
      provenance: 'studio_ledger',
    );
  }

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

  test('commit marks only the requested snapshot as committed', () async {
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
    final target = (await service.loadSnapshots('session')).last;

    await service.commitSnapshot(sessionId: 'session', snapshot: target);

    final snapshots = await service.loadSnapshots('session');
    expect(
      snapshots.singleWhere((item) => item.agentSwipeId == 0).committed,
      isTrue,
    );
    expect(
      snapshots.singleWhere((item) => item.agentSwipeId == 1).committed,
      isFalse,
    );
  });

  test(
    'rollback deletes target snapshots and restores committed fallback',
    () async {
      final fallbackTracker = tracker('session', 'scene', 'fallback');
      await seedSnapshot(
        sessionId: 'session',
        messageId: 'previous',
        createdAt: 1,
        trackers: [fallbackTracker],
      );
      await seedSnapshot(
        sessionId: 'session',
        messageId: 'target',
        createdAt: 2,
        trackers: [tracker('session', 'scene', 'target-0')],
      );
      await seedSnapshot(
        sessionId: 'session',
        messageId: 'target',
        createdAt: 3,
        trackers: [tracker('session', 'scene', 'target-1')],
        agentSwipeId: 1,
      );
      await trackerRepo.upsert(tracker('session', 'scene', 'live'));

      final result = await service.rollback(
        sessionId: 'session',
        messageId: 'target',
      );

      expect(result.deletedMessageId, 'target');
      expect(result.fallbackMessageId, 'previous');
      expect(await snapshotRepo.getBySessionId('session'), hasLength(1));
      expect((await trackerRepo.get('session', 'scene'))?.value, 'fallback');
    },
  );

  test('rollback without fallback leaves live trackers unchanged', () async {
    await seedSnapshot(
      sessionId: 'session',
      messageId: 'target',
      createdAt: 1,
      trackers: [tracker('session', 'scene', 'snapshot')],
    );
    await trackerRepo.upsert(tracker('session', 'scene', 'live'));

    final result = await service.rollback(
      sessionId: 'session',
      messageId: 'target',
    );

    expect(result.deletedMessageId, 'target');
    expect(result.fallbackMessageId, isNull);
    expect(await snapshotRepo.getBySessionId('session'), isEmpty);
    expect((await trackerRepo.get('session', 'scene'))?.value, 'live');
  });

  test('rollback is isolated to the requested session', () async {
    for (final sessionId in ['target-session', 'other-session']) {
      await seedSnapshot(
        sessionId: sessionId,
        messageId: 'shared-message',
        createdAt: 1,
        trackers: [tracker(sessionId, 'scene', sessionId)],
      );
      await trackerRepo.upsert(tracker(sessionId, 'scene', sessionId));
    }

    await service.rollback(
      sessionId: 'target-session',
      messageId: 'shared-message',
    );

    expect(await snapshotRepo.getBySessionId('target-session'), isEmpty);
    expect(await snapshotRepo.getBySessionId('other-session'), hasLength(1));
    expect(
      (await trackerRepo.get('other-session', 'scene'))?.value,
      'other-session',
    );
  });
}
