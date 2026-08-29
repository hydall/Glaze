import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/models/tracker.dart';

void main() {
  late AppDatabase db;
  late LedgerRawTrackerStateReader reader;
  late TrackerRepo trackers;
  late TrackerSnapshotRepo snapshots;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    reader = LedgerRawTrackerStateReader(db);
    trackers = TrackerRepo(db);
    snapshots = TrackerSnapshotRepo(db);
  });
  tearDown(() => db.close());

  test(
    'reads committed Ledger snapshot and only live canon controls',
    () async {
      await snapshots.upsertTrackers(
        sessionId: 'session',
        messageId: 'message',
        swipeId: 0,
        agentSwipeId: 0,
        committed: true,
        trackers: const [
          Tracker(sessionId: 'session', name: 'world:time', scope: 'ledger'),
          Tracker(sessionId: 'session', name: 'chat:value', scope: 'chat'),
        ],
      );
      await trackers.upsertValue(
        'session',
        'canon_override:world:time',
        'night',
        scope: 'ledger',
      );
      await trackers.upsertValue(
        'session',
        'canon_lock:world:place',
        'true',
        scope: 'ledger',
      );
      await trackers.upsertValue(
        'session',
        'world:uncommitted',
        'ignored',
        scope: 'ledger',
      );

      final state = await db.transaction(() => reader.read('session'));

      expect(state.committedTrackers.map((item) => item.name), ['world:time']);
      expect(state.manualControls.map((item) => item.name), [
        'canon_lock:world:place',
        'canon_override:world:time',
      ]);
    },
  );

  test('uses a complete game-time seed before the first snapshot', () async {
    await trackers.seedInitialGameTime(
      sessionId: 'session',
      time: '14:12',
      date: '26.08.2026',
    );

    final state = await db.transaction(() => reader.read('session'));

    expect(
      {
        for (final tracker in state.committedTrackers)
          tracker.name: tracker.value,
      },
      {'world:time': '14:12', 'world:date': '26.08.2026', 'world:day': '0'},
    );
  });

  test(
    'zero-op first Ledger replacement preserves the game-time seed',
    () async {
      await trackers.seedInitialGameTime(
        sessionId: 'session',
        time: '14:12',
        date: '26.08.2026',
      );
      final bootstrap = await db.transaction(() => reader.read('session'));

      await trackers.replaceLedgerState('session', bootstrap.committedTrackers);

      final live = await trackers.getBySessionAndScope('session', 'ledger');
      expect(
        {for (final tracker in live) tracker.name: tracker.value},
        {'world:time': '14:12', 'world:date': '26.08.2026', 'world:day': '0'},
      );
    },
  );

  test('stale seed dialog cannot overwrite a changed clock', () async {
    await trackers.upsertValue(
      'session',
      'world:time',
      '14:15',
      scope: 'ledger',
      provenance: 'source=studio_ledger',
    );

    final seeded = await trackers.seedInitialGameTime(
      sessionId: 'session',
      time: '14:12',
      date: '26.08.2026',
      expectedValues: const {
        'world:time': null,
        'world:date': null,
        'world:day': null,
      },
    );

    expect(seeded, isFalse);
    expect((await trackers.get('session', 'world:time'))?.value, '14:15');
    expect(await trackers.get('session', 'world:date'), isNull);
    expect(await trackers.get('session', 'world:day'), isNull);
  });

  test('ignores a partial or unrelated live Ledger bootstrap', () async {
    await trackers.upsertValue(
      'session',
      'world:time',
      '14:12',
      scope: 'ledger',
      provenance: 'game_time_seed',
    );
    await trackers.upsertValue(
      'session',
      'world:date',
      '26.08.2026',
      scope: 'ledger',
      provenance: 'other',
    );

    final state = await db.transaction(() => reader.read('session'));

    expect(state.committedTrackers, isEmpty);
  });

  test('complete live clock repairs a partial committed snapshot', () async {
    await trackers.seedInitialGameTime(
      sessionId: 'session',
      time: '14:12',
      date: '26.08.2026',
    );
    await snapshots.upsertTrackers(
      sessionId: 'session',
      messageId: 'message',
      swipeId: 0,
      agentSwipeId: 0,
      committed: true,
      trackers: const [
        Tracker(
          sessionId: 'session',
          name: 'world:time',
          value: '14:15',
          scope: 'ledger',
        ),
      ],
    );

    final state = await db.transaction(() => reader.read('session'));

    expect(
      {
        for (final tracker in state.committedTrackers)
          tracker.name: tracker.value,
      },
      {'world:time': '14:15', 'world:date': '26.08.2026', 'world:day': '0'},
    );
  });

  test(
    'regen exclusion reads the previous snapshot without live leakage',
    () async {
      await snapshots.upsertTrackers(
        sessionId: 'session',
        messageId: 'previous',
        swipeId: 0,
        agentSwipeId: 0,
        committed: true,
        trackers: const [
          Tracker(
            sessionId: 'session',
            name: 'world:time',
            value: '12:00',
            scope: 'ledger',
          ),
          Tracker(
            sessionId: 'session',
            name: 'scene.location',
            value: 'before',
            scope: 'ledger',
          ),
        ],
      );
      await snapshots.upsertTrackers(
        sessionId: 'session',
        messageId: 'target',
        swipeId: 0,
        agentSwipeId: 0,
        committed: true,
        trackers: const [
          Tracker(
            sessionId: 'session',
            name: 'world:time',
            value: '12:30',
            scope: 'ledger',
          ),
          Tracker(
            sessionId: 'session',
            name: 'scene.location',
            value: 'after',
            scope: 'ledger',
          ),
        ],
      );
      await trackers.upsertValue(
        'session',
        'world:time',
        '12:30',
        scope: 'ledger',
      );
      await trackers.upsertValue(
        'session',
        'world:date',
        '01.01.2027',
        scope: 'ledger',
      );
      await trackers.upsertValue('session', 'world:day', '1', scope: 'ledger');

      final state = await db.transaction(
        () => reader.read('session', excludeSnapshotMessageId: 'target'),
      );

      expect(
        {
          for (final tracker in state.committedTrackers)
            tracker.name: tracker.value,
        },
        {'world:time': '12:00', 'scene.location': 'before'},
      );
    },
  );
}
