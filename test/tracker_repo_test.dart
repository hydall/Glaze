import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/models/tracker.dart';

AppDatabase _testDb() => AppDatabase.forTesting(NativeDatabase.memory());

Tracker _tracker({
  required String sessionId,
  required String name,
  String value = 'v',
  String scope = 'chat',
  String provenance = '',
}) {
  return Tracker(
    sessionId: sessionId,
    name: name,
    value: value,
    scope: scope,
    provenance: provenance,
  );
}

void main() {
  late AppDatabase db;
  late TrackerRepo repo;

  setUp(() {
    db = _testDb();
    repo = TrackerRepo(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('TrackerRepo.upsert', () {
    test('creates a new tracker', () async {
      await repo.upsert(_tracker(sessionId: 's1', name: 'mood', value: 'happy'));

      final got = await repo.get('s1', 'mood');
      expect(got, isNotNull);
      expect(got!.value, 'happy');
      expect(got.scope, 'chat');
    });

    test('overwrites existing tracker with same name', () async {
      await repo.upsert(_tracker(sessionId: 's1', name: 'mood', value: 'happy'));
      await repo.upsert(_tracker(sessionId: 's1', name: 'mood', value: 'angry'));

      final got = await repo.get('s1', 'mood');
      expect(got!.value, 'angry');
    });

    test('preserves different trackers with different names', () async {
      await repo.upsert(_tracker(sessionId: 's1', name: 'mood', value: 'happy'));
      await repo.upsert(
        _tracker(sessionId: 's1', name: 'location', value: 'tavern'),
      );

      final mood = await repo.get('s1', 'mood');
      final loc = await repo.get('s1', 'location');
      expect(mood!.value, 'happy');
      expect(loc!.value, 'tavern');
    });
  });

  group('TrackerRepo.getBySessionId', () {
    test('returns all trackers sorted by name', () async {
      await repo.upsert(_tracker(sessionId: 's1', name: 'zeta', value: '1'));
      await repo.upsert(_tracker(sessionId: 's1', name: 'alpha', value: '2'));
      await repo.upsert(_tracker(sessionId: 's1', name: 'mid', value: '3'));

      final all = await repo.getBySessionId('s1');
      expect(all.map((t) => t.name).toList(), ['alpha', 'mid', 'zeta']);
    });

    test('returns empty list for session with no trackers', () async {
      final all = await repo.getBySessionId('empty');
      expect(all, isEmpty);
    });

    test('does not leak trackers across sessions', () async {
      await repo.upsert(_tracker(sessionId: 's1', name: 'mood', value: 'a'));
      await repo.upsert(_tracker(sessionId: 's2', name: 'mood', value: 'b'));

      final s1 = await repo.getBySessionId('s1');
      final s2 = await repo.getBySessionId('s2');
      expect(s1.length, 1);
      expect(s1.first.value, 'a');
      expect(s2.length, 1);
      expect(s2.first.value, 'b');
    });
  });

  group('TrackerRepo.getBySessionAndScope', () {
    test('filters by scope', () async {
      await repo.upsert(
        _tracker(sessionId: 's1', name: 'a', value: '1', scope: 'chat'),
      );
      await repo.upsert(
        _tracker(sessionId: 's1', name: 'b', value: '2', scope: 'character'),
      );
      await repo.upsert(
        _tracker(sessionId: 's1', name: 'c', value: '3', scope: 'chat'),
      );

      final chatOnly = await repo.getBySessionAndScope('s1', 'chat');
      expect(chatOnly.map((t) => t.name).toList(), ['a', 'c']);
    });
  });

  group('TrackerRepo.upsertValue', () {
    test('upserts via explicit fields', () async {
      await repo.upsertValue('s1', 'mood', 'happy', provenance: 'agent:msg1');

      final got = await repo.get('s1', 'mood');
      expect(got!.value, 'happy');
      expect(got.provenance, 'agent:msg1');
      expect(got.updatedAt, greaterThan(0));
    });

    test('overwrites via explicit fields', () async {
      await repo.upsertValue('s1', 'mood', 'happy');
      await repo.upsertValue('s1', 'mood', 'angry');

      final got = await repo.get('s1', 'mood');
      expect(got!.value, 'angry');
    });
  });

  group('TrackerRepo.delete', () {
    test('removes a single tracker', () async {
      await repo.upsert(_tracker(sessionId: 's1', name: 'a', value: '1'));
      await repo.upsert(_tracker(sessionId: 's1', name: 'b', value: '2'));

      await repo.delete('s1', 'a');

      final all = await repo.getBySessionId('s1');
      expect(all.map((t) => t.name).toList(), ['b']);
    });

    test('is a no-op when tracker does not exist', () async {
      await repo.delete('s1', 'ghost');
      final all = await repo.getBySessionId('s1');
      expect(all, isEmpty);
    });
  });

  group('TrackerRepo.clearForSession', () {
    test('removes all trackers for the session', () async {
      await repo.upsert(_tracker(sessionId: 's1', name: 'a', value: '1'));
      await repo.upsert(_tracker(sessionId: 's1', name: 'b', value: '2'));
      await repo.upsert(_tracker(sessionId: 's2', name: 'c', value: '3'));

      await repo.clearForSession('s1');

      expect(await repo.getBySessionId('s1'), isEmpty);
      expect((await repo.getBySessionId('s2')).length, 1);
    });
  });

  group('TrackerRepo.replaceForSession', () {
    test('atomically replaces all trackers', () async {
      await repo.upsert(_tracker(sessionId: 's1', name: 'old', value: '1'));
      await repo.upsert(_tracker(sessionId: 's1', name: 'stale', value: '2'));

      await repo.replaceForSession('s1', [
        _tracker(sessionId: 's1', name: 'new1', value: 'a'),
        _tracker(sessionId: 's1', name: 'new2', value: 'b'),
      ]);

      final all = await repo.getBySessionId('s1');
      expect(all.map((t) => t.name).toList(), ['new1', 'new2']);
      expect(all.map((t) => t.value).toList(), ['a', 'b']);
    });

    test('does not affect other sessions', () async {
      await repo.upsert(_tracker(sessionId: 's1', name: 'a', value: '1'));
      await repo.upsert(_tracker(sessionId: 's2', name: 'b', value: '2'));

      await repo.replaceForSession('s1', [
        _tracker(sessionId: 's1', name: 'x', value: '9'),
      ]);

      expect((await repo.getBySessionId('s1')).length, 1);
      expect((await repo.getBySessionId('s2')).length, 1);
    });
  });

  group('TrackerRepo.watchBySessionId', () {
    test('emits initial state and updates on change', () async {
      await repo.upsert(_tracker(sessionId: 's1', name: 'a', value: '1'));

      final stream = repo.watchBySessionId('s1');
      final first = await stream.first;
      expect(first.map((t) => t.name).toList(), ['a']);

      await repo.upsert(_tracker(sessionId: 's1', name: 'b', value: '2'));

      final second = await stream.first;
      expect(second.map((t) => t.name).toList(), ['a', 'b']);
    });
  });
}
