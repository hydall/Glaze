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

  test('sorts by chat range and keeps endpoint variants adjacent', () async {
    await chatRepo.put(
      const ChatSession(
        id: 'session',
        characterId: 'character',
        sessionIndex: 0,
        messages: [
          ChatMessage(id: 'a1', role: 'assistant', content: 'A1'),
          ChatMessage(id: 'u2', role: 'user', content: 'U2'),
          ChatMessage(id: 'a3', role: 'assistant', content: 'A3'),
          ChatMessage(id: 'u4', role: 'user', content: 'U4'),
          ChatMessage(id: 'a5', role: 'assistant', content: 'A5'),
          ChatMessage(id: 'u6', role: 'user', content: 'U6'),
          ChatMessage(id: 'a7', role: 'assistant', content: 'A7'),
        ],
      ),
    );
    await seedSnapshot(
      sessionId: 'session',
      messageId: 'a5',
      createdAt: 100,
      trackers: const [],
    );
    await seedSnapshot(
      sessionId: 'session',
      messageId: 'a7',
      createdAt: 10,
      trackers: const [],
    );
    await seedSnapshot(
      sessionId: 'session',
      messageId: 'a5',
      createdAt: 200,
      trackers: const [],
      agentSwipeId: 1,
      committed: false,
    );
    await seedSnapshot(
      sessionId: 'session',
      messageId: 'a3',
      createdAt: 300,
      trackers: const [],
    );
    await seedSnapshot(
      sessionId: 'session',
      messageId: 'deleted',
      createdAt: 400,
      trackers: const [],
    );

    final snapshots = await service.loadSnapshots('session');

    expect(snapshots.map((item) => item.snapshot.messageId), [
      'a7',
      'a5',
      'a5',
      'a3',
      'deleted',
    ]);
    expect(
      snapshots
          .where((item) => item.snapshot.messageId == 'a5')
          .map((item) => item.snapshot.createdAt),
      [200, 100],
    );
  });
}
