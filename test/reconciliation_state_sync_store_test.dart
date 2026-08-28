import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_collector_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_observation_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/models/card_evolution_observation.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/features/cloud_sync/adapters/ext_blocks_sync_stores.dart';

void main() {
  late AppDatabase sourceDb;
  late AppDatabase targetDb;
  late ReconciliationStateSyncStore sourceStore;
  late ReconciliationStateSyncStore targetStore;

  setUp(() async {
    sourceDb = AppDatabase.forTesting(NativeDatabase.memory());
    targetDb = AppDatabase.forTesting(NativeDatabase.memory());
    sourceStore = ReconciliationStateSyncStore(sourceDb);
    targetStore = ReconciliationStateSyncStore(targetDb);
    await Future.wait([_seedSession(sourceDb), _seedSession(targetDb)]);
  });

  tearDown(() async {
    await sourceDb.close();
    await targetDb.close();
  });

  test('imports an immutable chain and makes its head authoritative', () async {
    final sourceRuns = await _appendChain(sourceDb, 2);
    final payload = (await sourceStore.getBySessionId('session'))!;

    final merged = await targetStore.mergeBySessionId('session', payload);

    expect((merged['runs'] as List), hasLength(2));
    final head = await LedgerReconciliationRunRepo(targetDb).getHead('session');
    expect(head?.id, sourceRuns.last.id);
    expect(head?.chainHash, sourceRuns.last.chainHash);
  });

  test('round-trips exact reconciliation effects in payload v2', () async {
    final sourceRun = (await _appendChain(sourceDb, 1)).single;
    final sourceRepo = LedgerReconciliationRunRepo(sourceDb);
    final state = await sourceRepo.captureState('session');
    await sourceRepo.recordEffect(
      runId: sourceRun.id,
      sessionId: 'session',
      before: state,
      after: state,
      createdAt: 1,
    );

    final payload = (await sourceStore.getBySessionId('session'))!;
    expect(payload['schemaVersion'], 2);
    expect(payload['effects'], hasLength(1));

    await targetStore.mergeBySessionId('session', payload);
    final imported = await LedgerReconciliationRunRepo(
      targetDb,
    ).readEffect(sourceRun.id);
    expect(imported, isNotNull);
    expect(imported!.beforeStateHash, state.hash);
    expect(
      await LedgerReconciliationRunRepo(
        targetDb,
      ).validateEffect(await _storedRun(targetDb, sourceRun.id)),
      isA<ReconciliationEffectValid>(),
    );
  });

  test('accepts legacy payload v1 without exact effects', () async {
    await _appendChain(sourceDb, 1);
    final payload = (await sourceStore.getBySessionId('session'))!
      ..['schemaVersion'] = 1
      ..remove('effects');

    await targetStore.mergeBySessionId('session', payload);

    expect(
      await targetDb.select(targetDb.ledgerReconciliationEffects).get(),
      isEmpty,
    );
  });

  test('rejects tampered effects atomically', () async {
    final sourceRun = (await _appendChain(sourceDb, 1)).single;
    final repo = LedgerReconciliationRunRepo(sourceDb);
    final state = await repo.captureState('session');
    await repo.recordEffect(
      runId: sourceRun.id,
      sessionId: 'session',
      before: state,
      after: state,
      createdAt: 1,
    );
    final payload = (await sourceStore.getBySessionId('session'))!;
    final effect = Map<String, dynamic>.from(
      (payload['effects'] as List).single as Map,
    )..['afterStateHash'] = 'tampered';
    payload['effects'] = [effect];

    await expectLater(
      targetStore.mergeBySessionId('session', payload),
      throwsStateError,
    );
    expect(
      await targetDb.select(targetDb.ledgerReconciliationSuccessfulRuns).get(),
      isEmpty,
    );
    expect(
      await targetDb.select(targetDb.ledgerReconciliationEffects).get(),
      isEmpty,
    );
  });

  test(
    'legacy global run id collision is re-keyed without replacing parent',
    () async {
      final incoming = (await _appendChain(sourceDb, 1)).single;
      await targetDb.customStatement(
        'INSERT INTO chat_sessions '
        '(session_id, character_id, session_index, messages_json) '
        'VALUES (?, ?, 1, ?)',
        ['parent', 'character', jsonEncode(_messages)],
      );
      var parent = LedgerReconciliationRun(
        id: '',
        sessionId: 'parent',
        ordinal: 1,
        anchors: incoming.anchors,
        acceptedManifestRefs: const [],
        effectiveCanonStamp: incoming.effectiveCanonStamp,
        effectiveCanonRevision: incoming.effectiveCanonRevision,
        effectiveCanonHash: incoming.effectiveCanonHash,
        canonicalResult: incoming.canonicalResult,
        predecessorChainHash: '',
        contractVersion: incoming.contractVersion,
        opsApplied: incoming.opsApplied,
        createdAt: incoming.createdAt,
      );
      parent = LedgerReconciliationRun(
        id: 'reconciliation-${parent.contentHash}',
        sessionId: parent.sessionId,
        ordinal: parent.ordinal,
        anchors: parent.anchors,
        acceptedManifestRefs: parent.acceptedManifestRefs,
        effectiveCanonStamp: parent.effectiveCanonStamp,
        effectiveCanonRevision: parent.effectiveCanonRevision,
        effectiveCanonHash: parent.effectiveCanonHash,
        canonicalResult: parent.canonicalResult,
        predecessorChainHash: parent.predecessorChainHash,
        contractVersion: parent.contractVersion,
        opsApplied: parent.opsApplied,
        createdAt: parent.createdAt,
      );
      expect(
        await LedgerReconciliationRunRepo(targetDb).append(parent),
        isA<ReconciliationRunAppended>(),
      );

      final payload = (await sourceStore.getBySessionId('session'))!;
      final legacyRun = Map<String, dynamic>.from(
        (payload['runs'] as List).single as Map,
      );
      legacyRun
        ..['id'] = parent.id
        ..['contentHash'] = parent.contentHash
        ..['predecessorChainHash'] = parent.predecessorChainHash
        ..['chainHash'] = parent.chainHash;
      final legacyPayload = {
        ...payload,
        'runs': [legacyRun],
      };
      final firstMerge = await targetStore.mergeBySessionId(
        'session',
        legacyPayload,
      );
      final secondMerge = await targetStore.mergeBySessionId(
        'session',
        legacyPayload,
      );

      final parentRows = await LedgerReconciliationRunRepo(
        targetDb,
      ).readSession('parent');
      final importedRows = await LedgerReconciliationRunRepo(
        targetDb,
      ).readSession('session');
      expect(parentRows.single.id, parent.id);
      expect(importedRows, hasLength(1));
      expect(importedRows.single.id, isNot(parent.id));
      expect(
        importedRows.single.id,
        'reconciliation-${importedRows.single.contentHash}',
      );
      expect(secondMerge, firstMerge);
    },
  );

  test(
    'canonical cloud id is namespaced when a legacy foreign row occupies it',
    () async {
      await _appendChain(sourceDb, 1);
      final payload = (await sourceStore.getBySessionId('session'))!;
      final cloudJson = Map<String, dynamic>.from(
        (payload['runs'] as List).single as Map,
      );
      final canonicalId = 'reconciliation-${cloudJson['contentHash']}';
      cloudJson['id'] = canonicalId;
      payload['runs'] = [cloudJson];

      await targetDb.customStatement(
        'INSERT INTO chat_sessions '
        '(session_id, character_id, session_index, messages_json) '
        'VALUES (?, ?, 1, ?)',
        ['legacy-owner', 'character', jsonEncode(_messages)],
      );
      await targetDb
          .into(targetDb.ledgerReconciliationSuccessfulRuns)
          .insert(
            LedgerReconciliationSuccessfulRunRow.fromJson({
              ...cloudJson,
              'sessionId': 'legacy-owner',
            }),
          );

      await targetStore.mergeBySessionId('session', payload);

      final imported = await LedgerReconciliationRunRepo(
        targetDb,
      ).readSession('session');
      expect(imported, hasLength(1));
      expect(
        imported.single.id,
        'reconciliation-${computeHash('session\u001f${imported.single.contentHash}')}',
      );
      final occupied = await (targetDb.select(
        targetDb.ledgerReconciliationSuccessfulRuns,
      )..where((row) => row.id.equals(canonicalId))).getSingle();
      expect(occupied.sessionId, 'legacy-owner');
    },
  );

  test(
    'a stale shorter incoming chain never truncates local history',
    () async {
      await _appendChain(sourceDb, 2);
      final localRuns = await _appendChain(targetDb, 3);

      await targetStore.mergeBySessionId(
        'session',
        (await sourceStore.getBySessionId('session'))!,
      );

      final stored = await LedgerReconciliationRunRepo(
        targetDb,
      ).readSession('session');
      expect(stored.map((row) => row.id), ['run-1', 'run-2', 'run-3']);
      expect(
        (await LedgerReconciliationRunRepo(targetDb).getHead('session'))?.id,
        localRuns.last.id,
      );
    },
  );

  test(
    'divergent chains at the same endpoint converge deterministically',
    () async {
      await _appendChain(
        targetDb,
        1,
        resultPrefix: 'local',
        progressingEndpoints: true,
      );
      await _appendChain(sourceDb, 1, resultPrefix: 'cloud');
      final sourcePayload = (await sourceStore.getBySessionId('session'))!;
      final targetPayload = (await targetStore.getBySessionId('session'))!;

      await Future.wait([
        sourceStore.mergeBySessionId('session', targetPayload),
        targetStore.mergeBySessionId('session', sourcePayload),
      ]);

      expect(
        await targetStore.getBySessionId('session'),
        equals(await sourceStore.getBySessionId('session')),
      );
    },
  );

  test(
    'a divergent incoming chain replaces local when its endpoint is newer',
    () async {
      final incoming = await _appendChain(
        sourceDb,
        3,
        resultPrefix: 'cloud',
        progressingEndpoints: true,
      );
      await _appendChain(targetDb, 1, resultPrefix: 'local');

      await targetStore.mergeBySessionId(
        'session',
        (await sourceStore.getBySessionId('session'))!,
      );

      final stored = await LedgerReconciliationRunRepo(
        targetDb,
      ).readSession('session');
      expect(
        stored.map((run) => run.chainHash),
        incoming.map((run) => run.chainHash),
      );
    },
  );

  test(
    'a divergent stale incoming chain preserves farther local endpoint',
    () async {
      await _appendChain(
        sourceDb,
        1,
        resultPrefix: 'cloud',
        progressingEndpoints: true,
      );
      final local = await _appendChain(
        targetDb,
        3,
        resultPrefix: 'local',
        progressingEndpoints: true,
      );

      final merged = await targetStore.mergeBySessionId(
        'session',
        (await sourceStore.getBySessionId('session'))!,
      );

      expect(
        (merged['runs'] as List).map((run) => (run as Map)['chainHash']),
        local.map((run) => run.chainHash),
      );
    },
  );

  test(
    'a divergent incoming chain replaces a local head absent from chat',
    () async {
      await _appendChain(
        targetDb,
        1,
        resultPrefix: 'local',
        progressingEndpoints: true,
      );
      final incoming = await _appendChain(
        sourceDb,
        2,
        resultPrefix: 'cloud',
        progressingEndpoints: true,
      );
      await _replaceMessages(targetDb, [
        _messages[1],
        _messages[2],
        _messages[3],
        _messages[4],
      ]);

      await targetStore.mergeBySessionId(
        'session',
        (await sourceStore.getBySessionId('session'))!,
      );

      final stored = await LedgerReconciliationRunRepo(
        targetDb,
      ).readSession('session');
      expect(
        stored.map((run) => run.chainHash),
        incoming.map((run) => run.chainHash),
      );
    },
  );

  test(
    'a divergent incoming head absent from chat preserves local state',
    () async {
      await _appendChain(
        sourceDb,
        2,
        resultPrefix: 'cloud',
        progressingEndpoints: true,
      );
      final local = await _appendChain(
        targetDb,
        1,
        resultPrefix: 'local',
        progressingEndpoints: true,
      );
      await _replaceMessages(targetDb, _messages.take(3).toList());

      final merged = await targetStore.mergeBySessionId(
        'session',
        (await sourceStore.getBySessionId('session'))!,
      );

      expect(
        (merged['runs'] as List).map((run) => (run as Map)['chainHash']),
        local.map((run) => run.chainHash),
      );
    },
  );

  test('malformed cloud evidence is discarded without failing sync', () async {
    await _appendChain(
      sourceDb,
      1,
      resultPrefix: 'cloud',
      progressingEndpoints: true,
    );
    await _replaceMessages(sourceDb, [
      _messages[0],
      _messages[1],
      {
        ..._messages[2],
        'content': 'Edited assistant response',
        'swipes': ['Edited assistant response'],
      },
    ]);
    await _replaceMessages(targetDb, [
      _messages[0],
      _messages[1],
      {
        ..._messages[2],
        'content': 'Edited assistant response',
        'swipes': ['Edited assistant response'],
      },
    ]);

    final merged = await targetStore.mergeBySessionId(
      'session',
      (await sourceStore.getBySessionId('session'))!,
    );

    expect(merged['runs'], isEmpty);
    expect(
      await LedgerReconciliationRunRepo(targetDb).getHead('session'),
      equals(null),
    );
  });

  test('completed collector round-trip consumes its valid pair', () async {
    final runs = await _appendChain(sourceDb, 2);
    final collectorRepo = CardEvolutionCollectorRunRepo(sourceDb);
    final claim = await collectorRepo.claim(
      reconciliationRun: await _storedRun(sourceDb, runs.last.id),
      characterId: 'character',
      inputHash: 'collector-input',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
      rangeHash: CardEvolutionCollectorPair(
        await _storedRun(sourceDb, runs.first.id),
        await _storedRun(sourceDb, runs.last.id),
      ).rangeHash,
    );
    expect(
      await collectorRepo.complete(
        id: claim.row!.id,
        ownerId: 'owner',
        modelOutputHash: 'output',
        now: 11,
      ),
      isTrue,
    );

    await targetStore.mergeBySessionId(
      'session',
      (await sourceStore.getBySessionId('session'))!,
    );

    expect(
      await CardEvolutionCollectorRunRepo(
        targetDb,
      ).pendingValidPairs('session'),
      isEmpty,
    );
  });

  test(
    'stale collector provenance is discarded without failing sync',
    () async {
      final runs = await _appendChain(sourceDb, 2);
      await _completeCollector(sourceDb, runs);
      final payload = (await sourceStore.getBySessionId('session'))!;
      final collectors = (payload['collectors'] as List)
          .cast<Map<String, dynamic>>();
      payload['collectors'] = [
        {...collectors.single, 'rangeHash': 'legacy-stale-range'},
      ];

      final merged = await targetStore.mergeBySessionId('session', payload);

      expect(merged['runs'], hasLength(2));
      expect(merged['collectors'], isEmpty);
      expect(
        await CardEvolutionCollectorRunRepo(
          targetDb,
        ).pendingValidPairs('session'),
        hasLength(1),
      );
    },
  );

  test('active collector claims and leases are omitted', () async {
    final runs = await _appendChain(sourceDb, 2);
    final first = await _storedRun(sourceDb, runs.first.id);
    final boundary = await _storedRun(sourceDb, runs.last.id);
    await CardEvolutionCollectorRunRepo(sourceDb).claim(
      reconciliationRun: boundary,
      characterId: 'character',
      inputHash: 'collector-input',
      ownerId: 'active-owner',
      now: 10,
      leaseSeconds: 30,
      rangeHash: CardEvolutionCollectorPair(first, boundary).rangeHash,
    );

    final payload = (await sourceStore.getBySessionId('session'))!;
    expect(payload['collectors'], isEmpty);

    await targetStore.mergeBySessionId('session', payload);
    expect(
      await targetDb.select(targetDb.cardEvolutionCollectorRuns).get(),
      isEmpty,
    );
  });

  test(
    'incoming completed collector replaces local claim at boundary',
    () async {
      final sourceRuns = await _appendChain(sourceDb, 2);
      final targetRuns = await _appendChain(targetDb, 2);
      final completed = await _completeCollector(sourceDb, sourceRuns);
      final local = await _claimCollector(
        targetDb,
        targetRuns,
        ownerId: 'local',
      );

      await targetStore.mergeBySessionId(
        'session',
        (await sourceStore.getBySessionId('session'))!,
      );

      final stored = await targetDb
          .select(targetDb.cardEvolutionCollectorRuns)
          .get();
      expect(stored, hasLength(1));
      expect(stored.single.id, completed.id);
      expect(stored.single.status, 'completed');
      expect(stored.single.ownerId, 'cloud-sync');
      expect(stored.single.id, isNot(local.id));
    },
  );

  test(
    'incoming completed collector replaces failed boundary at another ordinal',
    () async {
      final sourceRuns = await _appendChain(sourceDb, 2);
      final targetRuns = await _appendChain(targetDb, 2);
      await _insertFailedCollectorPlaceholder(sourceDb);
      final completed = await _completeCollector(sourceDb, sourceRuns);
      final local = await _claimCollector(
        targetDb,
        targetRuns,
        ownerId: 'local',
      );
      expect(
        await CardEvolutionCollectorRunRepo(targetDb).markFailed(
          id: local.id,
          ownerId: 'local',
          now: 12,
          code: 'httpError',
        ),
        isTrue,
      );
      expect(local.collectorOrdinal, 1);
      expect(completed.collectorOrdinal, 2);
      expect(local.reconciliationRunId, completed.reconciliationRunId);

      await targetStore.mergeBySessionId(
        'session',
        (await sourceStore.getBySessionId('session'))!,
      );

      final stored = await targetDb
          .select(targetDb.cardEvolutionCollectorRuns)
          .get();
      expect(stored, hasLength(1));
      expect(stored.single.id, completed.id);
      expect(stored.single.collectorOrdinal, 2);
      expect(stored.single.status, 'completed');
      expect(stored.single.ownerId, 'cloud-sync');
    },
  );

  test('conflicting manifest entry evidence rolls back the merge', () async {
    await _appendChain(sourceDb, 1);
    await _appendChain(targetDb, 1);
    await _insertManifestEvidence(sourceDb, evidence: '{"source":true}');
    await _insertManifestEvidence(targetDb, evidence: '{"target":true}');
    await sourceDb.customStatement(
      'INSERT INTO lorebook_use_manifests '
      '(session_id, message_id, swipe_id, agent_swipe_id, manifest_json, '
      'manifest_hash, manifest_schema_version, final_prompt_hash, '
      'preset_snapshot_hash, created_at) VALUES (?, ?, 0, 0, ?, ?, 1, ?, ?, 2)',
      ['session', 'user-1', '{}', 'second', 'prompt', 'preset'],
    );
    final before = (await targetStore.getBySessionId('session'))!;

    await expectLater(
      targetStore.mergeBySessionId(
        'session',
        (await sourceStore.getBySessionId('session'))!,
      ),
      throwsStateError,
    );

    expect(await targetStore.getBySessionId('session'), equals(before));
  });

  test('newer observation lifecycle wins and converges', () async {
    await _appendChain(sourceDb, 2);
    await _appendChain(targetDb, 2);
    await _insertObservation(
      sourceDb,
      id: 'source-observation',
      runOrdinal: 2,
      clusters: const [
        ['message-3', 'message-2'],
      ],
      retrievalKeys: const ['npc:Alice', 'trait:trust'],
      confidence: 0.8,
      status: 'promoted',
      firstSeenRun: 2,
      lastConfirmedRun: 5,
      updatedAt: 20,
    );
    await _insertObservation(
      targetDb,
      id: 'target-observation',
      runOrdinal: 1,
      clusters: const [
        ['message-1'],
      ],
      retrievalKeys: const ['npc:Alice', 'arc:alliance'],
      confidence: 0.6,
      status: 'consumed',
      firstSeenRun: 1,
      lastConfirmedRun: 4,
      updatedAt: 10,
    );
    final sourcePayload = (await sourceStore.getBySessionId('session'))!;
    final targetPayload = (await targetStore.getBySessionId('session'))!;

    await Future.wait([
      sourceStore.mergeBySessionId('session', targetPayload),
      targetStore.mergeBySessionId('session', sourcePayload),
    ]);

    final source = (await sourceStore.getBySessionId('session'))!;
    final target = (await targetStore.getBySessionId('session'))!;
    expect(target['observations'], equals(source['observations']));
    final observation = (target['observations'] as List).single as Map;
    expect(jsonDecode(observation['evidenceClustersJson'] as String), [
      ['message-3', 'message-2'],
    ]);
    expect(jsonDecode(observation['retrievalKeysJson'] as String), [
      'npc:Alice',
      'trait:trust',
    ]);
    expect(observation, containsPair('confidence', 0.8));
    expect(observation, containsPair('firstSeenRun', 2));
    expect(observation, containsPair('lastConfirmedRun', 5));
    expect(observation, containsPair('status', 'promoted'));
  });

  test(
    'incoming completed claim replaces failed claim with same input',
    () async {
      final runs = await _appendChain(sourceDb, 2);
      await _appendChain(targetDb, 2);
      final collector = await _completeCollector(sourceDb, runs);
      await _insertCompletedClaim(sourceDb, collector);
      await targetDb
          .into(targetDb.cardEvolutionClaims)
          .insert(
            CardEvolutionClaimsCompanion.insert(
              id: 'failed-claim',
              sessionId: 'session',
              characterId: 'character',
              ownerId: 'local',
              status: 'failed',
              leaseExpiresAt: 0,
              chatHistoryHash: 'old-history',
              effectiveCanonIdentity: 'old-canon',
              predecessorCursorHash: collector.reconciliationChainHash,
              predecessorRunOrdinal: collector.collectorOrdinal,
              inputHash: 'claim-input',
              selectedInputJson: const Value('{"local":true}'),
              failureCode: const Value('parserRejected'),
              createdAt: 10,
              failedAt: const Value(11),
            ),
          );
      await targetDb
          .into(targetDb.cardEvolutionWriterCalls)
          .insert(
            CardEvolutionWriterCallsCompanion.insert(
              id: 'failed-call',
              claimId: 'failed-claim',
              sessionId: 'session',
              ordinal: 1,
              stage: 'card_writer',
              stageOrdinal: 1,
              status: 'failed',
              prompt: 'old prompt',
              promptHash: 'old-prompt-hash',
              failureCode: const Value('parserRejected'),
              createdAt: 10,
              updatedAt: 11,
              failedAt: const Value(11),
            ),
          );

      await targetStore.mergeBySessionId(
        'session',
        (await sourceStore.getBySessionId('session'))!,
      );

      final claims = await targetDb.select(targetDb.cardEvolutionClaims).get();
      expect(claims, hasLength(1));
      expect(claims.single.id, 'completed-claim');
      expect(claims.single.status, 'completed');
      expect(claims.single.ownerId, 'cloud-sync');
      expect(
        await targetDb.select(targetDb.cardEvolutionWriterCalls).get(),
        isEmpty,
      );
    },
  );

  test('synced invalidation clears derived lane without deleting claims or '
      'resurrecting stale collectors', () async {
    final runs = await _appendChain(sourceDb, 2);
    final collector = await _completeCollector(sourceDb, runs);
    await _insertObservation(sourceDb);
    await _insertCompletedClaim(sourceDb, collector);
    final stalePayload = (await sourceStore.getBySessionId('session'))!;
    await targetStore.mergeBySessionId('session', stalePayload);

    final invalidatedPayload = Map<String, dynamic>.from(stalePayload)
      ..['invalidations'] = [
        {
          'id': 0,
          'sessionId': 'session',
          'runId': runs.last.id,
          'causeMessageId': 'opening-assistant',
          'reason': 'message deleted',
          'createdAt': 30,
        },
      ];
    await targetStore.mergeBySessionId('session', invalidatedPayload);

    expect(
      await targetDb.select(targetDb.cardEvolutionCollectorRuns).get(),
      isEmpty,
    );
    expect(
      await targetDb.select(targetDb.cardEvolutionObservations).get(),
      isEmpty,
    );
    expect(
      await targetDb.select(targetDb.cardEvolutionClaims).get(),
      hasLength(1),
    );

    await targetStore.mergeBySessionId('session', stalePayload);
    expect(
      await targetDb.select(targetDb.cardEvolutionCollectorRuns).get(),
      isEmpty,
    );
    expect(
      await targetDb.select(targetDb.cardEvolutionClaims).get(),
      hasLength(1),
    );
  });

  test(
    'synced invalidation still imports unaffected completed collectors',
    () async {
      final runs = await _appendChain(sourceDb, 4);
      final firstCollector = await _completeCollector(
        sourceDb,
        runs.sublist(0, 2),
      );
      await _completeCollector(sourceDb, runs.sublist(2, 4));
      final payload = (await sourceStore.getBySessionId('session'))!
        ..['invalidations'] = [
          {
            'id': 0,
            'sessionId': 'session',
            'runId': runs.last.id,
            'causeMessageId': 'assistant-3',
            'reason': 'message_evidence_changed',
            'createdAt': 30,
          },
        ];

      await targetStore.mergeBySessionId('session', payload);

      final collectors = await targetDb
          .select(targetDb.cardEvolutionCollectorRuns)
          .get();
      expect(collectors, hasLength(1));
      expect(
        collectors.single.reconciliationRunId,
        firstCollector.reconciliationRunId,
      );
      expect(collectors.single.ownerId, 'cloud-sync');
    },
  );
}

