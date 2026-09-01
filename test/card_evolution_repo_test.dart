import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_read_repository.dart';

void main() {
  late AppDatabase db;
  late CardEvolutionRepo evolution;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final characters = CharacterRepo(db);
    final revisions = CharacterRevisionRepo(db);
    const character = Character(
      id: 'character',
      name: 'Card',
      description: 'Alice is cautious.',
      personality: 'Reserved and observant.',
      scenario: 'A quiet city after midnight.',
    );
    await characters.put(character);
    final hash = CardCanonicalizer.sha256(character);
    await revisions.insert(
      CharacterRevisionRecord(
        characterId: character.id,
        revision: 1,
        revisionHash: hash,
        parentRevisionHash: '',
        snapshotJson: jsonEncode(character.toJson()),
        createdAt: 1,
      ),
    );
    await db.customStatement(
      'INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) VALUES (?, ?, 0, ?)',
      ['session', 'character', jsonEncode(_messages)],
    );
    final reader = EffectiveCanonReadRepository(
      db: db,
      characterRepo: characters,
      revisionRepo: revisions,
      baselineRepo: CharacterSessionBaselineRepo(db),
      factRepo: CharacterKnowledgeFactRepo(db),
      transitionRepo: AppliedCanonTransitionRepo(db),
      transitionFactRefRepo: CanonTransitionFactRefRepo(db),
    );
    evolution = CardEvolutionRepo(
      db: db,
      canonReader: reader,
      jobRepo: ManualRewriteJobRepo(
        db: db,
        rawTrackerStateReader: LedgerRawTrackerStateReader(db),
      ),
    );
  });

  tearDown(() => db.close());

  test('uses chat history without reconciliation runs', () async {
    expect(await evolution.isEligible('session'), isTrue);

    final claim = await evolution.claim(
      sessionId: 'session',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
    );

    expect(claim.kind, 'claimed');
    expect(
      (jsonDecode(claim.claim!.selectedInputJson) as Map)['contractVersion'],
      8,
    );
    expect(claim.claim!.selectedInputJson, contains('assistant development'));
    expect(claim.claim!.selectedInputJson, contains('user response'));
    expect(claim.claim!.selectedInputJson, contains('"effectiveCanon"'));
    expect(claim.claim!.row.selectedInputJson, claim.claim!.selectedInputJson);
    expect(
      await db.select(db.ledgerReconciliationSuccessfulRuns).get(),
      isEmpty,
    );
  });

  test('failed writer retains exact input and can be reclaimed', () async {
    final claimed = (await evolution.claim(
      sessionId: 'session',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
      writerOptionsJson: '{"lorebookEnabled":true,"contractVersion":1}',
    )).claim!;

    expect(
      await evolution.markWriterFailed(
        claimId: claimed.row.id,
        ownerId: 'owner',
        now: 11,
        code: 'cardWriterFailed',
        detail: 'offline',
      ),
      isTrue,
    );
    final blocked = await evolution.claim(
      sessionId: 'session',
      ownerId: 'automatic',
      now: 12,
      leaseSeconds: 30,
    );
    expect(blocked.kind, 'failed');
    expect(blocked.claim?.selectedInputJson, claimed.selectedInputJson);

    final recovered = await evolution.claimFailedWriter(
      claimId: claimed.row.id,
      ownerId: 'recovery',
      now: 13,
      leaseSeconds: 30,
    );
    expect(recovered.kind, 'claimed');
    expect(recovered.claim?.row.ownerId, 'recovery');
    expect(recovered.claim?.row.writerOptionsJson, contains('lorebookEnabled'));
    expect(recovered.claim?.selectedInputJson, claimed.selectedInputJson);
  });

  test(
    'completed boundary prevents reclaiming an older failed writer',
    () async {
      final claimed = (await evolution.claim(
        sessionId: 'session',
        ownerId: 'owner',
        now: 10,
        leaseSeconds: 30,
        throughCollectorOrdinal: 2,
        collectorBoundaryHash: 'shared-boundary',
      )).claim!;
      expect(
        await evolution.markWriterFailed(
          claimId: claimed.row.id,
          ownerId: 'owner',
          now: 11,
          code: 'cardWriterFailed',
        ),
        isTrue,
      );
      await db
          .into(db.cardEvolutionClaims)
          .insert(
            CardEvolutionClaimsCompanion.insert(
              id: 'completed-successor',
              sessionId: 'session',
              characterId: 'character',
              ownerId: 'cloud-sync',
              status: 'completed',
              leaseExpiresAt: 0,
              chatHistoryHash: 'completed-history',
              effectiveCanonIdentity: 'completed-canon',
              predecessorCursorHash: 'shared-boundary',
              predecessorRunOrdinal: 2,
              inputHash: 'completed-input',
              createdAt: 12,
              completedAt: const Value(13),
            ),
          );

      final recovered = await evolution.claimFailedWriter(
        claimId: claimed.row.id,
        ownerId: 'recovery',
        now: 14,
        leaseSeconds: 30,
      );

      expect(recovered.kind, 'notFailed');
      expect((await evolution.getClaimById(claimed.row.id))?.status, 'failed');
    },
  );

  test(
    'an unreproducible failed claim is dropped and replaced fresh',
    () async {
      final dead = (await evolution.claim(
        sessionId: 'session',
        ownerId: 'owner',
        now: 10,
        leaseSeconds: 30,
      )).claim!;
      await db.customStatement(
        'UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?',
        [
          jsonEncode([..._messages, _nextAssistant, _nextUser]),
          'session',
        ],
      );
      // A restart attempt fails to rebuild the snapshot from the changed
      // chat and marks the claim failed with durable checkpoints.
      expect(
        await evolution.markWriterFailed(
          claimId: dead.row.id,
          ownerId: 'owner',
          now: 11,
          code: 'snapshotUnavailable',
          detail: 'inputHashMismatch',
        ),
        isTrue,
      );

      // The dead claim no longer blocks the lane: the next claim attempt exits
      // the restart loop by dropping it and selecting a fresh snapshot.
      final fresh = await evolution.claim(
        sessionId: 'session',
        ownerId: 'automatic',
        now: 13,
        leaseSeconds: 30,
      );
      expect(fresh.kind, 'claimed');
      expect(fresh.claim!.row.id, isNot(dead.row.id));
      expect(fresh.claim!.selectedInputJson, isNot(dead.selectedInputJson));
      expect(
        await (db.select(
          db.cardEvolutionClaims,
        )..where((row) => row.id.equals(dead.row.id))).get(),
        isEmpty,
      );
    },
  );

  test('a changed chat snapshot makes a claimed lease stale', () async {
    final claim = (await evolution.claim(
      sessionId: 'session',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
    )).claim!;
    await db.customStatement(
      'UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?',
      [
        jsonEncode([..._messages, _nextAssistant, _nextUser]),
        'session',
      ],
    );

    final outcome = await evolution.readPromptSnapshotOutcome(
      claimId: claim.row.id,
      ownerId: 'owner',
      now: 11,
    );

    expect(outcome.snapshot, isNull);
    expect(outcome.reason, 'inputHashMismatch');
    expect(
      await evolution.readPromptSnapshot(
        claimId: claim.row.id,
        ownerId: 'owner',
        now: 11,
      ),
      isNull,
    );
  });

  test('renews only a live claim owned by the caller', () async {
    final claim = (await evolution.claim(
      sessionId: 'session',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
    )).claim!;

    expect(
      await evolution.renewClaimLease(
        claimId: claim.row.id,
        ownerId: 'owner',
        now: 20,
        leaseSeconds: 600,
      ),
      isTrue,
    );
    final renewed = await (db.select(
      db.cardEvolutionClaims,
    )..where((row) => row.id.equals(claim.row.id))).getSingle();
    expect(renewed.leaseExpiresAt, 620);
    expect(
      await evolution.renewClaimLease(
        claimId: claim.row.id,
        ownerId: 'other-owner',
        now: 21,
        leaseSeconds: 600,
      ),
      isFalse,
    );
    expect(
      await evolution.renewClaimLease(
        claimId: claim.row.id,
        ownerId: 'owner',
        now: 620,
        leaseSeconds: 600,
      ),
      isFalse,
    );
  });

  test(
    'an unknown session is attributed instead of silently ignored',
    () async {
      expect(
        await evolution.selectionFailure('missing'),
        CardEvolutionSelectionFailure.sessionMissing,
      );

      final claim = await evolution.claim(
        sessionId: 'missing',
        ownerId: 'owner',
        now: 10,
        leaseSeconds: 30,
      );

      expect(claim.kind, 'notEligible');
      expect(claim.detail, 'sessionMissing');
    },
  );

  test('a malformed message list is attributed', () async {
    await db.customStatement(
      'UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?',
      ['{}', 'session'],
    );

    expect(
      await evolution.selectionFailure('session'),
      CardEvolutionSelectionFailure.messagesMalformed,
    );
  });

  test('a single-turn history is attributed as too short', () async {
    await db.customStatement(
      'UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?',
      [
        jsonEncode([_messages.first]),
        'session',
      ],
    );

    expect(
      await evolution.selectionFailure('session'),
      CardEvolutionSelectionFailure.historyTooShort,
    );
    expect(await evolution.isEligible('session'), isFalse);
  });

  test(
    'a character without revisions is attributed as canon unavailable',
    () async {
      await db.customStatement(
        'DELETE FROM character_revision_rows WHERE character_id = ?',
        ['character'],
      );

      expect(
        await evolution.selectionFailure('session'),
        CardEvolutionSelectionFailure.canonUnavailable,
      );
    },
  );

  test(
    'a claim asking for unknown reconciliation runs is attributed',
    () async {
      final claim = await evolution.claim(
        sessionId: 'session',
        ownerId: 'owner',
        now: 10,
        leaseSeconds: 30,
        reconciliationRunIds: const ['missing-run'],
      );

      expect(claim.kind, 'notEligible');
      expect(claim.detail, 'reconciliationRunsMissing');
    },
  );

  test('expired claim is replaced using a fresh chat snapshot', () async {
    final first = (await evolution.claim(
      sessionId: 'session',
      ownerId: 'closed-app-owner',
      now: 10,
      leaseSeconds: 30,
    )).claim!;
    await db.customStatement(
      'UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?',
      [
        jsonEncode([..._messages, _nextAssistant, _nextUser]),
        'session',
      ],
    );

    final recovered = await evolution.claim(
      sessionId: 'session',
      ownerId: 'new-app-owner',
      now: 41,
      leaseSeconds: 30,
    );

    expect(recovered.kind, 'claimed');
    expect(recovered.claim!.row.id, isNot(first.row.id));
    expect(recovered.claim!.row.ownerId, 'new-app-owner');
    expect(
      recovered.claim!.selectedInputJson,
      contains('new assistant development'),
    );
    expect(
      await (db.select(
        db.cardEvolutionClaims,
      )..where((row) => row.id.equals(first.row.id))).getSingleOrNull(),
      isNull,
    );
  });

  test(
    'excludes a trailing mutable user-assistant turn from evidence',
    () async {
      await db.customStatement(
        'UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?',
        [
          jsonEncode([..._messages, _nextAssistant]),
          'session',
        ],
      );

      final claim = await evolution.claim(
        sessionId: 'session',
        ownerId: 'owner',
        now: 10,
        leaseSeconds: 30,
      );

      expect(claim.kind, 'claimed');
      expect(
        claim.claim!.selectedInputJson,
        isNot(contains('new assistant development')),
      );
      expect(claim.claim!.selectedInputJson, isNot(contains('user response')));
      expect(claim.claim!.selectedInputJson, contains('assistant development'));
    },
  );

  test('finalize atomically writes a three-field review proposal', () async {
    final claim = (await evolution.claim(
      sessionId: 'session',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
    )).claim!;

    final result = await evolution.finalize(
      claimId: claim.row.id,
      ownerId: 'owner',
      now: 11,
      modelOutput: '["raw"]',
      operations: _operations(),
    );

    expect(result.kind, 'persisted');
    expect(result.job!.status, 'pending');
    expect(await db.select(db.rewriteOperations).get(), hasLength(3));
    expect(await db.select(db.rewriteOperationRevisions).get(), hasLength(3));
    expect(await db.select(db.rewriteEvidenceRows).get(), hasLength(1));
    expect(await db.select(db.cardEvolutionProposalRuns).get(), hasLength(1));
    expect(await db.select(db.ledgerReconciliationCursors).get(), isEmpty);
  });

  test('deletes a cancelled proposal and all of its provenance', () async {
    final claim = (await evolution.claim(
      sessionId: 'session',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
    )).claim!;
    final finalized = await evolution.finalize(
      claimId: claim.row.id,
      ownerId: 'owner',
      now: 11,
      modelOutput: '["raw"]',
      operations: _operations(),
    );
    final job = finalized.job!;
    await evolution.jobRepo.cancel(jobId: job.id, expectedVersion: job.version);

    final outcome = await evolution.deleteReplaceableProposal(job.id);

    expect(outcome.kind, 'deleted');
    expect(await db.select(db.rewriteJobs).get(), isEmpty);
    expect(await db.select(db.rewriteOperations).get(), isEmpty);
    expect(await db.select(db.rewriteOperationRevisions).get(), isEmpty);
    expect(await db.select(db.rewriteEvidenceRows).get(), isEmpty);
    expect(await db.select(db.cardEvolutionProposalRuns).get(), isEmpty);
    expect(await db.select(db.cardEvolutionClaims).get(), isEmpty);
    expect(
      (await evolution.claim(
        sessionId: 'session',
        ownerId: 'replacement',
        now: 12,
        leaseSeconds: 30,
      )).kind,
      'claimed',
    );
  });

  test('deletes a pending automated proposal before review apply', () async {
    final claim = (await evolution.claim(
      sessionId: 'session',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
    )).claim!;
    final finalized = await evolution.finalize(
      claimId: claim.row.id,
      ownerId: 'owner',
      now: 11,
      modelOutput: '["raw"]',
      operations: _operations(),
    );

    final outcome = await evolution.deleteReplaceableProposal(
      finalized.job!.id,
    );

    expect(outcome.kind, 'deleted');
    expect(await db.select(db.rewriteJobs).get(), isEmpty);
    expect(await db.select(db.rewriteOperations).get(), isEmpty);
    expect(await db.select(db.rewriteOperationRevisions).get(), isEmpty);
    expect(await db.select(db.rewriteEvidenceRows).get(), isEmpty);
    expect(await db.select(db.cardEvolutionProposalRuns).get(), isEmpty);
    expect(await db.select(db.cardEvolutionClaims).get(), isEmpty);
  });

  test('refuses to delete an applied automated proposal', () async {
    final claim = (await evolution.claim(
      sessionId: 'session',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
    )).claim!;
    final finalized = await evolution.finalize(
      claimId: claim.row.id,
      ownerId: 'owner',
      now: 11,
      modelOutput: '["raw"]',
      operations: _operations(),
    );
    await (db.update(db.rewriteJobs)
          ..where((row) => row.id.equals(finalized.job!.id)))
        .write(const RewriteJobsCompanion(status: Value('applied')));

    final outcome = await evolution.deleteReplaceableProposal(
      finalized.job!.id,
    );

    expect(outcome.kind, 'invalidState');
    expect(await db.select(db.rewriteJobs).get(), hasLength(1));
    expect(await db.select(db.cardEvolutionProposalRuns).get(), hasLength(1));
    expect(await db.select(db.cardEvolutionClaims).get(), hasLength(1));
  });

  test('deletes a failed writer claim and its call checkpoints', () async {
    final claim = (await evolution.claim(
      sessionId: 'session',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
    )).claim!;
    await (db.update(
      db.cardEvolutionClaims,
    )..where((row) => row.id.equals(claim.row.id))).write(
      const CardEvolutionClaimsCompanion(
        status: Value('failed'),
        leaseExpiresAt: Value(0),
        failureCode: Value('snapshotUnavailable'),
        failedAt: Value(11),
      ),
    );
    await db
        .into(db.cardEvolutionWriterCalls)
        .insert(
          CardEvolutionWriterCallsCompanion.insert(
            id: 'call',
            claimId: claim.row.id,
            sessionId: 'session',
            ordinal: 1,
            stage: 'card_writer',
            stageOrdinal: 1,
            status: 'failed',
            prompt: 'prompt',
            promptHash: 'prompt-hash',
            failureCode: const Value('snapshotUnavailable'),
            createdAt: 10,
            updatedAt: 11,
          ),
        );

    final outcome = await evolution.deleteFailedWriterClaim(claim.row.id);

    expect(outcome.kind, 'deleted');
    expect(await db.select(db.cardEvolutionClaims).get(), isEmpty);
    expect(await db.select(db.cardEvolutionWriterCalls).get(), isEmpty);
  });

  test('refuses to delete a completed writer claim', () async {
    final claim = (await evolution.claim(
      sessionId: 'session',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
    )).claim!;
    await (db.update(
      db.cardEvolutionClaims,
    )..where((row) => row.id.equals(claim.row.id))).write(
      const CardEvolutionClaimsCompanion(
        status: Value('completed'),
        leaseExpiresAt: Value(0),
        completedAt: Value(11),
      ),
    );

    final outcome = await evolution.deleteFailedWriterClaim(claim.row.id);

    expect(outcome.kind, 'invalidState');
    expect(await db.select(db.cardEvolutionClaims).get(), hasLength(1));
  });

  test('finalize reports the exact rejected card patch validation', () async {
    final claim = (await evolution.claim(
      sessionId: 'session',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
    )).claim!;
    final invalid = _operation(
      CardRewriteField.description,
      'text from chat history',
      'replacement',
    );

    final result = await evolution.finalize(
      claimId: claim.row.id,
      ownerId: 'owner',
      now: 11,
      modelOutput: 'raw',
      operations: [invalid],
    );

    expect(result.kind, 'invalidOperation');
    expect(result.detail, 'description: staleAnchor');
    expect(await db.select(db.rewriteJobs).get(), isEmpty);
  });

  test('finalize rejects a cited fact owned by another scope', () async {
    Future<void> putFact(String id, String scope) => db
        .into(db.characterKnowledgeFactRows)
        .insert(
          CharacterKnowledgeFactRowsCompanion.insert(
            id: id,
            chatSessionId: 'session',
            knowerKey: 'alice',
            subjectKey: 'alice',
            factClass: 'relationship',
            scopeKey: Value(scope),
            predicate: 'status',
            object: 'ended',
            epistemicState: 'confirmed',
            lifecycle: const Value('active'),
            sourceMessageId: const Value('a1'),
          ),
        );
    const relationshipScope = 'relationship:гильда:ричард';
    const arcScope = 'arc:gilda_richard_engagement';
    await putFact('fact-engagement', relationshipScope);
    await putFact('fact-arc-target', arcScope);
    final claim = (await evolution.claim(
      sessionId: 'session',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
    )).claim!;

    final result = await evolution.finalize(
      claimId: claim.row.id,
      ownerId: 'owner',
      now: 11,
      modelOutput: 'raw',
      operations: [
        _operation(
          CardRewriteField.description,
          'Alice is cautious.',
          'Alice is cautious but decisive.',
          scopeKey: arcScope,
          factIds: const ['fact-engagement'],
        ),
      ],
    );

    expect(result.kind, 'invalidOperation');
    expect(
      result.detail,
      allOf(contains(arcScope), contains(relationshipScope)),
    );
    expect(await db.select(db.rewriteJobs).get(), isEmpty);
    expect(await db.select(db.rewriteOperations).get(), isEmpty);
    expect(await db.select(db.cardEvolutionProposalRuns).get(), isEmpty);
  });

  test('finalize rejects a tiny automated anchor', () async {
    final claim = (await evolution.claim(
      sessionId: 'session',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
    )).claim!;

    final result = await evolution.finalize(
      claimId: claim.row.id,
      ownerId: 'owner',
      now: 11,
      modelOutput: 'raw',
      operations: [
        _operation(CardRewriteField.scenario, '8', 'Afterlife with Danvi'),
      ],
    );

    expect(result.kind, 'invalidOperation');
    expect(result.detail, 'scenario: anchorTooShort');
    expect(await db.select(db.rewriteJobs).get(), isEmpty);
  });

  test('finalization rollback keeps no partial proposal', () async {
    final reader = evolution.canonReader;
    evolution = CardEvolutionRepo(
      db: db,
      canonReader: reader,
      jobRepo: evolution.jobRepo,
      beforeCursorInsert: () async => throw StateError('injected'),
    );
    final claim = (await evolution.claim(
      sessionId: 'session',
      ownerId: 'owner',
      now: 10,
      leaseSeconds: 30,
    )).claim!;

    await expectLater(
      evolution.finalize(
        claimId: claim.row.id,
        ownerId: 'owner',
        now: 11,
        modelOutput: '["raw"]',
        operations: _operations(),
      ),
      throwsStateError,
    );
    expect(await db.select(db.rewriteJobs).get(), isEmpty);
    expect(await db.select(db.cardEvolutionProposalRuns).get(), isEmpty);
  });
}

