import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_debug_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/features/chat/services/reconciler_view_service.dart';

void main() {
  late AppDatabase db;
  late LedgerReconciliationRunRepo runRepo;
  late ReconcilerViewService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    runRepo = LedgerReconciliationRunRepo(db);
    service = ReconcilerViewService(
      runRepo: runRepo,
      debugRepo: LedgerDebugRunRepo(db),
      checkpointRepo: LedgerReconciliationCheckpointRepo(db),
      chatRepo: ChatRepo(db),
      snapshotRepo: TrackerSnapshotRepo(db),
    );
  });

  tearDown(() => db.close());

  test(
    'projects message ordinals and keeps invalidated physical runs',
    () async {
      await _seedSession(db);
      final run = _run();
      expect(await runRepo.append(run), isA<ReconciliationRunAppended>());
      await LedgerReconciliationCheckpointRepo(db).upsert(
        const LedgerReconciliationCheckpoint(
          sessionId: 'session',
          startMessageId: 'a1',
          endMessageId: 'a2',
          endSwipeId: 0,
          endAgentSwipeId: 0,
          messageIds: ['a1', 'u1', 'a2'],
          rangeHash: 'range',
        ),
      );
      await db.customStatement(
        'INSERT INTO reconciliation_run_invalidations '
        '(session_id, run_id, cause_message_id, reason, created_at) '
        "VALUES ('session', 'run-1', 'a1', 'manual replacement', 20)",
      );

      final snapshot = await service.load('session');

      expect(snapshot.chainIsValid, isTrue);
      expect(snapshot.runs, hasLength(1));
      expect(snapshot.runs.single.firstMessageOrdinal, 1);
      expect(snapshot.runs.single.lastMessageOrdinal, 3);
      expect(snapshot.checkpointEndMessageOrdinal, 3);
      expect(
        snapshot.runs.single.status,
        ReconciliationRunViewStatus.invalidated,
      );
      expect(snapshot.runs.single.invalidation?.reason, 'manual replacement');
    },
  );

  test('reports the exact missing Ledger endpoint for a due range', () async {
    final messages = [
      const {'id': 'a1', 'role': 'assistant', 'content': 'Opening'},
      for (var i = 2; i <= 7; i++) ...[
        {'id': 'u$i', 'role': 'user', 'content': 'User $i'},
        {'id': 'a$i', 'role': 'assistant', 'content': 'Assistant $i'},
      ],
    ];
    await db.customStatement(
      'INSERT INTO chat_sessions '
      '(session_id, character_id, session_index, messages_json) '
      'VALUES (?, ?, ?, ?)',
      ['due', 'character', 0, jsonEncode(messages)],
    );

    var snapshot = await service.load('due');
    expect(snapshot.missingLedgerTarget?.id, 'a6');

    await TrackerSnapshotRepo(db).upsert(
      const TrackerSnapshot(
        sessionId: 'due',
        messageId: 'a6',
        swipeId: 0,
        agentSwipeId: 0,
        trackers: [],
        committed: true,
        createdAt: 1,
      ),
    );
    snapshot = await service.load('due');
    expect(snapshot.missingLedgerTarget, isNull);
  });

  test(
    'returns reconciliation debug rows without normal Ledger rows',
    () async {
      final debugRepo = LedgerDebugRunRepo(db);
      await debugRepo.record(
        const LedgerDebugRun(
          sessionId: 'session',
          kind: LedgerDebugRunKind.normal,
          status: 'ok',
        ),
      );
      await debugRepo.record(
        const LedgerDebugRun(
          sessionId: 'session',
          kind: LedgerDebugRunKind.reconciliation,
          status: 'error',
          parseFailure: 'malformedJson',
        ),
      );

      final snapshot = await service.load('session');

      expect(snapshot.debugRuns, hasLength(1));
      expect(snapshot.debugRuns.single.kind, 'reconciliation');
      expect(snapshot.debugRuns.single.parseFailure, 'malformedJson');
    },
  );
}

Future<void> _seedSession(AppDatabase db) => db.customStatement(
  'INSERT INTO chat_sessions '
  '(session_id, character_id, session_index, messages_json) VALUES (?, ?, ?, ?)',
  [
    'session',
    'character',
    0,
    jsonEncode([
      {'id': 'a1', 'role': 'assistant', 'content': 'opening'},
      {'id': 'u1', 'role': 'user', 'content': 'hello'},
      {'id': 'a2', 'role': 'assistant', 'content': 'reply'},
    ]),
  ],
);

LedgerReconciliationRun _run() => LedgerReconciliationRun(
  id: 'run-1',
  sessionId: 'session',
  ordinal: 1,
  anchors:
      const [
            ReconciliationAnchor(
              messageId: 'a1',
              swipeId: 0,
              agentSwipeId: 0,
              role: 'assistant',
              contentHash: '',
            ),
            ReconciliationAnchor(
              messageId: 'u1',
              swipeId: 0,
              agentSwipeId: 0,
              role: 'user',
              contentHash: '',
            ),
            ReconciliationAnchor(
              messageId: 'a2',
              swipeId: 0,
              agentSwipeId: 0,
              role: 'assistant',
              contentHash: '',
            ),
          ].indexed
          .map(
            (entry) => ReconciliationAnchor(
              messageId: entry.$2.messageId,
              swipeId: 0,
              agentSwipeId: 0,
              role: entry.$2.role,
              contentHash: computeHash(['opening', 'hello', 'reply'][entry.$1]),
            ),
          )
          .toList(),
  acceptedManifestRefs: const [],
  effectiveCanonStamp: 'stamp',
  effectiveCanonRevision: 1,
  effectiveCanonHash: 'canon',
  canonicalResult: const {'export': <String, Object?>{}},
  predecessorChainHash: '',
  contractVersion: 1,
  opsApplied: const ['set:scene.location'],
  createdAt: 10,
);