Future<void> _seedSession(AppDatabase db) => db.customStatement(
  'INSERT INTO chat_sessions '
  '(session_id, character_id, session_index, messages_json) '
  'VALUES (?, ?, 0, ?)',
  ['session', 'character', jsonEncode(_messages)],
);

Future<void> _replaceMessages(
  AppDatabase db,
  List<Map<String, Object>> messages,
) => db.customStatement(
  'UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?',
  [jsonEncode(messages), 'session'],
);

Future<List<LedgerReconciliationRun>> _appendChain(
  AppDatabase db,
  int count, {
  String resultPrefix = 'result',
  bool progressingEndpoints = false,
}) async {
  final repo = LedgerReconciliationRunRepo(db);
  final runs = <LedgerReconciliationRun>[];
  var predecessor = '';
  for (var ordinal = 1; ordinal <= count; ordinal++) {
    final run = LedgerReconciliationRun(
      id: 'run-$ordinal',
      sessionId: 'session',
      ordinal: ordinal,
      anchors: [
        progressingEndpoints ? _progressAnchor(ordinal) : _openingAnchor,
      ],
      acceptedManifestRefs: const [],
      effectiveCanonStamp: 'stamp-$ordinal',
      effectiveCanonRevision: ordinal,
      effectiveCanonHash: 'canon-$ordinal',
      canonicalResult: {
        'facts': ['$resultPrefix-$ordinal'],
      },
      predecessorChainHash: predecessor,
      contractVersion: 1,
      opsApplied: const [],
      createdAt: ordinal,
    );
    expect(await repo.append(run), isA<ReconciliationRunAppended>());
    runs.add(run);
    predecessor = run.chainHash;
  }
  return runs;
}

