import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

void main() {
  late AppDatabase db;
  late LedgerReconciliationRunRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = LedgerReconciliationRunRepo(db);
  });
  tearDown(() => db.close());

  test('appends genesis at ordinal one, replays exactly, and chains', () async {
    await _seedSession(db);
    final first = _run();
    expect(await repo.append(first), isA<ReconciliationRunAppended>());
    expect(await repo.append(first), isA<ReconciliationRunIdempotent>());
    final second = _run(
      id: 'run-2',
      ordinal: 2,
      predecessor: first.chainHash,
      result: const {
        'facts': ['second'],
      },
    );
    expect(await repo.append(second), isA<ReconciliationRunAppended>());
    expect((await repo.readSession('session')).map((r) => r.ordinal), [1, 2]);
    expect((await repo.getHead('session'))!.id, 'run-2');
  });

  test('candidate replay keeps the stored legacy identity', () async {
    await _seedSession(db);
    final stored = _run(id: 'legacy-id');
    expect(await repo.append(stored), isA<ReconciliationRunAppended>());

    expect(
      await repo.appendCandidate(_run(id: 'new-draft-id')),
      isA<ReconciliationRunIdempotent>(),
    );
    expect((await repo.getHead('session'))!.id, 'legacy-id');
  });

  test(
    'branch copy rebuilds session-bound identities without replacing source',
    () async {
      await _seedSession(db);
      await db.customStatement(
        "INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) "
        "SELECT 'branch', character_id, 1, messages_json FROM chat_sessions WHERE session_id = 'session'",
      );
      final source = _run();
      expect(await repo.append(source), isA<ReconciliationRunAppended>());

      await repo.copyForSessionBranch(
        fromSessionId: 'session',
        toSessionId: 'branch',
        messageIds: {'message', 'user'},
      );

      final sourceRows = await repo.readSession('session');
      final branchRows = await repo.readSession('branch');
      expect(sourceRows.single.id, source.id);
      expect(branchRows, hasLength(1));
      expect(branchRows.single.id, isNot(source.id));
      expect(
        branchRows.single.id,
        'reconciliation-${branchRows.single.contentHash}',
      );
      expect(branchRows.single.sessionId, 'branch');
      expect(await repo.validateChain('branch'), isA<ReconciliationRunValid>());
    },
  );

  test(
    'rejects anchor mutations and immutable content-hash collisions',
    () async {
      await _seedSession(db);
      final first = _run();
      expect(await repo.append(first), isA<ReconciliationRunAppended>());
      expect(
        await repo.append(_run(id: 'other', createdAt: 2)),
        isA<ReconciliationRunConflict>(),
      );
      expect(
        await repo.append(
          _run(
            id: 'bad',
            anchors: [_anchor(content: 'wrong')],
          ),
        ),
        isA<ReconciliationRunMalformed>(),
      );
    },
  );

  test('content hash binds every canonical evidence projection', () {
    final baseline = _run();
    final anchor = _anchor();
    final variants = [
      _run(
        anchors: [
          ReconciliationAnchor(
            messageId: anchor.messageId,
            swipeId: 1,
            agentSwipeId: anchor.agentSwipeId,
            role: anchor.role,
            contentHash: anchor.contentHash,
          ),
        ],
      ),
      _run(
        anchors: [
          ReconciliationAnchor(
            messageId: anchor.messageId,
            swipeId: anchor.swipeId,
            agentSwipeId: 1,
            role: anchor.role,
            contentHash: anchor.contentHash,
          ),
        ],
      ),
      _run(
        anchors: [
          ReconciliationAnchor(
            messageId: anchor.messageId,
            swipeId: anchor.swipeId,
            agentSwipeId: anchor.agentSwipeId,
            role: 'user',
            contentHash: anchor.contentHash,
          ),
        ],
      ),
      _run(
        anchors: [
          ReconciliationAnchor(
            messageId: anchor.messageId,
            swipeId: anchor.swipeId,
            agentSwipeId: anchor.agentSwipeId,
            role: anchor.role,
            contentHash: 'other',
          ),
        ],
      ),
      _run(
        anchors: [
          _anchor(),
          _anchor(messageId: 'later'),
        ],
      ),
      _run(
        acceptedManifestRefs: const [
          AcceptedManifestRef(
            sessionId: 'session',
            messageId: 'message',
            swipeId: 0,
            agentSwipeId: 0,
            manifestHash: 'manifest',
            acceptanceId: 'acceptance',
            acceptedByUserMessageId: 'user',
          ),
        ],
      ),
      _run(effectiveCanonStamp: 'other-stamp'),
      _run(effectiveCanonHash: 'other-canon'),
      _run(
        result: const {
          'facts': ['other'],
        },
      ),
    ];
    for (final variant in variants) {
      expect(variant.contentHash, isNot(baseline.contentHash));
    }
  });

  test(
    'stored malformed JSON and predecessor chain mismatch fail closed',
    () async {
      await _seedSession(db);
      final first = _run();
      expect(await repo.append(first), isA<ReconciliationRunAppended>());
      await db.customStatement(
        'DROP TRIGGER reconciliation_successful_runs_no_update',
      );
      await db.customStatement(
        "UPDATE reconciliation_successful_runs SET anchors_json = '[]' WHERE id = 'run-1'",
      );
      expect(await repo.readSession('session'), isEmpty);

      await db.customStatement(
        "UPDATE reconciliation_successful_runs SET anchors_json = ?, range_hash = ?, content_hash = ?, chain_hash = ?, predecessor_chain_hash = 'wrong' WHERE id = 'run-1'",
        [
          first.anchorsJson,
          first.rangeHash,
          first.contentHash,
          first.chainHash,
        ],
      );
      expect(
        await repo.validateChain('session'),
        isA<ReconciliationRunChainGap>(),
      );
      expect(await repo.readSession('session'), isEmpty);
    },
  );

  test(
    'read excludes invalidations and cursor genesis fails closed on gap',
    () async {
      await _seedSession(db);
      final first = _run();
      expect(await repo.append(first), isA<ReconciliationRunAppended>());
      await db.customStatement(
        "INSERT INTO reconciliation_run_invalidations "
        "(session_id, run_id, cause_message_id, reason, created_at) "
        "VALUES ('session', 'run-1', 'message', 'deleted', 1)",
      );
      expect(await repo.readSession('session'), isEmpty);
      final hash = _cursorHash(sequence: 1, predecessor: '');
      await db.customStatement(
        "INSERT INTO ledger_reconciliation_cursors VALUES "
        "('session', 1, '', 'run-1', 1, 'chain-1', '$hash', 1)",
      );
      expect(await repo.readCursors('session'), isEmpty);
      await db.customStatement(
        "INSERT INTO ledger_reconciliation_cursors VALUES "
        "('session', 3, '$hash', 'run-3', 3, 'chain-3', 'bad', 1)",
      );
      expect(await repo.readCursors('session'), isEmpty);
    },
  );

  test('serializes all seven authoritative variation-ref fields', () async {
    await _seedSession(db);
    await _seedVariationEvidence(db);
    final refs = await repo.readAcceptedManifestRefs(
      sessionId: 'session',
      anchors: [_anchor()],
    );
    expect(refs, hasLength(1));
    expect(refs.single.toJson(), {
      'acceptanceId': 'variation:session:user',
      'sessionId': 'session',
      'messageId': 'message',
      'swipeId': 0,
      'agentSwipeId': 0,
      'manifestHash': 'manifest-hash',
      'acceptedByUserMessageId': 'user',
    });
    expect(jsonDecode(_run(acceptedManifestRefs: refs).manifestsJson), [
      refs.single.toJson(),
    ]);
  });

  test('selection-only evidence emits no accepted manifest refs', () async {
    await _seedSession(db);
    await _seedVariationEvidence(db, kind: 'selection');
    // The immutable schema requires a variation before recording selection;
    // remove it after insertion to leave selection-only durable evidence.
    await db.customStatement(
      "DELETE FROM lorebook_use_acceptance_records "
      "WHERE acceptance_id = 'variation:session:user'",
    );
    expect(
      await repo.readAcceptedManifestRefs(
        sessionId: 'session',
        anchors: [_anchor()],
      ),
      isEmpty,
    );
  });

  test(
    'wrong acceptance identity, accepting user, or manifest rejects append',
    () async {
      await _seedSession(db);
      await _seedVariationEvidence(db);
      final ref = (await repo.readAcceptedManifestRefs(
        sessionId: 'session',
        anchors: [_anchor()],
      )).single;
      for (final bad in [
        AcceptedManifestRef(
          acceptanceId: 'wrong',
          sessionId: 'session',
          messageId: 'message',
          swipeId: 0,
          agentSwipeId: 0,
          manifestHash: 'manifest-hash',
          acceptedByUserMessageId: 'user',
        ),
        AcceptedManifestRef(
          acceptanceId: ref.acceptanceId,
          sessionId: 'session',
          messageId: 'message',
          swipeId: 0,
          agentSwipeId: 0,
          manifestHash: 'manifest-hash',
          acceptedByUserMessageId: 'missing-user',
        ),
        AcceptedManifestRef(
          acceptanceId: ref.acceptanceId,
          sessionId: 'session',
          messageId: 'message',
          swipeId: 0,
          agentSwipeId: 0,
          manifestHash: 'wrong-hash',
          acceptedByUserMessageId: 'user',
        ),
      ]) {
        expect(
          await repo.append(
            _run(
              id: 'bad-${bad.acceptanceId}-${bad.manifestHash}',
              acceptedManifestRefs: [bad],
            ),
          ),
          isA<ReconciliationRunMalformed>(),
        );
      }
      expect(await repo.readSession('session'), isEmpty);
    },
  );

  test(
    'invalidated physical head allocates ordinal two with predecessor',
    () async {
      await _seedSession(db);
      final first = _run();
      expect(await repo.append(first), isA<ReconciliationRunAppended>());
      await db.customStatement(
        "INSERT INTO reconciliation_run_invalidations "
        "(session_id, run_id, cause_message_id, reason, created_at) "
        "VALUES ('session', 'run-1', 'message', 'deleted', 1)",
      );
      final candidate = _run(
        id: 'run-2',
        result: const {
          'facts': ['distinct'],
        },
      );
      expect(
        await repo.appendCandidate(candidate),
        isA<ReconciliationRunAppended>(),
      );
      final rows = await db.select(db.ledgerReconciliationSuccessfulRuns).get();
      final second = rows.singleWhere(
        (row) => row.contentHash == candidate.contentHash,
      );
      expect(second.ordinal, 2);
      expect(second.predecessorChainHash, first.chainHash);
    },
  );

  test('message mutation invalidates anchored run suffix, not trigger', () async {
    await _seedSession(db);
    final first = _run();
    expect(await repo.append(first), isA<ReconciliationRunAppended>());

    expect(
      await repo.invalidateForMessageMutation(
        sessionId: 'session',
        messageIds: {'user'},
        reason: 'message_deleted',
        createdAt: 2,
      ),
      isEmpty,
    );
    expect((await repo.getHead('session'))?.id, 'run-1');

    final invalidated = await repo.invalidateForMessageMutation(
      sessionId: 'session',
      messageIds: {'message'},
      reason: 'message_deleted',
      createdAt: 3,
    );
    expect(invalidated, ['run-1']);
    expect(await repo.getHead('session'), isNull);

    await db.customStatement(
      "UPDATE chat_sessions SET messages_json = '[{\"id\":\"user\",\"role\":\"user\",\"content\":\"accepted\"}]' WHERE session_id = 'session'",
    );
    expect(await repo.validateChain('session'), isA<ReconciliationRunValid>());
  });

  test(
    'legacy stale evidence hides logical suffix without breaking chain',
    () async {
      await _seedSession(db);
      expect(await repo.append(_run()), isA<ReconciliationRunAppended>());
      await db.customStatement(
        "UPDATE chat_sessions SET messages_json = '[{\"id\":\"user\",\"role\":\"user\",\"content\":\"accepted\"}]' WHERE session_id = 'session'",
      );
      expect(
        await repo.validateChain('session'),
        isA<ReconciliationRunValid>(),
      );
      expect(await repo.readSession('session'), isEmpty);
      expect(await repo.getHead('session'), isNull);
    },
  );
}

