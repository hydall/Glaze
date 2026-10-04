import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_debug_run_repo.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';

void main() {
  late AppDatabase db;
  late LedgerDebugRunRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = LedgerDebugRunRepo(db);
  });
  tearDown(() => db.close());

  test('records a rejected response with the reason and repair payload', () async {
    await repo.record(
      LedgerDebugRun(
        sessionId: 'session',
        kind: LedgerDebugRunKind.normal,
        status: 'error',
        messageId: 'message',
        swipeId: 2,
        agentSwipeId: 1,
        model: 'google/gemini-3.7-flash',
        parseFailure: 'malformedJson',
        rejectionReason: 'malformed JSON: unexpected end of input',
        rejectedOps: const ['op[0] set: missing key'],
        repairAttempted: true,
        repairFailure: 'emptyExport',
        responseText: 'first response',
        repairResponseText: 'repair response',
        attempts: const [
          AgentOperationAttempt(
            attempt: 1,
            statusCode: 200,
            status: 'ok',
            startedAtMs: 5,
            elapsedMs: 30,
          ),
        ],
        error: 'export rejected',
        elapsedMs: 1200,
        promptChars: 900,
        responseChars: 400,
      ),
    );

    final rows = await repo.recentForSession('session');
    expect(rows, hasLength(1));
    final row = rows.single;
    expect(row.kind, 'normal');
    expect(row.messageId, 'message');
    expect(row.swipeId, 2);
    expect(row.agentSwipeId, 1);
    expect(row.parseFailure, 'malformedJson');
    expect(row.rejectionReason, 'malformed JSON: unexpected end of input');
    expect(jsonDecode(row.rejectedOpsJson), ['op[0] set: missing key']);
    // The silent second call is the whole point of the journal.
    expect(row.repairAttempted, isTrue);
    expect(row.repairFailure, 'emptyExport');
    expect(row.responseText, 'first response');
    expect(row.repairResponseText, 'repair response');
    expect(jsonDecode(row.attemptsJson), hasLength(1));
    expect(row.error, 'export rejected');
  });

  test('truncates oversized payloads instead of storing them whole', () async {
    final huge = 'x' * (LedgerDebugRunRepo.maxStoredTextChars + 500);
    await repo.record(
      LedgerDebugRun(
        sessionId: 'session',
        kind: LedgerDebugRunKind.reconciliation,
        status: 'ok',
        responseText: huge,
      ),
    );

    final row = (await repo.recentForSession('session')).single;
    expect(row.responseText, isNotNull);
    expect(
      row.responseText!.length,
      lessThan(LedgerDebugRunRepo.maxStoredTextChars + 100),
    );
    expect(row.responseText, endsWith('[truncated]'));
  });

  test('keeps the journal bounded per session', () async {
    for (var i = 0; i < LedgerDebugRunRepo.maxRunsPerSession + 5; i++) {
      await repo.record(
        LedgerDebugRun(
          sessionId: 'session',
          kind: LedgerDebugRunKind.normal,
          status: 'ok',
          messageId: 'message-$i',
        ),
      );
    }
    await repo.record(
      const LedgerDebugRun(
        sessionId: 'other',
        kind: LedgerDebugRunKind.normal,
        status: 'ok',
      ),
    );

    final kept = await db
        .customSelect(
          "SELECT COUNT(*) AS c FROM ledger_debug_runs "
          "WHERE session_id = 'session'",
        )
        .getSingle();
    expect(kept.read<int>('c'), LedgerDebugRunRepo.maxRunsPerSession);
    // Trimming is scoped to the session that just wrote.
    final others = await repo.recentForSession('other');
    expect(others, hasLength(1));
  });

  test('a rejected write never surfaces as a Ledger failure', () async {
    // An empty status violates the table CHECK; the repo must swallow it.
    await repo.record(
      const LedgerDebugRun(
        sessionId: 'session',
        kind: LedgerDebugRunKind.normal,
        status: '',
      ),
    );
    expect(await repo.recentForSession('session'), isEmpty);
  });

  test('deletes a session journal', () async {
    await repo.record(
      const LedgerDebugRun(
        sessionId: 'session',
        kind: LedgerDebugRunKind.normal,
        status: 'ok',
      ),
    );
    await repo.deleteBySessionId('session');
    expect(await repo.recentForSession('session'), isEmpty);
  });
}
