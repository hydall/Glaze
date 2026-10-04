import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/reconciliation_replacement_repo.dart';

void main() {
  late AppDatabase db;
  late ReconciliationReplacementRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = ReconciliationReplacementRepo(db);
  });

  tearDown(() => db.close());

  test(
    'applied linked proposal blocks and malformed applied fails closed',
    () async {
      await _insertProposal(db, jobId: 'linked', status: 'applied');
      expect(
        await repo.hasAppliedDependency(
          sessionId: 'session',
          reconciliationRunId: 'run',
        ),
        isTrue,
      );
      await db.delete(db.cardEvolutionProposalRuns).go();
      await db
          .into(db.cardEvolutionProposalRuns)
          .insert(
            CardEvolutionProposalRunsCompanion.insert(
              id: 'malformed',
              claimId: 'malformed-claim',
              sessionId: 'session',
              characterId: 'character',
              rewriteJobId: 'linked',
              chatHistoryHash: 'first',
              effectiveCanonIdentity: 'second',
              selectedInputJson: '{',
              inputHash: 'malformed-input',
              modelOutput: '{}',
              modelOutputHash: 'output',
              operationSnapshotJson: '{}',
              createdAt: 1,
            ),
          );
      expect(
        await repo.hasAppliedDependency(
          sessionId: 'session',
          reconciliationRunId: 'other-run',
        ),
        isTrue,
      );
    },
  );

  test('reset cancels pending proposal and removes only recoverable state', () async {
    await _insertProposal(db, jobId: 'pending', status: 'pending');
    await db.customStatement(
      "INSERT INTO card_evolution_collector_runs "
      "(id, session_id, character_id, collector_ordinal, reconciliation_run_id, reconciliation_run_ordinal, reconciliation_chain_hash, range_hash, input_hash, owner_id, status, lease_expires_at, created_at) "
      "VALUES ('collector', 'session', 'character', 1, 'run', 1, 'chain', 'range', 'input', 'owner', 'completed', 0, 1)",
    );
    await db.customStatement(
      "INSERT INTO card_evolution_observations "
      "(id, session_id, character_id, run_ordinal, semantic_scope_key, observed_change, evidence_message_ids, confidence, status, first_seen_run, created_at, updated_at) "
      "VALUES ('observation', 'session', 'character', 1, 'scope', 'change', '[]', 1, 'active', 1, 1, 1)",
    );
    await db.customStatement(
      "INSERT INTO ledger_reconciliation_cursors VALUES ('session', 1, '', 'run', 1, 'chain', 'cursor', 1)",
    );
    await _insertClaim(db, id: 'recoverable', status: 'failed');
    await _insertClaim(
      db,
      id: 'preserved',
      status: 'completed',
      rewriteJobId: 'pending',
    );
    await _insertWriterCall(db, claimId: 'recoverable');
    await _insertWriterCall(db, claimId: 'preserved');

    await db.transaction(
      () => repo.resetDownstreamInTransaction(
        sessionId: 'session',
        reconciliationRunId: 'run',
        now: 10,
      ),
    );

    final job = await db.select(db.rewriteJobs).getSingle();
    expect(job.status, 'cancelled');
    expect(job.statusReason, 'reconciliationReplaced');
    expect(job.version, 2);
    expect(await db.select(db.cardEvolutionProposalRuns).get(), hasLength(1));
    expect(await db.select(db.rewriteOperations).get(), hasLength(1));
    expect(await db.select(db.rewriteOperationRevisions).get(), hasLength(1));
    expect(await db.select(db.rewriteEvidenceRows).get(), hasLength(1));
    expect(await db.select(db.cardEvolutionCollectorRuns).get(), isEmpty);
    expect(await db.select(db.cardEvolutionObservations).get(), isEmpty);
    expect(await db.select(db.ledgerReconciliationCursors).get(), isEmpty);
    expect(
      (await db.select(db.cardEvolutionClaims).get()).map((row) => row.id),
      ['preserved'],
    );
    expect(
      (await db.select(db.cardEvolutionWriterCalls).get()).map(
        (row) => row.claimId,
      ),
      ['preserved'],
    );
  });
}

Future<void> _insertProposal(
  AppDatabase db, {
  required String jobId,
  required String status,
}) async {
  await db
      .into(db.rewriteJobs)
      .insert(
        RewriteJobsCompanion.insert(
          id: jobId,
          chatSessionId: 'session',
          characterId: 'character',
          status: Value(status),
        ),
      );
  await db
      .into(db.rewriteOperations)
      .insert(
        RewriteOperationsCompanion.insert(
          id: 'operation-$jobId',
          rewriteJobId: jobId,
          chatSessionId: 'session',
        ),
      );
  await db.customStatement(
    'INSERT INTO rewrite_operation_revisions '
    '(rewrite_operation_id, revision, snapshot_json, created_at) '
    "VALUES ('operation-$jobId', 1, '{}', 1)",
  );
  await db.customStatement(
    'INSERT INTO rewrite_evidence_rows '
    '(id, rewrite_operation_id, evidence_json, created_at) '
    "VALUES ('evidence-$jobId', 'operation-$jobId', '{}', 1)",
  );
  final selected = jsonEncode({
    'limits': {
      'reconciliationRunIds': ['run'],
    },
  });
  await db
      .into(db.cardEvolutionProposalRuns)
      .insert(
        CardEvolutionProposalRunsCompanion.insert(
          id: 'proposal-$jobId',
          claimId: 'proposal-claim-$jobId',
          sessionId: 'session',
          characterId: 'character',
          rewriteJobId: jobId,
          chatHistoryHash: 'first',
          effectiveCanonIdentity: 'second',
          selectedInputJson: selected,
          inputHash: 'input-$jobId',
          modelOutput: '{}',
          modelOutputHash: 'output',
          operationSnapshotJson: '{}',
          createdAt: 1,
        ),
      );
}

Future<void> _insertClaim(
  AppDatabase db, {
  required String id,
  required String status,
  String? rewriteJobId,
}) => db
    .into(db.cardEvolutionClaims)
    .insert(
      CardEvolutionClaimsCompanion.insert(
        id: id,
        sessionId: 'session',
        characterId: 'character',
        ownerId: 'owner',
        status: status,
        leaseExpiresAt: 0,
        chatHistoryHash: 'first-$id',
        effectiveCanonIdentity: 'second-$id',
        predecessorCursorHash: '',
        predecessorRunOrdinal: 0,
        inputHash: 'claim-input-$id',
        rewriteJobId: Value(rewriteJobId),
        createdAt: 1,
      ),
    );

Future<void> _insertWriterCall(AppDatabase db, {required String claimId}) => db
    .into(db.cardEvolutionWriterCalls)
    .insert(
      CardEvolutionWriterCallsCompanion.insert(
        id: 'call-$claimId',
        claimId: claimId,
        sessionId: 'session',
        ordinal: 1,
        stage: 'card_writer',
        stageOrdinal: 1,
        status: 'prepared',
        prompt: 'prompt',
        promptHash: 'hash',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