Future<void> _seedSession(AppDatabase db) => db.customStatement(
  "INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) "
  "VALUES ('session', 'character', 0, '[{\"id\":\"message\",\"role\":\"assistant\",\"content\":\"canonical\",\"swipes\":[\"canonical\"],\"agentSwipes\":[]},{\"id\":\"user\",\"role\":\"user\",\"content\":\"accepted\"}]')",
);

Future<void> _seedVariationEvidence(
  AppDatabase db, {
  String kind = 'variation',
}) async {
  await db.customStatement(
    "INSERT INTO lorebook_use_manifests "
    "(session_id,message_id,swipe_id,agent_swipe_id,manifest_json,manifest_hash,manifest_schema_version,final_prompt_hash,preset_snapshot_hash,created_at) "
    "VALUES ('session','message',0,0,'{}','manifest-hash',1,'prompt','preset',1)",
  );
  final selection = kind == 'selection';
  if (selection) {
    await db.customStatement(
      "INSERT INTO lorebook_use_manifest_entries "
      "(session_id,message_id,swipe_id,agent_swipe_id,lorebook_id,entry_id,entry_order,evidence_json) "
      "VALUES ('session','message',0,0,'book','entry',0,'{}')",
    );
    await db.customStatement(
      "INSERT INTO lorebook_use_acceptance_records "
      "(acceptance_id,session_id,message_id,swipe_id,agent_swipe_id,acceptance_kind,accepted_by_user_message_id,evidence_json,accepted_at) "
      "VALUES ('variation:session:user','session','message',0,0,'variation','user','{}',1)",
    );
  }
  await db.customStatement(
    "INSERT INTO lorebook_use_acceptance_records "
    "(acceptance_id,session_id,message_id,swipe_id,agent_swipe_id,acceptance_kind,accepted_by_user_message_id,selected_lorebook_id,selected_entry_id,selected_entry_order,evidence_json,accepted_at) VALUES "
    "('${selection ? 'selection:session:message' : 'variation:session:user'}','session','message',0,0,'$kind',${selection ? 'NULL' : "'user'"},${selection ? "'book'" : 'NULL'},${selection ? "'entry'" : 'NULL'},${selection ? '0' : 'NULL'},'{}',1)",
  );
}