Future<LedgerReconciliationSuccessfulRunRow> _storedRun(
  AppDatabase db,
  String id,
) => (db.select(
  db.ledgerReconciliationSuccessfulRuns,
)..where((row) => row.id.equals(id))).getSingle();

Future<CardEvolutionCollectorRunRow> _claimCollector(
  AppDatabase db,
  List<LedgerReconciliationRun> runs, {
  required String ownerId,
}) async {
  final first = await _storedRun(db, runs.first.id);
  final boundary = await _storedRun(db, runs.last.id);
  final claim = await CardEvolutionCollectorRunRepo(db).claim(
    reconciliationRun: boundary,
    characterId: 'character',
    inputHash: 'collector-input',
    ownerId: ownerId,
    now: 10,
    leaseSeconds: 30,
    rangeHash: CardEvolutionCollectorPair(first, boundary).rangeHash,
  );
  return claim.row!;
}

Future<CardEvolutionCollectorRunRow> _completeCollector(
  AppDatabase db,
  List<LedgerReconciliationRun> runs,
) async {
  final row = await _claimCollector(db, runs, ownerId: 'owner');
  expect(
    await CardEvolutionCollectorRunRepo(db).complete(
      id: row.id,
      ownerId: 'owner',
      modelOutputHash: 'output',
      now: 11,
    ),
    isTrue,
  );
  return (db.select(
    db.cardEvolutionCollectorRuns,
  )..where((item) => item.id.equals(row.id))).getSingle();
}

