import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_collector_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';

void main() {
  late AppDatabase db;
  late CardEvolutionCollectorRunRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = CardEvolutionCollectorRunRepo(db);
  });

  tearDown(() => db.close());

  test('failed claim remains durable and requires explicit recovery', () async {
    final run = _run();
    final claim = await repo.claim(
      reconciliationRun: run,
      characterId: 'character',
      inputHash: 'input',
      ownerId: 'owner-1',
      now: 10,
      leaseSeconds: 60,
    );

    expect(
      await repo.markFailed(
        id: claim.row!.id,
        ownerId: 'owner-1',
        now: 20,
        code: 'parserRejected',
        detail: 'invalid JSON',
        callId: 'call-1',
      ),
      isTrue,
    );
    final failed = await repo.getById(claim.row!.id);
    expect(failed?.status, 'failed');
    expect(failed?.failureCode, 'parserRejected');
    expect(failed?.failureDetail, 'invalid JSON');
    expect(failed?.lastCallId, 'call-1');
    expect(await repo.latestCompletedOrdinal('session'), 0);

    final automatic = await repo.claim(
      reconciliationRun: run,
      characterId: 'character',
      inputHash: 'input',
      ownerId: 'owner-2',
      now: 21,
      leaseSeconds: 60,
    );
    expect(automatic.kind, 'failed');

    final reclaimed = await repo.claimFailed(
      id: claim.row!.id,
      ownerId: 'owner-2',
      now: 21,
      leaseSeconds: 60,
    );
    expect(reclaimed.kind, 'claimed');
    expect(reclaimed.row?.id, claim.row?.id);
    expect(reclaimed.row?.collectorOrdinal, 1);
    expect(reclaimed.row?.status, 'claimed');
    expect(reclaimed.row?.ownerId, 'owner-2');
    expect(reclaimed.row?.failureCode, isNull);
  });

  test('wrong owner cannot mark a live claim failed', () async {
    final claim = await repo.claim(
      reconciliationRun: _run(),
      characterId: 'character',
      inputHash: 'input',
      ownerId: 'owner-1',
      now: 10,
      leaseSeconds: 60,
    );

    expect(
      await repo.markFailed(
        id: claim.row!.id,
        ownerId: 'owner-2',
        now: 20,
        code: 'transportFailed',
      ),
      isFalse,
    );
    expect((await repo.getById(claim.row!.id))?.status, 'claimed');
  });

  test('expired claim can be reclaimed with refreshed input', () async {
    final first = await repo.claim(
      reconciliationRun: _run(),
      characterId: 'character',
      inputHash: 'old-input',
      ownerId: 'owner-1',
      now: 10,
      leaseSeconds: 60,
    );

    final reclaimed = await repo.claim(
      reconciliationRun: _run(),
      characterId: 'character',
      inputHash: 'new-input',
      ownerId: 'owner-2',
      now: 71,
      leaseSeconds: 60,
    );

    expect(reclaimed.kind, 'existing');
    expect(reclaimed.row?.id, first.row?.id);
    expect(reclaimed.row?.ownerId, 'owner-2');
    expect(reclaimed.row?.inputHash, 'new-input');
    expect(reclaimed.row?.leaseExpiresAt, 131);
  });

  test('live claim rejects refreshed input', () async {
    await repo.claim(
      reconciliationRun: _run(),
      characterId: 'character',
      inputHash: 'old-input',
      ownerId: 'owner-1',
      now: 10,
      leaseSeconds: 60,
    );

    final outcome = await repo.claim(
      reconciliationRun: _run(),
      characterId: 'character',
      inputHash: 'new-input',
      ownerId: 'owner-1',
      now: 20,
      leaseSeconds: 60,
    );

    expect(outcome.kind, 'staleInput');
  });
}

LedgerReconciliationSuccessfulRunRow _run() {
  final run = LedgerReconciliationRun(
    id: 'run',
    sessionId: 'session',
    ordinal: 2,
    anchors: const [
      ReconciliationAnchor(
        messageId: 'a1',
        swipeId: 0,
        agentSwipeId: 0,
        role: 'assistant',
        contentHash: 'content',
      ),
    ],
    acceptedManifestRefs: const [],
    effectiveCanonStamp: 'stamp',
    effectiveCanonRevision: 1,
    effectiveCanonHash: 'canon',
    canonicalResult: const {},
    predecessorChainHash: 'predecessor',
    contractVersion: 1,
    opsApplied: const [],
    createdAt: 1,
  );
  return LedgerReconciliationSuccessfulRunRow(
    id: run.id,
    sessionId: run.sessionId,
    ordinal: run.ordinal,
    startMessageId: run.start.messageId,
    startSwipeId: run.start.swipeId,
    startAgentSwipeId: run.start.agentSwipeId,
    endMessageId: run.end.messageId,
    endSwipeId: run.end.swipeId,
    endAgentSwipeId: run.end.agentSwipeId,
    anchorsJson: run.anchorsJson,
    rangeHash: run.rangeHash,
    acceptedManifestRefsJson: run.manifestsJson,
    effectiveCanonStamp: run.effectiveCanonStamp,
    effectiveCanonRevision: run.effectiveCanonRevision,
    effectiveCanonHash: run.effectiveCanonHash,
    canonicalResultJson: run.resultJson,
    contentHash: run.contentHash,
    predecessorChainHash: run.predecessorChainHash,
    chainHash: run.chainHash,
    contractVersion: run.contractVersion,
    opsAppliedJson: run.opsJson,
    createdAt: run.createdAt,
  );
}