ReconciliationAnchor _anchor({
  String messageId = 'message',
  String content = 'canonical',
}) => ReconciliationAnchor(
  messageId: messageId,
  swipeId: 0,
  agentSwipeId: 0,
  role: 'assistant',
  contentHash: computeHash(content),
);

LedgerReconciliationRun _run({
  String id = 'run-1',
  int ordinal = 1,
  String predecessor = '',
  List<ReconciliationAnchor>? anchors,
  List<AcceptedManifestRef>? acceptedManifestRefs,
  String effectiveCanonStamp = 'stamp',
  String effectiveCanonHash = 'canon',
  Map<String, dynamic> result = const {'facts': <String>[]},
  int createdAt = 1,
}) => LedgerReconciliationRun(
  id: id,
  sessionId: 'session',
  ordinal: ordinal,
  anchors: anchors ?? [_anchor()],
  acceptedManifestRefs: acceptedManifestRefs ?? const [],
  effectiveCanonStamp: effectiveCanonStamp,
  effectiveCanonRevision: 1,
  effectiveCanonHash: effectiveCanonHash,
  canonicalResult: result,
  predecessorChainHash: predecessor,
  contractVersion: 1,
  opsApplied: const [],
  createdAt: createdAt,
);

String _cursorHash({required int sequence, required String predecessor}) =>
    computeHash(
      jsonEncode({
        'predecessorHash': predecessor,
        'sequence': sequence,
        'sessionId': 'session',
        'throughRunChainHash': 'chain-$sequence',
        'throughRunId': 'run-$sequence',
        'throughRunOrdinal': sequence,
      }),
    );