Future<void> _insertFailedCollectorPlaceholder(AppDatabase db) => db
    .into(db.cardEvolutionCollectorRuns)
    .insert(
      CardEvolutionCollectorRunsCompanion.insert(
        id: 'failed-placeholder',
        sessionId: 'session',
        characterId: 'character',
        collectorOrdinal: 1,
        reconciliationRunId: 'obsolete-reconciliation',
        reconciliationRunOrdinal: 1,
        reconciliationChainHash: 'obsolete-chain',
        rangeHash: 'obsolete-range',
        inputHash: 'obsolete-input',
        ownerId: 'owner',
        status: 'failed',
        leaseExpiresAt: 0,
        failureCode: const Value('httpError'),
        createdAt: 9,
        failedAt: const Value(10),
      ),
    );

Future<void> _insertManifestEvidence(
  AppDatabase db, {
  required String evidence,
}) async {
  await db.customStatement(
    'INSERT INTO lorebook_use_manifests '
    '(session_id, message_id, swipe_id, agent_swipe_id, manifest_json, '
    'manifest_hash, manifest_schema_version, final_prompt_hash, '
    'preset_snapshot_hash, created_at) VALUES (?, ?, 0, 0, ?, ?, 1, ?, ?, 1)',
    ['session', 'opening-assistant', '{}', 'manifest', 'prompt', 'preset'],
  );
  await db.customStatement(
    'INSERT INTO lorebook_use_manifest_entries '
    '(session_id, message_id, swipe_id, agent_swipe_id, lorebook_id, '
    'entry_id, entry_order, evidence_json) VALUES (?, ?, 0, 0, ?, ?, 0, ?)',
    ['session', 'opening-assistant', 'lorebook', 'entry', evidence],
  );
}

