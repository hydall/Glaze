import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_collector_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_observation_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/llm_request_capture_repo.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/llm/transport/llm_call_event.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/core/models/card_evolution_observation.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/features/chat/services/collector_view_service.dart';

void main() {
  late AppDatabase db;
  late LedgerReconciliationRunRepo reconciliationRepo;
  late CardEvolutionCollectorRunRepo collectorRepo;
  late CardEvolutionObservationRepo observationRepo;
  late CollectorViewService service;
  late LlmRequestCaptureRepo captureRepo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    reconciliationRepo = LedgerReconciliationRunRepo(db);
    collectorRepo = CardEvolutionCollectorRunRepo(db);
    observationRepo = CardEvolutionObservationRepo(db);
    captureRepo = LlmRequestCaptureRepo(db);
    service = CollectorViewService(
      collectorRepo: collectorRepo,
      observationRepo: observationRepo,
      reconciliationRepo: reconciliationRepo,
      captureRepo: captureRepo,
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
    expect(snapshot.unclaimedPairCount, 0);
    expect(snapshot.runs.single.firstReconciliationOrdinal, 1);
    expect(snapshot.runs.single.boundaryReconciliationOrdinal, 2);
    expect(snapshot.observations.map((item) => item.status), [
      'expired',
      'active',
    ]);
  });

  test('reports a valid reconciliation pair without a Collector claim', () async {
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
    await reconciliationRepo.append(first);
    await reconciliationRepo.append(
      _run(
        id: 'run-2',
        ordinal: 2,
        predecessor: first.chainHash,
        messageId: 'u1',
        role: 'user',
        content: 'two',
      ),
    );

    final snapshot = await service.load('session');

    expect(snapshot.unclaimedPairCount, 1);
    expect(snapshot.runs, isEmpty);
  });

  test('reports a valid pair when its Collector lease expired', () async {
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
    final second = _run(
      id: 'run-2',
      ordinal: 2,
      predecessor: first.chainHash,
      messageId: 'u1',
      role: 'user',
      content: 'two',
    );
    await reconciliationRepo.append(first);
    await reconciliationRepo.append(second);
    await db
        .into(db.cardEvolutionCollectorRuns)
        .insert(
          CardEvolutionCollectorRunsCompanion.insert(
            id: 'collector-expired',
            sessionId: 'session',
            characterId: 'character',
            collectorOrdinal: 1,
            reconciliationRunId: second.id,
            reconciliationRunOrdinal: second.ordinal,
            reconciliationChainHash: second.chainHash,
            rangeHash: _pairHash(first, second),
            inputHash: 'input',
            ownerId: 'interrupted-owner',
            status: 'claimed',
            leaseExpiresAt: 1,
            createdAt: 1,
          ),
        );

    final snapshot = await service.load('session');

    expect(snapshot.unclaimedPairCount, 1);
    expect(snapshot.runs.single.row.id, 'collector-expired');
  });

  test('joins failed run with exact prompt and parser response', () async {
    await db.customStatement(
      "INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) VALUES ('session', 'character', 0, '[]')",
    );
    await db
        .into(db.cardEvolutionCollectorRuns)
        .insert(
          CardEvolutionCollectorRunsCompanion.insert(
            id: 'collector-failed',
            sessionId: 'session',
            characterId: 'character',
            collectorOrdinal: 1,
            reconciliationRunId: 'run-2',
            reconciliationRunOrdinal: 2,
            reconciliationChainHash: 'chain',
            rangeHash: 'range',
            inputHash: 'input',
            ownerId: 'owner',
            status: 'failed',
            leaseExpiresAt: 0,
            lastCallId: const Value('call-1'),
            failureCode: const Value('parserRejected'),
            failedAt: const Value(10),
            createdAt: 1,
          ),
        );
    const context = LlmCaptureContext(
      stage: 'card.collector',
      sessionId: 'session',
      pipelineRunId: 'collector-failed',
      callId: 'call-1',
      relatedArtifactId: 'collector-failed',
      attempt: 1,
    );
    await captureRepo.record(
      LlmRequestCapture.build(
        ChatTransportRequest(
          endpoint: 'https://example.test',
          apiKey: 'secret',
          model: 'model',
          messages: const [
            {'role': 'user', 'content': 'exact prompt'},
          ],
          maxTokens: 20,
          temperature: 0.2,
          topP: 1,
          captureContext: context,
        ),
      ),
    );
    await captureRepo.recordCallEvent(
      LlmCallEvent.transport(
        context: context,
        attempt: const AgentOperationAttempt(
          attempt: 1,
          statusCode: 200,
          status: 'ok',
          startedAtMs: 1,
          elapsedMs: 1,
        ),
        responseText: 'bad response',
      ),
    );

    final run = (await service.load('session')).runs.single;
    expect(run.canRetry, isTrue);
    expect(run.canRetryExact, isTrue);
    expect(run.exactCapture?.prompt, 'exact prompt');
    expect(run.latestResponse, 'bad response');

    final withoutExactCapture = CollectorRunView(
      row: run.row,
      firstReconciliationOrdinal: run.firstReconciliationOrdinal,
      boundaryReconciliationOrdinal: run.boundaryReconciliationOrdinal,
      exactCapture: null,
      callEvents: run.callEvents,
    );
    expect(withoutExactCapture.canRetry, isTrue);
    expect(withoutExactCapture.canRetryExact, isFalse);
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
