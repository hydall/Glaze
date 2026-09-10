import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_proposal_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/llm/game_time.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/features/chat/services/manual_ledger_clock_service.dart';

void main() {
  late AppDatabase db;
  late ChatRepo chatRepo;
  late TrackerRepo trackerRepo;
  late TrackerSnapshotRepo snapshotRepo;
  late ManualLedgerClockService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chatRepo = ChatRepo(db);
    trackerRepo = TrackerRepo(db);
    snapshotRepo = TrackerSnapshotRepo(db);
    service = ManualLedgerClockService(
      chatRepo: chatRepo,
      snapshotRepo: snapshotRepo,
      trackerRepo: trackerRepo,
      reconciliationRunRepo: LedgerReconciliationRunRepo(db),
      reconciliationCheckpointRepo: LedgerReconciliationCheckpointRepo(db),
      proposalRunRepo: CardEvolutionProposalRunRepo(db),
    );
  });

  tearDown(() => db.close());

  GameTimeState clock(String time) =>
      GameTimeState(time: time, date: '08.09.0755', day: 0);

  List<Tracker> trackers(String time, String marker) => [
    Tracker(sessionId: 'session', name: 'world:time', value: time),
    const Tracker(
      sessionId: 'session',
      name: 'world:date',
      value: '08.09.0755',
    ),
    const Tracker(sessionId: 'session', name: 'world:day', value: '0'),
    Tracker(sessionId: 'session', name: 'world:location', value: marker),
  ];

  Future<void> seed() async {
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
        ],
      ),
    );
    for (final value in [('a1', '09:01'), ('a3', '08:15'), ('a5', '08:15')]) {
      await snapshotRepo.upsert(
        TrackerSnapshot(
          sessionId: 'session',
          messageId: value.$1,
          trackers: trackers(value.$2, value.$1),
          committed: value.$1 != 'a5',
          createdAt: 1,
        ),
      );
    }
    for (final entry in {
      'world:time': '08:15',
      'world:date': '08.09.0755',
      'world:day': '0',
    }.entries) {
      await trackerRepo.upsertValue(
        'session',
        entry.key,
        entry.value,
        scope: 'ledger',
      );
    }
  }

  test('loads active assistant anchors in message order', () async {
    await seed();

    final entries = await service.loadRecent('session', limit: 2);

    expect(entries.map((item) => item.messageId), ['a3', 'a5']);
    expect(entries.map((item) => item.messageNumber), [3, 5]);
  });

  test(
    'atomically corrects snapshots, stamps, and latest live clock',
    () async {
      await seed();
      final entries = await service.loadRecent('session', limit: 2);

      await service.save('session', [
        ManualLedgerClockCorrection(entry: entries[0], clock: clock('09:02')),
        ManualLedgerClockCorrection(entry: entries[1], clock: clock('09:03')),
      ]);

      final session = await chatRepo.getById('session');
      expect(session!.messages[2].time, '08.09.0755 · RP_Day 0 · 09:02');
      expect(session.messages[4].time, '08.09.0755 · RP_Day 0 · 09:03');
      final snapshot = await snapshotRepo.getByAnchor(
        sessionId: 'session',
        messageId: 'a3',
        swipeId: 0,
        agentSwipeId: 0,
      );
      expect(GameTimeState.fromTrackers(snapshot!.trackers).time, '09:02');
      expect(
        snapshot.trackers
            .singleWhere((item) => item.name == 'world:location')
            .value,
        'a3',
      );
      expect(snapshot.committed, isTrue);
      expect((await trackerRepo.get('session', 'world:time'))!.value, '09:03');
      expect(await trackerRepo.getLedgerManualMutationRevision('session'), 1);
    },
  );

  test('advances the manual mutation fence on every persisted edit', () async {
    await seed();
    var entries = await service.loadRecent('session', limit: 2);

    await service.save('session', [
      ManualLedgerClockCorrection(entry: entries[0], clock: clock('09:02')),
      ManualLedgerClockCorrection(entry: entries[1], clock: clock('09:03')),
    ]);
    expect(await trackerRepo.getLedgerManualMutationRevision('session'), 1);

    entries = await service.loadRecent('session', limit: 2);
    await service.save('session', [
      ManualLedgerClockCorrection(entry: entries[0], clock: clock('09:04')),
      ManualLedgerClockCorrection(entry: entries[1], clock: clock('09:05')),
    ]);

    expect(await trackerRepo.getLedgerManualMutationRevision('session'), 2);
  });

  test('tracker restoration cannot rewind the manual mutation fence', () async {
    await trackerRepo.bumpLedgerManualMutationRevision('session');
    await trackerRepo.bumpLedgerManualMutationRevision('session');

    await trackerRepo.replaceForSession('session', [
      ...trackers('08:15', 'restored'),
      const Tracker(
        sessionId: 'session',
        name: TrackerRepo.ledgerManualMutationRevisionName,
        value: '1',
        scope: 'system',
      ),
    ]);

    expect(await trackerRepo.getLedgerManualMutationRevision('session'), 2);
  });

  test('rejects a backward corrected sequence without writing', () async {
    await seed();
    final entries = await service.loadRecent('session', limit: 2);

    await expectLater(
      service.save('session', [
        ManualLedgerClockCorrection(entry: entries[0], clock: clock('09:10')),
        ManualLedgerClockCorrection(entry: entries[1], clock: clock('09:05')),
      ]),
      throwsA(isA<ManualLedgerClockException>()),
    );

    final unchanged = await snapshotRepo.getByAnchor(
      sessionId: 'session',
      messageId: 'a3',
      swipeId: 0,
      agentSwipeId: 0,
    );
    expect(GameTimeState.fromTrackers(unchanged!.trackers).time, '08:15');
  });

  test('rejects a correction before the preceding unedited clock', () async {
    await seed();
    final entries = await service.loadRecent('session', limit: 2);

    await expectLater(
      service.save('session', [
        ManualLedgerClockCorrection(entry: entries[0], clock: clock('08:59')),
        ManualLedgerClockCorrection(entry: entries[1], clock: clock('09:00')),
      ]),
      throwsA(isA<ManualLedgerClockException>()),
    );

    final session = await chatRepo.getById('session');
    expect(session!.messages[2].time, isNull);
    expect((await trackerRepo.get('session', 'world:time'))!.value, '08:15');
  });

  test('deletes a reconciliation checkpoint touched by a correction', () async {
    await seed();
    final checkpointRepo = LedgerReconciliationCheckpointRepo(db);
    await checkpointRepo.upsert(
      const LedgerReconciliationCheckpoint(
        sessionId: 'session',
        startMessageId: 'a1',
        endMessageId: 'a3',
        endSwipeId: 0,
        endAgentSwipeId: 0,
        messageIds: ['a1', 'u2', 'a3'],
        rangeHash: 'old-range',
      ),
    );
    final entries = await service.loadRecent('session', limit: 2);

    await service.save('session', [
      ManualLedgerClockCorrection(entry: entries[0], clock: clock('09:02')),
      ManualLedgerClockCorrection(entry: entries[1], clock: clock('09:03')),
    ]);

    expect(await checkpointRepo.get('session'), isNull);
  });

  test('rejects calendar date and RP day disagreement', () async {
    await seed();
    final entries = await service.loadRecent('session', limit: 2);
    final inconsistent = const GameTimeState(
      time: '09:03',
      date: '09.09.0755',
      day: 0,
    );

    await expectLater(
      service.save('session', [
        ManualLedgerClockCorrection(entry: entries[0], clock: clock('09:02')),
        ManualLedgerClockCorrection(entry: entries[1], clock: inconsistent),
      ]),
      throwsA(isA<ManualLedgerClockException>()),
    );

    final unchanged = await snapshotRepo.getByAnchor(
      sessionId: 'session',
      messageId: 'a3',
      swipeId: 0,
      agentSwipeId: 0,
    );
    expect(GameTimeState.fromTrackers(unchanged!.trackers).time, '08:15');
  });
}