Future<void> _insertObservation(
  AppDatabase db, {
  String id = 'observation',
  int runOrdinal = 1,
  List<List<String>> clusters = const [
    ['message-1'],
  ],
  List<String> retrievalKeys = const ['npc:Alice'],
  double confidence = 0.5,
  String status = 'active',
  int firstSeenRun = 1,
  int? lastConfirmedRun,
  int updatedAt = 10,
}) => CardEvolutionObservationRepo(db).insertObservation(
  CardEvolutionObservation(
    id: id,
    sessionId: 'session',
    characterId: 'character',
    runOrdinal: runOrdinal,
    semanticScopeKey: 'character.personality.trust',
    observedChange: 'Alice increasingly trusts the protagonist.',
    canonicalClaim: 'Alice trusts the protagonist.',
    evidenceClusters: clusters,
    retrievalKeys: retrievalKeys,
    targetKind: 'main_character_card',
    cardFieldPath: 'personality',
    confidence: confidence,
    status: status,
    firstSeenRun: firstSeenRun,
    repeatCount: clusters.length,
    lastConfirmedRun: lastConfirmedRun,
    createdAt: 10,
    updatedAt: updatedAt,
  ),
);

Future<void> _insertCompletedClaim(
  AppDatabase db,
  CardEvolutionCollectorRunRow collector,
) => db
    .into(db.cardEvolutionClaims)
    .insert(
      CardEvolutionClaimsCompanion.insert(
        id: 'completed-claim',
        sessionId: 'session',
        characterId: 'character',
        ownerId: 'owner',
        status: 'completed',
        leaseExpiresAt: 0,
        chatHistoryHash: 'history',
        effectiveCanonIdentity: 'canon',
        predecessorCursorHash: collector.reconciliationChainHash,
        predecessorRunOrdinal: collector.collectorOrdinal,
        inputHash: 'claim-input',
        rewriteJobId: const Value('rewrite-job'),
        createdAt: 12,
        completedAt: const Value(13),
      ),
    );

