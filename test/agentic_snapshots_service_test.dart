import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/features/chat/services/agentic_snapshots_service.dart';

void main() {
  late AppDatabase db;
  late TrackerSnapshotRepo snapshotRepo;
  late ChatRepo chatRepo;
  late AgenticSnapshotsService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    snapshotRepo = TrackerSnapshotRepo(db);
    chatRepo = ChatRepo(db);
    service = AgenticSnapshotsService(snapshotRepo, chatRepo);
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
    await chatRepo.put(
      const ChatSession(
        id: 'session',
        characterId: 'character',
        sessionIndex: 0,
        messages: [
          ChatMessage(id: 'first', role: 'assistant', content: 'First'),
          ChatMessage(id: 'user', role: 'user', content: 'User'),
          ChatMessage(id: 'message', role: 'assistant', content: 'Second'),
        ],
      ),
    );
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
      snapshots
          .singleWhere((item) => item.snapshot.agentSwipeId == 0)
          .snapshot
          .committed,
      isFalse,
    );
    expect(
      snapshots
          .singleWhere((item) => item.snapshot.agentSwipeId == 1)
          .snapshot
          .committed,
      isFalse,
    );
    expect(snapshots.map((item) => item.startMessageNumber), everyElement(1));
    expect(snapshots.map((item) => item.endMessageNumber), everyElement(3));
  });
}