const _messages = [
  {'id': 'u1', 'role': 'user', 'content': 'user setup'},
  {'id': 'a1', 'role': 'assistant', 'content': 'assistant development'},
  {'id': 'u2', 'role': 'user', 'content': 'user response'},
];

const _nextAssistant = {
  'id': 'a2',
  'role': 'assistant',
  'content': 'new assistant development',
};

const _nextUser = {'id': 'u3', 'role': 'user', 'content': 'next user response'};

List<CardRewriteOperationSnapshot> _operations() => [
  _operation(
    CardRewriteField.description,
    'Alice is cautious.',
    'Alice is cautious but increasingly trusting.',
  ),
  _operation(
    CardRewriteField.personality,
    'Reserved and observant.',
    'Reserved, observant, and increasingly open.',
  ),
  _operation(
    CardRewriteField.scenario,
    'A quiet city after midnight.',
    'A quiet city after midnight where trust is cautiously growing.',
  ),
];

CardRewriteOperationSnapshot _operation(
  CardRewriteField field,
  String anchor,
  String value, {
  String scopeKey = 'npc:alice',
  List<String> factIds = const [],
}) => CardRewriteOperationSnapshot(
  field: field,
  patches: [
    AnchoredScalarPatch(
      scopeKey: scopeKey,
      field: field,
      anchor: anchor,
      anchorSha256: CardCanonicalizer.scalarSha256(anchor),
      value: value,
    ),
  ],
  transition: CardRewriteTransitionSnapshot(
    id: 'transition-${field.wireName}',
    scopeKey: scopeKey,
    canonicalClaim: 'Alice is increasingly trusting.',
    promotionDestination: 'card',
    affectedTrackerKeys: const [],
    factIds: factIds,
  ),
);
