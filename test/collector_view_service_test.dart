import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_collector_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_observation_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/models/card_evolution_observation.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/features/chat/services/collector_view_service.dart';

void main() {
  late AppDatabase db;
  late LedgerReconciliationRunRepo reconciliationRepo;
  late CardEvolutionCollectorRunRepo collectorRepo;
  late CardEvolutionObservationRepo observationRepo;
  late CollectorViewService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    reconciliationRepo = LedgerReconciliationRunRepo(db);
    collectorRepo = CardEvolutionCollectorRunRepo(db);
    observationRepo = CardEvolutionObservationRepo(db);
    service = CollectorViewService(
      collectorRepo: collectorRepo,
      observationRepo: observationRepo,
      reconciliationRepo: reconciliationRepo,
    );
  });

  tearDown(() => db.close());

  test('projects collector pair and every observation lifecycle state', () async {
    await db.customStatement(
      "INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) VALUES ('session', 'character', 0, '[{\"id\":\"a1\",\"role\":\"assistant\",\"content\":\"one\"},{\"id\":\"u1\",\"role\":\"user\",\"content\":\"two\"}]')",
    );
    final first = _run(
      id: 'run-1',
      ordinal: 1,
      messageId: 'a1',
      role: 'assistant',
      content: 'one',
    );
    expect(
      await reconciliationRepo.append(first),
      isA<ReconciliationRunAppended>(),
    );
    final second = _run(
      id: 'run-2',
      ordinal: 2,
      predecessor: first.chainHash,
      messageId: 'u1',
      role: 'user',
      content: 'two',
    );
    expect(
      await reconciliationRepo.append(second),
      isA<ReconciliationRunAppended>(),
    );
    await db
        .into(db.cardEvolutionCollectorRuns)
        .insert(
          CardEvolutionCollectorRunsCompanion.insert(
            id: 'collector-1',
            sessionId: 'session',
            characterId: 'character',
            collectorOrdinal: 1,
            reconciliationRunId: second.id,
            reconciliationRunOrdinal: second.ordinal,
            reconciliationChainHash: second.chainHash,
            rangeHash: _pairHash(first, second),
            inputHash: 'input',
            ownerId: 'owner',
            status: 'completed',
            leaseExpiresAt: 100,
            createdAt: 10,
          ),
        );
    await observationRepo.insertObservation(_observation('active', 'active'));
    await observationRepo.insertObservation(
      _observation('expired', 'expired', updatedAt: 20),
    );

    final snapshot = await service.load('session');

    expect(snapshot.runs, hasLength(1));
    expect(snapshot.runs.single.label, 'Collector #1 (commits 1-2)');
    expect(snapshot.observations.map((item) => item.status), [
      'expired',
      'active',
    ]);
  });
}

LedgerReconciliationRun _run({
  required String id,
  required int ordinal,
  required String messageId,
  required String role,
  required String content,
  String predecessor = '',
}) => LedgerReconciliationRun(
  id: id,
  sessionId: 'session',
  ordinal: ordinal,
  anchors: [
    ReconciliationAnchor(
      messageId: messageId,
      swipeId: 0,
      agentSwipeId: 0,
      role: role,
      contentHash: computeHash(content),
    ),
  ],
  acceptedManifestRefs: const [],
  effectiveCanonStamp: 'stamp',
  effectiveCanonRevision: 1,
  effectiveCanonHash: 'canon',
  canonicalResult: const {'export': <String, Object?>{}},
  predecessorChainHash: predecessor,
  contractVersion: 1,
  opsApplied: const [],
  createdAt: ordinal,
);

CardEvolutionObservation _observation(
  String id,
  String status, {
  int updatedAt = 10,
}) => CardEvolutionObservation(
  id: id,
  sessionId: 'session',
  characterId: 'character',
  runOrdinal: 1,
  semanticScopeKey: 'scope:$id',
  observedChange: 'change $id',
  evidenceClusters: const [
    ['a1', 'u1'],
  ],
  confidence: 0.8,
  status: status,
  firstSeenRun: 1,
  createdAt: 10,
  updatedAt: updatedAt,
);

String _pairHash(
  LedgerReconciliationRun first,
  LedgerReconciliationRun second,
) => computeHash(
  '${first.id}\u001f${first.rangeHash}\u001e'
  '${second.id}\u001f${second.rangeHash}',
);
