import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/post_cleaner_service.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';

void main() {
  late AppDatabase db;
  late List<String> events;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    events = [];
  });

  tearDown(() => db.close());

  test(
    'updates cache and history before cloning the parent snapshot',
    () async {
      const tracker = Tracker(
        sessionId: 'session',
        name: 'mood',
        value: 'calm',
      );
      const session = ChatSession(
        id: 'session',
        characterId: 'character',
        sessionIndex: 0,
        messages: [
          ChatMessage(
            id: 'message',
            role: 'assistant',
            content: 'cleaned',
            swipeId: 3,
            agentSwipeId: 2,
          ),
        ],
      );
      final chatRepo = _RecordingChatRepo(db, events, session: session);
      final snapshotRepo = _RecordingSnapshotRepo(
        db,
        events,
        parent: const TrackerSnapshot(
          sessionId: 'session',
          messageId: 'message',
          swipeId: 3,
          agentSwipeId: 1,
          trackers: [tracker],
          committed: true,
        ),
      );
      ChatSession? callbackSession;
      final service = PostCleanerService(
        llm: const AuxLlmClient(),
        chatRepo: chatRepo,
        snapshotRepo: snapshotRepo,
        onSessionUpdated: (updated) {
          events.add('session-updated');
          callbackSession = updated;
        },
        invalidateChatHistory: () => events.add('history-invalidated'),
      );

      await service.applyCleanedText(
        sessionId: 'session',
        messageId: 'message',
        cleanedText: 'cleaned',
        genTime: '1.2s',
        tokens: 7,
      );

      expect(callbackSession, same(session));
      expect(events, [
        'append',
        'session-read',
        'session-updated',
        'history-invalidated',
        'snapshot-read',
        'snapshot-write',
      ]);
      expect(snapshotRepo.readAnchor, ('session', 'message', 3, 1));
      expect(snapshotRepo.writtenAnchor, ('session', 'message', 3, 2));
    expect(snapshotRepo.writtenTrackers, snapshotRepo.parent!.trackers);
      expect(chatRepo.appended, (
        'session',
        'message',
        'cleaned',
        'cleaned',
        '1.2s',
        7,
      ));
    },
  );

  test('does not refresh or clone when the message was not updated', () async {
    final service = PostCleanerService(
      llm: const AuxLlmClient(),
      chatRepo: _RecordingChatRepo(db, events, updated: false),
      snapshotRepo: _RecordingSnapshotRepo(db, events),
      onSessionUpdated: (_) => events.add('session-updated'),
      invalidateChatHistory: () => events.add('history-invalidated'),
    );

    await service.applyCleanedText(
      sessionId: 'session',
      messageId: 'missing',
      cleanedText: 'cleaned',
    );

    expect(events, ['append']);
  });
}

class _RecordingChatRepo extends ChatRepo {
  _RecordingChatRepo(
    super.db,
    this.events, {
    this.session,
    this.updated = true,
  });

  final List<String> events;
  final ChatSession? session;
  final bool updated;
  (String, String, String, String, String?, int?)? appended;

  @override
  Future<bool> appendAgentSwipe({
    required String sessionId,
    required String messageId,
    required String content,
    required String kind,
    String? reasoning,
    String? genTime,
    int? tokens,
    List<Map<String, dynamic>> studioOutputs = const [],
  }) async {
    events.add('append');
    appended = (sessionId, messageId, content, kind, genTime, tokens);
    return updated;
  }

  @override
  Future<ChatSession?> getById(String sessionId) async {
    events.add('session-read');
    return session;
  }
}

class _RecordingSnapshotRepo extends TrackerSnapshotRepo {
  _RecordingSnapshotRepo(super.db, this.events, {this.parent});

  final List<String> events;
  final TrackerSnapshot? parent;
  (String, String, int, int)? readAnchor;
  (String, String, int, int)? writtenAnchor;
  List<Tracker>? writtenTrackers;

  @override
  Future<TrackerSnapshot?> getByAnchor({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
  }) async {
    events.add('snapshot-read');
    readAnchor = (sessionId, messageId, swipeId, agentSwipeId);
    return parent;
  }

  @override
  Future<void> upsertTrackers({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required List<Tracker> trackers,
    bool committed = false,
  }) async {
    events.add('snapshot-write');
    writtenAnchor = (sessionId, messageId, swipeId, agentSwipeId);
    writtenTrackers = trackers;
  }
}
