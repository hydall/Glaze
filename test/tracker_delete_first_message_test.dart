import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/models/tracker.dart';

AppDatabase _testDb() => AppDatabase.forTesting(NativeDatabase.memory());

Tracker _tracker({
  required String sessionId,
  required String name,
  String value = 'v',
}) {
  return Tracker(
    sessionId: sessionId,
    name: name,
    value: value,
    scope: 'chat',
    provenance: 'memory_agent:msg_1',
  );
}

/// Characterization test for the "first message deletion" scenario fixed in
/// `chat_message_service.deleteMessage`:
///
/// 1. First user message → agent writes trackers to `tracker_rows` + an
///    UNCOMMITTED snapshot (commit happens only on the next user turn via
///    `chat_provider.commitLatest`).
/// 2. User deletes that message before sending a second one.
/// 3. `deleteForMessage` removes the only (uncommitted) snapshot.
/// 4. `getLatestCommitted` returns null.
/// 5. FIX: `trackerRepo.clearForSession` must be called — otherwise the
///    trackers persist in `tracker_rows` forever (UI falls back to
///    `trackerRepo.getBySessionId` when no snapshot exists).
///
/// This test reproduces the repo-level sequence the service runs and asserts
/// the fix: after the sequence, `tracker_rows` is empty.
void main() {
  late AppDatabase db;
  late TrackerRepo trackerRepo;
  late TrackerSnapshotRepo snapshotRepo;

  setUp(() {
    db = _testDb();
    trackerRepo = TrackerRepo(db);
    snapshotRepo = TrackerSnapshotRepo(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('first-message deletion: clearForSession when no committed snapshot',
      () async {
    const sessionId = 's1';
    const messageId = 'msg_1';

    // 1. Agent writes trackers + uncommitted snapshot (first message).
    await trackerRepo.upsert(_tracker(sessionId: sessionId, name: 'mood', value: 'happy'));
    await snapshotRepo.upsertTrackers(
      sessionId: sessionId,
      messageId: messageId,
      swipeId: 0,
      agentSwipeId: 0,
      trackers: [_tracker(sessionId: sessionId, name: 'mood', value: 'happy')],
      committed: false,
    );

    // Sanity: tracker_rows has the written value.
    expect((await trackerRepo.getBySessionId(sessionId)).length, 1);
    // Sanity: no committed snapshot exists yet.
    expect(await snapshotRepo.getLatestCommitted(sessionId), isNull);

    // 2. User deletes the message: deleteForMessage + getLatestCommitted.
    await snapshotRepo.deleteForMessage(sessionId, messageId);
    final latest = await snapshotRepo.getLatestCommitted(sessionId);

    // 3. BUG (pre-fix): snapshot is null → service skipped replaceForSession
    //    → tracker_rows retained the orphan. FIX: clearForSession.
    if (latest == null) {
      await trackerRepo.clearForSession(sessionId);
    } else {
      await trackerRepo.replaceForSession(sessionId, latest.trackers);
    }

    // 4. After the fix: tracker_rows is empty.
    expect(await trackerRepo.getBySessionId(sessionId), isEmpty);
    // And no snapshots remain.
    expect(await snapshotRepo.getLatest(sessionId), isNull);
  });

  test('second-message deletion: replaceForSession rolls back to first',
      () async {
    const sessionId = 's1';

    // First message: trackers + COMMITTED snapshot (user sent a follow-up).
    await snapshotRepo.upsertTrackers(
      sessionId: sessionId,
      messageId: 'msg_1',
      swipeId: 0,
      agentSwipeId: 0,
      trackers: [_tracker(sessionId: sessionId, name: 'mood', value: 'calm')],
      committed: true,
    );
    // Second message: more trackers, uncommitted snapshot.
    await trackerRepo.upsert(_tracker(sessionId: sessionId, name: 'mood', value: 'tense'));
    await snapshotRepo.upsertTrackers(
      sessionId: sessionId,
      messageId: 'msg_2',
      swipeId: 0,
      agentSwipeId: 0,
      trackers: [_tracker(sessionId: sessionId, name: 'mood', value: 'tense')],
      committed: false,
    );

    // Delete the second message.
    await snapshotRepo.deleteForMessage(sessionId, 'msg_2');
    final latest = await snapshotRepo.getLatestCommitted(sessionId);

    // A committed snapshot exists (msg_1) → roll back to it.
    expect(latest, isNotNull);
    expect(latest!.trackers.first.value, 'calm');
    await trackerRepo.replaceForSession(sessionId, latest.trackers);

    // tracker_rows reflects the rolled-back (first-message) state.
    final rows = await trackerRepo.getBySessionId(sessionId);
    expect(rows.length, 1);
    expect(rows.first.name, 'mood');
    expect(rows.first.value, 'calm');
  });
}
