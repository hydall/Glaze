import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_observation_repo.dart';
import 'package:glaze_flutter/core/models/card_evolution_observation.dart';

void main() {
  late AppDatabase db;
  late CardEvolutionObservationRepo repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = CardEvolutionObservationRepo(db);
  });
  tearDown(() => db.close());

  test('insert and find by scope key', () async {
    await repo.insertObservation(_observation());
    final found = await repo.findByScopeKey(
      'session',
      'character.preference.X',
    );
    expect(found, isNotNull);
    expect(found!.status, 'active');
    expect(found.repeatCount, 1);
    expect(found.lastConfirmedRun, isNull);
    expect(found.evidenceMessageIds, ['msg:1', 'msg:2']);
    expect(found.evidenceClusters, [
      ['msg:1', 'msg:2'],
    ]);
    expect(found.retrievalKeys, ['npc:Алиса']);
    expect(found.targetKind, 'main_character_card');
  });

  test('confirm bumps repeat count and last confirmed run', () async {
    await repo.insertObservation(_observation());
    await repo.confirmObservation(
      id: 'obs-1',
      runOrdinal: 2,
      confidence: 0.8,
      now: 20,
      evidenceMessageIds: const ['msg:3', 'msg:4'],
    );
    final found = await repo.findByScopeKey(
      'session',
      'character.preference.X',
    );
    expect(found!.repeatCount, 2);
    expect(found.lastConfirmedRun, 2);
    expect(found.confidence, 0.8);
    expect(found.updatedAt, 20);
    expect(found.evidenceClusters, [
      ['msg:1', 'msg:2'],
      ['msg:3', 'msg:4'],
    ]);
  });

  test(
    'confirm is idempotent for duplicate, overlap, empty, and same run',
    () async {
      await repo.insertObservation(_observation());
      expect(
        await repo.confirmObservation(
          id: 'obs-1',
          runOrdinal: 2,
          confidence: 0.8,
          now: 20,
          evidenceMessageIds: const ['msg:2', 'msg:1'],
        ),
        ObservationConfirmationOutcome.duplicate,
      );
      expect(
        await repo.confirmObservation(
          id: 'obs-1',
          runOrdinal: 2,
          confidence: 0.8,
          now: 20,
          evidenceMessageIds: const ['msg:2', 'msg:3'],
        ),
        ObservationConfirmationOutcome.overlap,
      );
      expect(
        await repo.confirmObservation(
          id: 'obs-1',
          runOrdinal: 2,
          confidence: 0.8,
          now: 20,
          evidenceMessageIds: const [],
        ),
        ObservationConfirmationOutcome.noEvidence,
      );
      expect(
        await repo.confirmObservation(
          id: 'obs-1',
          runOrdinal: 1,
          confidence: 0.8,
          now: 20,
          evidenceMessageIds: const ['msg:3'],
        ),
        ObservationConfirmationOutcome.sameRun,
      );
      expect((await repo.findById('obs-1'))!.repeatCount, 1);
    },
  );

  test('promote flips status and excludes from active', () async {
    await repo.insertObservation(_observation());
    await repo.promoteObservation('obs-1', now: 20);
    expect(await repo.getActiveObservations('session'), isEmpty);
    final promoted = await repo.getPromotedObservations('session');
    expect(promoted, hasLength(1));
    expect(promoted.first.status, 'promoted');
  });

  test('explicit contradiction expires and excludes from active', () async {
    await repo.insertObservation(_observation());
    await repo.contradictObservation('obs-1', now: 20);
    expect(await repo.getActiveObservations('session'), isEmpty);
  });

  test('consume flips promoted to consumed', () async {
    await repo.insertObservation(_observation());
    await repo.promoteObservation('obs-1', now: 20);
    await repo.consumeObservation('obs-1', now: 30);
    expect(await repo.getPromotedObservations('session'), isEmpty);
  });

  test('terminal scope can reactivate as a fresh evidence cycle', () async {
    await repo.insertObservation(_observation());
    await repo.contradictObservation('obs-1', now: 20);

    final outcome = await repo.insertOrReactivate(
      _observation(
        id: 'ignored-new-id',
        repeatCount: 1,
        confidence: 0.9,
        lastConfirmedRun: 7,
      ).copyWith(
        runOrdinal: 7,
        observedChange: 'Alice now consistently trusts Bob',
        firstSeenRun: 7,
        evidenceClusters: const [
          ['msg:7'],
        ],
        updatedAt: 70,
      ),
    );

    expect(outcome, ObservationActivationOutcome.reactivated);
    final restored = await repo.findByScopeKey(
      'session',
      'character.preference.X',
    );
    expect(restored!.id, 'obs-1');
    expect(restored.status, 'active');
    expect(restored.runOrdinal, 7);
    expect(restored.firstSeenRun, 7);
    expect(restored.repeatCount, 1);
    expect(restored.lastConfirmedRun, 7);
    expect(restored.evidenceClusters, [
      ['msg:7'],
    ]);
  });

  test('expires only active candidates outside confirmation window', () async {
    await repo.insertObservation(_observation(lastConfirmedRun: 1));
    await repo.insertObservation(
      _observation(
        id: 'recent',
        scopeKey: 'character.attitude.recent',
        lastConfirmedRun: 4,
      ),
    );
    await repo.promoteObservation('recent', now: 20);

    expect(
      await repo.expireUnconfirmed(
        sessionId: 'session',
        currentRunOrdinal: 5,
        maxUnconfirmedRuns: 4,
        now: 50,
      ),
      1,
    );
    expect((await repo.findById('obs-1'))!.status, 'expired');
    expect((await repo.findById('recent'))!.status, 'promoted');
  });

  test('getPromotable filters by repeat count and confidence', () async {
    await repo.insertObservation(_observation(repeatCount: 2, confidence: 0.6));
    await repo.insertObservation(
      _observation(
        id: 'obs-2',
        scopeKey: 'character.attitude.Y',
        repeatCount: 3,
        confidence: 0.8,
      ),
    );
    final promotable = await repo.getPromotableObservations(
      'session',
      minRepeatCount: 3,
      minConfidence: 0.7,
    );
    expect(promotable, hasLength(1));
    expect(promotable.first.id, 'obs-2');
  });

  test('unique key collision on insert throws', () async {
    await repo.insertObservation(_observation());
    await expectLater(
      repo.insertObservation(_observation()),
      throwsA(isA<Object>()),
    );
  });
}

CardEvolutionObservation _observation({
  String id = 'obs-1',
  String scopeKey = 'character.preference.X',
  int repeatCount = 1,
  double confidence = 0.5,
  int? lastConfirmedRun,
}) => CardEvolutionObservation(
  id: id,
  sessionId: 'session',
  characterId: 'character',
  runOrdinal: 1,
  semanticScopeKey: scopeKey,
  observedChange: 'Alice is becoming more trusting',
  canonicalClaim: 'Alice has become more trusting over time',
  evidenceClusters: const [
    ['msg:1', 'msg:2'],
  ],
  retrievalKeys: const ['npc:Алиса'],
  targetKind: 'main_character_card',
  cardFieldPath: 'personality',
  confidence: confidence,
  status: 'active',
  firstSeenRun: 1,
  repeatCount: repeatCount,
  lastConfirmedRun: lastConfirmedRun,
  createdAt: 10,
  updatedAt: 10,
);
