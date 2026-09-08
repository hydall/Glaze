import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/features/chat/services/agentic_tracker_values_service.dart';

void main() {
  late AppDatabase db;
  late TrackerRepo trackerRepo;
  late TrackerSnapshotRepo snapshotRepo;
  late LedgerReconciliationCheckpointRepo checkpointRepo;
  late AgenticTrackerValuesService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    trackerRepo = TrackerRepo(db);
    snapshotRepo = TrackerSnapshotRepo(db);
    checkpointRepo = LedgerReconciliationCheckpointRepo(db);
    service = AgenticTrackerValuesService(
      trackerRepo,
      snapshotRepo,
      checkpointRepo,
    );
  });

  tearDown(() => db.close());

  Tracker tracker(
    String sessionId,
    String name, {
    String value = 'value',
    String scope = 'ledger',
    String provenance = 'studio_ledger',
  }) {
    return Tracker(
      sessionId: sessionId,
      name: name,
      value: value,
      scope: scope,
      provenance: provenance,
    );
  }

  Future<void> seedSession(String sessionId) async {
    final seededTracker = tracker(sessionId, 'scene');
    await trackerRepo.upsert(seededTracker);
    await snapshotRepo.upsertTrackers(
      sessionId: sessionId,
      messageId: 'message-$sessionId',
      swipeId: 0,
      agentSwipeId: 0,
      trackers: [seededTracker],
      committed: true,
    );
    await checkpointRepo.upsert(
      LedgerReconciliationCheckpoint(
        sessionId: sessionId,
        startMessageId: 'start-$sessionId',
        endMessageId: 'end-$sessionId',
        endSwipeId: 0,
        endAgentSwipeId: 0,
        messageIds: ['start-$sessionId', 'end-$sessionId'],
        rangeHash: 'hash-$sessionId',
      ),
    );
  }

  test(
    'purge removes all tracker stores only for the requested session',
    () async {
      await seedSession('target');
      await seedSession('other');

      await service.purgeSession('target');

      expect(await trackerRepo.getBySessionId('target'), isEmpty);
      expect(await snapshotRepo.getBySessionId('target'), isEmpty);
      expect(await checkpointRepo.get('target'), isNull);
      expect(await trackerRepo.getBySessionId('other'), hasLength(1));
      expect(await snapshotRepo.getBySessionId('other'), hasLength(1));
      expect(await checkpointRepo.get('other'), isNotNull);
    },
  );

  test('editing a ledger tracker upserts a manual canon override', () async {
    final scene = tracker('session', 'scene', value: 'old');
    await trackerRepo.upsert(scene);

    await service.editValue(sessionId: 'session', tracker: scene, value: 'new');

    expect((await trackerRepo.get('session', 'scene'))!.value, 'old');
    final override = await trackerRepo.get('session', 'canon_override:scene');
    expect(override!.value, 'new');
    expect(override.scope, 'ledger');
    expect(override.provenance, 'manual');
  });

  test('editing a control row preserves its scope and provenance', () async {
    final control = tracker(
      'session',
      'canon_override:scene',
      value: 'old',
      scope: 'custom',
      provenance: 'existing',
    );
    await trackerRepo.upsert(control);

    await service.editValue(
      sessionId: 'session',
      tracker: control,
      value: 'new',
    );

    final edited = await trackerRepo.get('session', control.name);
    expect(edited!.value, 'new');
    expect(edited.scope, 'custom');
    expect(edited.provenance, 'existing');
  });

  test('delete removes only the named tracker', () async {
    await trackerRepo.upsert(tracker('session', 'scene'));
    await trackerRepo.upsert(tracker('session', 'relationship'));

    await service.deleteTracker(sessionId: 'session', trackerName: 'scene');

    expect(await trackerRepo.get('session', 'scene'), isNull);
    expect(await trackerRepo.get('session', 'relationship'), isNotNull);
  });

  test('toggle lock creates manual lock and removes it when locked', () async {
    await service.toggleCanonLock(
      sessionId: 'session',
      trackerName: 'scene',
      isLocked: false,
    );

    final lock = await trackerRepo.get('session', 'canon_lock:scene');
    expect(lock!.value, 'true');
    expect(lock.scope, 'ledger');
    expect(lock.provenance, 'manual');

    await service.toggleCanonLock(
      sessionId: 'session',
      trackerName: 'scene',
      isLocked: true,
    );
    expect(await trackerRepo.get('session', 'canon_lock:scene'), isNull);
  });

  test('set override upserts and remove override deletes it', () async {
    await service.setCanonOverride(
      sessionId: 'session',
      trackerName: 'scene',
      value: 'first',
    );
    await service.setCanonOverride(
      sessionId: 'session',
      trackerName: 'scene',
      value: 'second',
    );

    final override = await trackerRepo.get('session', 'canon_override:scene');
    expect(override!.value, 'second');
    expect(override.scope, 'ledger');
    expect(override.provenance, 'manual');

    await service.removeCanonOverride(
      sessionId: 'session',
      trackerName: 'scene',
    );
    expect(await trackerRepo.get('session', 'canon_override:scene'), isNull);
  });
}