const _openingContent = 'Welcome to the story.';
const _messages = [
  {
    'id': 'opening-assistant',
    'role': 'assistant',
    'content': _openingContent,
    'swipes': [_openingContent],
    'agentSwipes': <Object>[],
  },
  {'id': 'user-1', 'role': 'user', 'content': 'Begin.'},
  {
    'id': 'assistant-1',
    'role': 'assistant',
    'content': 'Assistant 1',
    'swipes': ['Assistant 1'],
    'agentSwipes': <Object>[],
  },
  {'id': 'user-2', 'role': 'user', 'content': 'Continue.'},
  {
    'id': 'assistant-2',
    'role': 'assistant',
    'content': 'Assistant 2',
    'swipes': ['Assistant 2'],
    'agentSwipes': <Object>[],
  },
  {'id': 'user-3', 'role': 'user', 'content': 'Continue again.'},
  {
    'id': 'assistant-3',
    'role': 'assistant',
    'content': 'Assistant 3',
    'swipes': ['Assistant 3'],
    'agentSwipes': <Object>[],
  },
];

final _openingAnchor = ReconciliationAnchor(
  messageId: 'opening-assistant',
  swipeId: 0,
  agentSwipeId: 0,
  role: 'assistant',
  contentHash: computeHash(_openingContent),
);

ReconciliationAnchor _progressAnchor(int ordinal) => ReconciliationAnchor(
  messageId: 'assistant-$ordinal',
  swipeId: 0,
  agentSwipeId: 0,
  role: 'assistant',
  contentHash: computeHash('Assistant $ordinal'),
);
