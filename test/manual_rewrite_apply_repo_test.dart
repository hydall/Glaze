import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_apply_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/llm/prompt/ledger_tracker_loader.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_assembler.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_read_repository.dart';

void main() {
  late AppDatabase db;
  late CharacterRepo characters;
  late CharacterRevisionRepo revisions;
  late EffectiveCanonReadRepository reader;
  late Future<String> Function() seed;
  late LedgerRawTrackerState raw;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    characters = CharacterRepo(db);
    revisions = CharacterRevisionRepo(db);
    raw = LedgerRawTrackerState(
      committedTrackers: const [],
      manualControls: const [],
    );
    reader = EffectiveCanonReadRepository.runtime(
      db: db,
      characterRepo: characters,
      revisionRepo: revisions,
      baselineRepo: CharacterSessionBaselineRepo(db),
      factRepo: CharacterKnowledgeFactRepo(db),
      transitionRepo: AppliedCanonTransitionRepo(db),
      transitionFactRefRepo: CanonTransitionFactRefRepo(db),
      loadRawTrackerState: (_) async => raw,
    );
  });
  tearDown(() => db.close());

  seed = () async {
    final card = Character(
      id: 'c',
      name: 'Card',
      description: 'old text',
      personality: 'untouched',
      extensions: {
        'opaque': {'preserved': true},
      },
    );
    await characters.put(card);
    final hash = CardCanonicalizer.sha256(card);
    await revisions.insert(
      CharacterRevisionRecord(
        characterId: 'c',
        revision: 1,
        revisionHash: hash,
        parentRevisionHash: '',
        snapshotJson: jsonEncode(card.toJson()),
        createdAt: 1,
      ),
    );
    await db
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion.insert(
            sessionId: 's',
            characterId: 'c',
            sessionIndex: 0,
            messagesJson: jsonEncode([
              {
                'id': 'assistant-accepted',
                'role': 'assistant',
                'content': 'Accepted response',
              },
              {'id': 'user-acceptance', 'role': 'user', 'content': 'Continue'},
            ]),
          ),
        );
    final input = await reader.readInTransaction(
      sessionId: 's',
      characterId: 'c',
    );
    final stamp = const EffectiveCanonAssembler().assemble(input).identity;
    final snapshot = jsonEncode({
      'field': 'description',
      'patches': [
        {
          'scopeKey': 'npc:alice',
          'anchor': 'old text',
          'anchorSha256': CardCanonicalizer.scalarSha256('old text'),
          'value': 'new text',
        },
      ],
      'transition': {
        'id': 'transition',
        'scopeKey': 'npc:alice',
        'canonicalClaim': 'new text',
        'promotionDestination': 'card',
        'affectedTrackerKeys': <String>[],
        'factIds': <String>[],
        'chatSessionId': null,
      },
    });
    await db
        .into(db.rewriteJobs)
        .insert(
          RewriteJobsCompanion.insert(
            id: 'job',
            chatSessionId: 's',
            characterId: 'c',
            basisRevision: const Value(1),
            basisRevisionHash: Value(hash),
            canonStamp: Value(stamp),
            version: const Value(1),
          ),
        );
    await db
        .into(db.rewriteOperations)
        .insert(
          RewriteOperationsCompanion.insert(
            id: 'op',
            rewriteJobId: 'job',
            chatSessionId: 's',
            operationJson: Value(snapshot),
            currentRevision: const Value(1),
            status: const Value('reviewable'),
            decision: const Value('approved'),
            validationStatus: const Value('valid'),
            decisionRevision: const Value(1),
          ),
        );
    await db
        .into(db.rewriteOperationRevisions)
        .insert(
          RewriteOperationRevisionsCompanion.insert(
            rewriteOperationId: 'op',
            revision: 1,
            snapshotJson: snapshot,
          ),
        );
    return stamp;
  };

  Future<void> addApprovedOperation({
    required String id,
    required String anchor,
    required String value,
    CardRewriteField field = CardRewriteField.description,
    String chatSessionId = 's',
    List<String> factIds = const [],
  }) async {
    final snapshot = jsonEncode({
      'field': field.wireName,
      'patches': [
        {
          'scopeKey': 'npc:alice',
          'anchor': anchor,
          'anchorSha256': CardCanonicalizer.scalarSha256(anchor),
          'value': value,
        },
      ],
      'transition': {
        'id': 'transition-$id',
        'scopeKey': 'npc:alice',
        'canonicalClaim': value,
        'promotionDestination': 'card',
        'affectedTrackerKeys': <String>[],
        'factIds': factIds,
        'chatSessionId': null,
      },
    });
    await db
        .into(db.rewriteOperations)
        .insert(
          RewriteOperationsCompanion.insert(
            id: id,
            rewriteJobId: 'job',
            chatSessionId: chatSessionId,
            operationJson: Value(snapshot),
            currentRevision: const Value(1),
            status: const Value('reviewable'),
            decision: const Value('approved'),
            validationStatus: const Value('valid'),
            decisionRevision: const Value(1),
          ),
        );
    await db
        .into(db.rewriteOperationRevisions)
        .insert(
          RewriteOperationRevisionsCompanion.insert(
            rewriteOperationId: id,
            revision: 1,
            snapshotJson: snapshot,
          ),
        );
  }

  Future<void> replaceOperationSnapshot(String id, String snapshot) async {
    final operation = await (db.select(
      db.rewriteOperations,
    )..where((row) => row.id.equals(id))).getSingle();
    final revision = operation.currentRevision + 1;
    await db
        .into(db.rewriteOperationRevisions)
        .insert(
          RewriteOperationRevisionsCompanion.insert(
            rewriteOperationId: id,
            revision: revision,
            snapshotJson: snapshot,
          ),
        );
    await (db.update(
      db.rewriteOperations,
    )..where((row) => row.id.equals(id))).write(
      RewriteOperationsCompanion(
        operationJson: Value(snapshot),
        currentRevision: Value(revision),
        decisionRevision: Value(revision),
      ),
    );
  }

  Future<void> addApprovedLorebookOperation({
    String expectedContent = 'The district is dangerous.',
  }) async {
    final snapshot = RewriteOperationSnapshotCodec.encode(
      LorebookRewriteOperationSnapshot(
        lorebookId: 'book',
        entryId: 'district',
        baseContent: 'The district is dangerous.',
        expectedContentHash: CardCanonicalizer.scalarSha256(expectedContent),
        patches: [
          LorebookAnchoredPatch(
            anchor: 'dangerous',
            anchorSha256: CardCanonicalizer.scalarSha256('dangerous'),
            value: 'dangerous but lively',
          ),
        ],
      ),
    );
    await db
        .into(db.rewriteOperations)
        .insert(
          RewriteOperationsCompanion.insert(
            id: 'lore-op',
            rewriteJobId: 'job',
            chatSessionId: 's',
            operationJson: Value(snapshot),
            currentRevision: const Value(1),
            status: const Value('reviewable'),
            decision: const Value('approved'),
            validationStatus: const Value('valid'),
            decisionRevision: const Value(1),
          ),
        );
    await db
        .into(db.rewriteOperationRevisions)
        .insert(
          RewriteOperationRevisionsCompanion.insert(
            rewriteOperationId: 'lore-op',
            revision: 1,
            snapshotJson: snapshot,
          ),
        );
  }

  String canonicalJson(Object? value) {
    Object? canonical(Object? item) {
      if (item is Map) {
        final keys = item.keys.map((key) => key.toString()).toList()..sort();
        return {for (final key in keys) key: canonical(item[key])};
      }
      if (item is Iterable) return item.map(canonical).toList();
      return item;
    }

    return jsonEncode(canonical(value));
  }

  Future<void> addAutomaticProposal({
    List<Map<String, Object?>> observations = const [],
  }) async {
    final history = <Map<String, Object?>>[
      {
        'messageId': 'assistant-accepted',
        'role': 'assistant',
        'swipeId': 0,
        'agentSwipeId': 0,
        'content': 'Accepted response',
        'contentHash': computeHash('Accepted response'),
      },
    ];
    final selected = canonicalJson({
      'contractVersion': 8,
      'chatHistoryHash': computeHash(canonicalJson(history)),
      'effectiveCanonIdentity': 'canon',
      'chatHistory': history,
      'accumulatedObservations': observations,
    });
    await db
        .into(db.cardEvolutionProposalRuns)
        .insert(
          CardEvolutionProposalRunsCompanion.insert(
            id: 'proposal',
            claimId: 'claim',
            sessionId: 's',
            characterId: 'c',
            rewriteJobId: 'job',
            chatHistoryHash: computeHash(canonicalJson(history)),
            effectiveCanonIdentity: 'canon',
            selectedInputJson: selected,
            inputHash: computeHash(selected),
            modelOutput: '{}',
            modelOutputHash: computeHash('{}'),
            operationSnapshotJson: '[]',
            createdAt: 1,
          ),
        );
  }

  test(
    'applies the durable approved set atomically and retries idempotently',
    () async {
      final stamp = await seed();
      final repo = ManualRewriteApplyRepo(db: db, canonReader: reader);
      expect(
        (await repo.applyApproved(
          jobId: 'job',
          expectedCanonStamp: stamp,
          expectedJobVersion: 1,
        )).kind,
        'applied',
      );
      final original = await characters.getById('c');
      expect(original!.description, 'old text');
      final session = await db.select(db.chatSessions).getSingle();
      expect(session.characterId, isNot('c'));
      final card = await characters.getById(session.characterId);
      expect(card!.description, 'new text');
      expect(card.personality, 'untouched');
      expect(card.extensions, {
        'opaque': {'preserved': true},
      });
      expect(card.updatedAt, greaterThan(0));
      expect(await revisions.getForCharacter('c'), hasLength(1));
      expect(
        await revisions.getForCharacter(session.characterId),
        hasLength(2),
      );
      expect(
        await db.select(db.sessionCanonCheckpointRows).get(),
        hasLength(2),
      );
      final checkpoint =
          (await db.select(db.sessionCanonCheckpointRows).get()).last;
      expect(checkpoint.anchorMessageId, 'assistant-accepted');
      expect(
        (await repo.applyApproved(
          jobId: 'job',
          expectedCanonStamp: stamp,
          expectedJobVersion: 1,
        )).kind,
        'alreadyApplied',
      );
    },
  );

  /// Automated evolution jobs are stamped with the stable canon identity
  /// (volatile Ledger state excluded). Restamps the seeded job accordingly.
  Future<String> restampJobAsAutomated() async {
    final stableStamp = const EffectiveCanonAssembler()
        .assemble(
          await reader.readInTransaction(sessionId: 's', characterId: 'c'),
          stampVolatileState: false,
        )
        .identity;
    await (db.update(db.rewriteJobs)..where((t) => t.id.equals('job')))
        .write(RewriteJobsCompanion(canonStamp: Value(stableStamp)));
    return stableStamp;
  }

  test('valid automatic proposal evidence remains applyable', () async {
    await seed();
    await addAutomaticProposal();
    final stamp = await restampJobAsAutomated();

    final outcome = await ManualRewriteApplyRepo(db: db, canonReader: reader)
        .applyApproved(
          jobId: 'job',
          expectedCanonStamp: stamp,
          expectedJobVersion: 1,
        );

    expect(outcome.kind, 'applied');
  });

  test(
    'apply consumes only promoted observations targeted by applied ops',
    () async {
      await seed();
      final stamp = await restampJobAsAutomated();
      for (final entry in const [
        ('used', 'npc:alice', 'description', 'promoted'),
        ('wrong-field', 'stored:wrong-field', 'personality', 'promoted'),
        ('active', 'stored:active', 'description', 'active'),
        ('rejected', 'npc:bob', 'description', 'promoted'),
      ]) {
        await db
            .into(db.cardEvolutionObservations)
            .insert(
              CardEvolutionObservationsCompanion.insert(
                id: entry.$1,
                sessionId: 's',
                characterId: 'c',
                runOrdinal: 1,
                semanticScopeKey: entry.$2,
                observedChange: entry.$1,
                evidenceMessageIds: '[]',
                confidence: 0.9,
                status: entry.$4,
                firstSeenRun: 1,
                cardFieldPath: Value(entry.$3),
                createdAt: 1,
                updatedAt: 1,
              ),
            );
      }
      await addAutomaticProposal(
        observations: const [
          {
            'id': 'used',
            'status': 'promoted',
            'targetKind': 'main_character_card',
            'scopeKey': 'npc:alice',
            'cardFieldPath': 'description',
            'firstSeenRun': 1,
          },
          {
            'id': 'wrong-field',
            'status': 'promoted',
            'targetKind': 'main_character_card',
            'scopeKey': 'npc:alice',
            'cardFieldPath': 'personality',
            'firstSeenRun': 1,
          },
          {
            'id': 'active',
            'status': 'active',
            'targetKind': 'main_character_card',
            'scopeKey': 'npc:alice',
            'cardFieldPath': 'description',
            'firstSeenRun': 1,
          },
          {
            'id': 'rejected',
            'status': 'promoted',
            'targetKind': 'main_character_card',
            'scopeKey': 'npc:bob',
            'cardFieldPath': 'description',
            'firstSeenRun': 1,
          },
        ],
      );

      final outcome = await ManualRewriteApplyRepo(db: db, canonReader: reader)
          .applyApproved(
            jobId: 'job',
            expectedCanonStamp: stamp,
            expectedJobVersion: 1,
          );
      expect(outcome.kind, 'applied');
      final rows = await db.select(db.cardEvolutionObservations).get();
      final statuses = {for (final row in rows) row.id: row.status};
      expect(statuses['used'], 'consumed');
      expect(statuses['wrong-field'], 'promoted');
      expect(statuses['active'], 'active');
      expect(statuses['rejected'], 'promoted');
    },
  );

  test('stale automatic evidence cancels job without card writes', () async {
    final stamp = await seed();
    await addAutomaticProposal();
    final session = await db.select(db.chatSessions).getSingle();
    final messages = jsonDecode(session.messagesJson) as List<dynamic>;
    (messages.first as Map<String, dynamic>)['content'] = 'Changed response';
    await db
        .update(db.chatSessions)
        .write(
          ChatSessionsCompanion(messagesJson: Value(jsonEncode(messages))),
        );

    final outcome = await ManualRewriteApplyRepo(db: db, canonReader: reader)
        .applyApproved(
          jobId: 'job',
          expectedCanonStamp: stamp,
          expectedJobVersion: 1,
        );

    expect(outcome.kind, 'blocked');
    expect(outcome.reason, 'staleAutomatedEvidence');
    expect((await db.select(db.rewriteJobs).getSingle()).status, 'cancelled');
    expect(
      (await db.select(db.rewriteJobs).getSingle()).statusReason,
      'chatEvidenceChanged',
    );
    expect((await characters.getById('c'))!.description, 'old text');
    expect(await db.select(db.characterRevisionRows).get(), hasLength(1));
    expect(await db.select(db.cardEvolutionProposalRuns).get(), hasLength(1));
    expect(await db.select(db.rewriteOperationRevisions).get(), hasLength(1));
  });

  test(
    'applies approved operations for multiple fields in one revision',
    () async {
      final stamp = await seed();
      await addApprovedOperation(
        id: 'personality',
        field: CardRewriteField.personality,
        anchor: 'untouched',
        value: 'decisive',
      );
      await addApprovedOperation(
        id: 'scenario',
        field: CardRewriteField.scenario,
        anchor: '',
        value: 'Night City',
      );

      final outcome = await ManualRewriteApplyRepo(db: db, canonReader: reader)
          .applyApproved(
            jobId: 'job',
            expectedCanonStamp: stamp,
            expectedJobVersion: 1,
          );

      expect(outcome.kind, 'applied');
      final session = await db.select(db.chatSessions).getSingle();
      final card = (await characters.getById(session.characterId))!;
      expect(card.description, 'new text');
      expect(card.personality, 'decisive');
      expect(card.scenario, 'Night City');
      expect(await revisions.getForCharacter('c'), hasLength(1));
      expect(
        await revisions.getForCharacter(session.characterId),
        hasLength(2),
      );
      expect(
        await db.select(db.appliedCanonTransitionRows).get(),
        hasLength(3),
      );
      expect(
        (await db.select(db.rewriteOperations).get()).map(
          (item) => item.status,
        ),
        everyElement('applied'),
      );
    },
  );

  test('applies a lore-only operation to the session overlay', () async {
    final stamp = await seed();
    await (db.update(db.rewriteOperations)..where((row) => row.id.equals('op')))
        .write(const RewriteOperationsCompanion(decision: Value('rejected')));
    await addApprovedLorebookOperation();

    final outcome = await ManualRewriteApplyRepo(db: db, canonReader: reader)
        .applyApproved(
          jobId: 'job',
          expectedCanonStamp: stamp,
          expectedJobVersion: 1,
        );

    expect(outcome.kind, 'applied');
    expect((await characters.getById('c'))!.description, 'old text');
    expect(await revisions.getForCharacter('c'), hasLength(1));
    final overlay = await db
        .select(db.sessionLorebookEvolutionRows)
        .getSingle();
    expect(overlay.chatSessionId, 's');
    expect(overlay.baseContent, 'The district is dangerous.');
    expect(overlay.content, 'The district is dangerous but lively.');
    final job = await db.select(db.rewriteJobs).getSingle();
    expect(job.appliedCharacterRevision, 0);
    expect(job.appliedCharacterRevisionHash, isEmpty);
    final checkpoints = await db.select(db.sessionCanonCheckpointRows).get();
    expect(checkpoints, hasLength(2));
    expect(checkpoints.last.rewriteJobId, 'job');
    final history = await db.select(db.sessionLorebookRevisionRows).getSingle();
    expect(history.checkpointId, checkpoints.last.id);
    expect(
      history.previousContentHash,
      CardCanonicalizer.scalarSha256('The district is dangerous.'),
    );
    expect(history.contentHash, overlay.contentHash);
    final embeddingJob = await db
        .select(db.sessionLorebookEmbeddingJobRows)
        .getSingle();
    expect(embeddingJob.checkpointId, checkpoints.last.id);
    expect(embeddingJob.expectedContentHash, overlay.contentHash);
  });

  test('stale lorebook operation rolls card writes back atomically', () async {
    final stamp = await seed();
    await addApprovedLorebookOperation(expectedContent: 'concurrent content');

    final outcome = await ManualRewriteApplyRepo(db: db, canonReader: reader)
        .applyApproved(
          jobId: 'job',
          expectedCanonStamp: stamp,
          expectedJobVersion: 1,
        );

    expect(outcome.kind, 'blocked');
    expect(outcome.reason, 'staleLorebookEntry');
    expect((await characters.getById('c'))!.description, 'old text');
    expect(await revisions.getForCharacter('c'), hasLength(1));
    expect(await db.select(db.sessionLorebookEvolutionRows).get(), isEmpty);
    expect(await db.select(db.sessionCanonCheckpointRows).get(), isEmpty);
    expect(await db.select(db.sessionLorebookRevisionRows).get(), isEmpty);
    expect(await db.select(db.sessionLorebookEmbeddingJobRows).get(), isEmpty);
    expect(
      (await db.select(db.rewriteOperations).get()).map((row) => row.status),
      everyElement('reviewable'),
    );
  });

  test('stale source scalar CAS blocks without writes', () async {
    final stamp = await seed();
    await (db.update(db.characters)..where((t) => t.charId.equals('c'))).write(
      const CharactersCompanion(description: Value('concurrent edit')),
    );
    final outcome = await ManualRewriteApplyRepo(db: db, canonReader: reader)
        .applyApproved(
          jobId: 'job',
          expectedCanonStamp: stamp,
          expectedJobVersion: 1,
        );
    expect(outcome.kind, 'blocked');
    expect((await characters.getById('c'))!.description, 'concurrent edit');
    expect(await revisions.getForCharacter('c'), hasLength(1));
    expect(await db.select(db.appliedCanonTransitionRows).get(), isEmpty);
  });

  test('stale updatedAt CAS blocks while selected text is unchanged', () async {
    final stamp = await seed();
    final outcome =
        await ManualRewriteApplyRepo(
          db: db,
          canonReader: reader,
          beforeScalarUpdateHook: () =>
              (db.update(db.characters)..where((t) => t.charId.equals('c')))
                  .write(const CharactersCompanion(updatedAt: Value(99))),
        ).applyApproved(
          jobId: 'job',
          expectedCanonStamp: stamp,
          expectedJobVersion: 1,
        );
    expect(outcome.kind, 'blocked');
    expect((await characters.getById('c'))!.description, 'old text');
    expect(await revisions.getForCharacter('c'), hasLength(1));
    expect(await db.select(db.appliedCanonTransitionRows).get(), isEmpty);
  });

  test(
    'generation canon stamp blocks changed effective canon despite fresh caller stamp',
    () async {
      final generatedStamp = await seed();
      raw = LedgerRawTrackerState(
        committedTrackers: const [
          Tracker(sessionId: 's', name: 'arc.status', value: 'advanced'),
        ],
        manualControls: const [],
      );
      final liveStamp = const EffectiveCanonAssembler()
          .assemble(
            await reader.readInTransaction(sessionId: 's', characterId: 'c'),
          )
          .identity;
      expect(liveStamp, isNot(generatedStamp));

      final outcome = await ManualRewriteApplyRepo(db: db, canonReader: reader)
          .applyApproved(
            jobId: 'job',
            expectedCanonStamp: liveStamp,
            expectedJobVersion: 1,
          );

      expect(outcome.kind, 'blocked');
      expect(outcome.reason, 'staleJobCanonStamp');
      expect((await characters.getById('c'))!.description, 'old text');
      expect(await revisions.getForCharacter('c'), hasLength(1));
      expect(await db.select(db.appliedCanonTransitionRows).get(), isEmpty);
    },
  );

  test(
    'automated evolution job applies despite volatile ledger drift',
    () async {
      final fullStamp = await seed();
      await addAutomaticProposal();
      final stableStamp = const EffectiveCanonAssembler()
          .assemble(
            await reader.readInTransaction(sessionId: 's', characterId: 'c'),
            stampVolatileState: false,
          )
          .identity;
      expect(stableStamp, isNot(fullStamp));
      await (db.update(db.rewriteJobs)..where((t) => t.id.equals('job'))).write(
        RewriteJobsCompanion(canonStamp: Value(stableStamp)),
      );
      // The per-turn Ledger committed new trackers after the automated
      // proposal existed (normal LedgerStage ordering).
      raw = LedgerRawTrackerState(
        committedTrackers: const [
          Tracker(sessionId: 's', name: 'arc.status', value: 'advanced'),
        ],
        manualControls: const [],
      );
      final freshStable = const EffectiveCanonAssembler()
          .assemble(
            await reader.readInTransaction(sessionId: 's', characterId: 'c'),
            stampVolatileState: false,
          )
          .identity;
      expect(freshStable, stableStamp);

      final outcome = await ManualRewriteApplyRepo(db: db, canonReader: reader)
          .applyApproved(
            jobId: 'job',
            expectedCanonStamp: freshStable,
            expectedJobVersion: 1,
          );

      expect(outcome.kind, 'applied');
      final session = await db.select(db.chatSessions).getSingle();
      expect(
        (await characters.getById(session.characterId))!.description,
        'new text',
      );
    },
  );

  test(
    'unrelated canonical source change blocks as stale lineage without writes',
    () async {
      final stamp = await seed();
      final before = (await characters.getById('c'))!;
      await (db.update(
        db.characters,
      )..where((t) => t.charId.equals('c'))).write(
        const CharactersCompanion(
          personality: Value('independent source edit'),
          updatedAt: Value(99),
        ),
      );
      final outcome = await ManualRewriteApplyRepo(db: db, canonReader: reader)
          .applyApproved(
            jobId: 'job',
            expectedCanonStamp: stamp,
            expectedJobVersion: 1,
          );
      expect(outcome.reason, 'sourceLineageStale');
      final after = (await characters.getById('c'))!;
      expect(after.description, before.description);
      expect(after.updatedAt, 99);
      expect(await revisions.getForCharacter('c'), hasLength(1));
      expect(await db.select(db.appliedCanonTransitionRows).get(), isEmpty);
    },
  );

  test(
    'non-applyable job status and operation session block without writes',
    () async {
      // v86 constrains rewrite_jobs.status to the elegant lifecycle set, so
      // non-applyable seeded states use in-domain non-'pending' values.
      for (final status in ['generating', 'failed']) {
        final stamp = await seed();
        await (db.update(db.rewriteJobs)..where((t) => t.id.equals('job')))
            .write(RewriteJobsCompanion(status: Value(status)));
        final outcome =
            await ManualRewriteApplyRepo(
              db: db,
              canonReader: reader,
            ).applyApproved(
              jobId: 'job',
              expectedCanonStamp: stamp,
              expectedJobVersion: 1,
            );
        expect(outcome.reason, 'jobNotApplyable');
        expect((await characters.getById('c'))!.description, 'old text');
        expect(await revisions.getForCharacter('c'), hasLength(1));
        await db.close();
        db = AppDatabase.forTesting(NativeDatabase.memory());
        characters = CharacterRepo(db);
        revisions = CharacterRevisionRepo(db);
        reader = EffectiveCanonReadRepository.runtime(
          db: db,
          characterRepo: characters,
          revisionRepo: revisions,
          baselineRepo: CharacterSessionBaselineRepo(db),
          factRepo: CharacterKnowledgeFactRepo(db),
          transitionRepo: AppliedCanonTransitionRepo(db),
          transitionFactRefRepo: CanonTransitionFactRefRepo(db),
          loadRawTrackerState: (_) async => raw,
        );
      }
      final stamp = await seed();
      await (db.update(
        db.rewriteOperations,
      )..where((t) => t.id.equals('op'))).write(
        const RewriteOperationsCompanion(chatSessionId: Value('other')),
      );
      expect(
        (await ManualRewriteApplyRepo(
              db: db,
              canonReader: reader,
            ).applyApproved(
              jobId: 'job',
              expectedCanonStamp: stamp,
              expectedJobVersion: 1,
            ))
            .kind,
        'blocked',
      );
      expect((await characters.getById('c'))!.description, 'old text');
    },
  );

  test(
    'fact ownership and exact semantic scope mismatches block without writes',
    () async {
      final stamp = await seed();
      final operation = await db.select(db.rewriteOperations).getSingle();
      final decoded =
          jsonDecode(operation.operationJson) as Map<String, dynamic>;
      (decoded['transition'] as Map<String, dynamic>)['factIds'] = ['fact'];
      final snapshot = jsonEncode(decoded);
      await replaceOperationSnapshot('op', snapshot);
      Future<void> putFact(String session, String scope) => db
          .into(db.characterKnowledgeFactRows)
          .insert(
            CharacterKnowledgeFactRowsCompanion.insert(
              id: 'fact',
              chatSessionId: session,
              knowerKey: 'alice',
              subjectKey: 'alice',
              factClass: 'knowledge',
              scopeKey: Value(scope),
              predicate: 'is',
              object: 'here',
              epistemicState: 'confirmed',
              lifecycle: const Value('active'),
            ),
          );
      await putFact('other', 'npc:alice');
      expect(
        (await ManualRewriteApplyRepo(
              db: db,
              canonReader: reader,
            ).applyApproved(
              jobId: 'job',
              expectedCanonStamp: stamp,
              expectedJobVersion: 1,
            ))
            .kind,
        'blocked',
      );
      await (db.delete(
        db.characterKnowledgeFactRows,
      )..where((t) => t.id.equals('fact'))).go();
      await putFact('s', 'npc:bob');
      expect(
        (await ManualRewriteApplyRepo(
              db: db,
              canonReader: reader,
            ).applyApproved(
              jobId: 'job',
              expectedCanonStamp: stamp,
              expectedJobVersion: 1,
            ))
            .kind,
        'blocked',
      );
      expect((await characters.getById('c'))!.description, 'old text');
      expect(await db.select(db.canonTransitionFactRefs).get(), isEmpty);
    },
  );

  test(
    'exact manual control blocks affected operation without writes',
    () async {
      await seed();
      raw = LedgerRawTrackerState(
        committedTrackers: const [],
        manualControls: const [
          Tracker(
            sessionId: 's',
            name: 'canon_lock:alice.status',
            value: 'locked',
          ),
        ],
      );
      reader = EffectiveCanonReadRepository.runtime(
        db: db,
        characterRepo: characters,
        revisionRepo: revisions,
        baselineRepo: CharacterSessionBaselineRepo(db),
        factRepo: CharacterKnowledgeFactRepo(db),
        transitionRepo: AppliedCanonTransitionRepo(db),
        transitionFactRefRepo: CanonTransitionFactRefRepo(db),
        loadRawTrackerState: (_) async => raw,
      );
      final operation = await db.select(db.rewriteOperations).getSingle();
      final decoded =
          jsonDecode(operation.operationJson) as Map<String, dynamic>;
      (decoded['transition'] as Map<String, dynamic>)['affectedTrackerKeys'] = [
        'alice.status',
      ];
      final snapshot = jsonEncode(decoded);
      await replaceOperationSnapshot('op', snapshot);
      final currentStamp = const EffectiveCanonAssembler()
          .assemble(
            await reader.readInTransaction(sessionId: 's', characterId: 'c'),
          )
          .identity;
      expect(
        (await ManualRewriteApplyRepo(
              db: db,
              canonReader: reader,
            ).applyApproved(
              jobId: 'job',
              expectedCanonStamp: currentStamp,
              expectedJobVersion: 1,
            ))
            .kind,
        'blocked',
      );
      expect((await characters.getById('c'))!.description, 'old text');
      expect(await revisions.getForCharacter('c'), hasLength(1));
    },
  );

  test(
    'live database canon override blocks primary-reader apply without writes',
    () async {
      await seed();
      await TrackerRepo(db).upsert(
        const Tracker(
          sessionId: 's',
          name: 'canon_override:npc:alice.status',
          value: 'manual',
          scope: 'ledger',
          updatedAt: 1,
        ),
      );
      final operation = await db.select(db.rewriteOperations).getSingle();
      final decoded =
          jsonDecode(operation.operationJson) as Map<String, dynamic>;
      (decoded['transition'] as Map<String, dynamic>)['affectedTrackerKeys'] = [
        'npc:alice.status',
      ];
      final snapshot = jsonEncode(decoded);
      await replaceOperationSnapshot('op', snapshot);

      final primaryReader = EffectiveCanonReadRepository(
        db: db,
        characterRepo: characters,
        revisionRepo: revisions,
        baselineRepo: CharacterSessionBaselineRepo(db),
        factRepo: CharacterKnowledgeFactRepo(db),
        transitionRepo: AppliedCanonTransitionRepo(db),
        transitionFactRefRepo: CanonTransitionFactRefRepo(db),
      );
      final stamp = const EffectiveCanonAssembler()
          .assemble(
            await primaryReader.readInTransaction(
              sessionId: 's',
              characterId: 'c',
            ),
          )
          .identity;
      await (db.update(db.rewriteJobs)..where((t) => t.id.equals('job'))).write(
        RewriteJobsCompanion(canonStamp: Value(stamp)),
      );

      final outcome =
          await ManualRewriteApplyRepo(
            db: db,
            canonReader: primaryReader,
          ).applyApproved(
            jobId: 'job',
            expectedCanonStamp: stamp,
            expectedJobVersion: 1,
          );

      expect(outcome.kind, 'blocked');
      expect(outcome.reason, 'manualControlOrTransition');
      expect((await characters.getById('c'))!.description, 'old text');
      expect(await revisions.getForCharacter('c'), hasLength(1));
      expect(await db.select(db.appliedCanonTransitionRows).get(), isEmpty);
      expect(await db.select(db.canonTransitionFactRefs).get(), isEmpty);
      expect(
        (await db.select(db.rewriteOperations).getSingle()).status,
        'reviewable',
      );
      expect((await db.select(db.rewriteJobs).getSingle()).status, 'pending');
    },
  );

  test(
    'invalid anchors, no-op, and invalid approved set block without writes',
    () async {
      for (final replacement in ['missing', 'old text', 'old text']) {
        final stamp = await seed();
        final operation = await db.select(db.rewriteOperations).getSingle();
        final decoded =
            jsonDecode(operation.operationJson) as Map<String, dynamic>;
        final patches = decoded['patches'] as List;
        if (replacement == 'missing') {
          (patches.single as Map<String, dynamic>)['anchor'] = 'missing';
        } else if (patches.single is Map<String, dynamic>) {
          (patches.single as Map<String, dynamic>)['value'] = replacement;
        }
        if (replacement == 'old text') {
          (patches.single as Map<String, dynamic>)['anchorSha256'] =
              CardCanonicalizer.scalarSha256('wrong');
        }
        final invalid = jsonEncode(decoded);
        await replaceOperationSnapshot('op', invalid);
        expect(
          (await ManualRewriteApplyRepo(
                db: db,
                canonReader: reader,
              ).applyApproved(
                jobId: 'job',
                expectedCanonStamp: stamp,
                expectedJobVersion: 1,
              ))
              .kind,
          'blocked',
        );
        expect(await revisions.getForCharacter('c'), hasLength(1));
        await db.close();
        db = AppDatabase.forTesting(NativeDatabase.memory());
        characters = CharacterRepo(db);
        revisions = CharacterRevisionRepo(db);
        reader = EffectiveCanonReadRepository.runtime(
          db: db,
          characterRepo: characters,
          revisionRepo: revisions,
          baselineRepo: CharacterSessionBaselineRepo(db),
          factRepo: CharacterKnowledgeFactRepo(db),
          transitionRepo: AppliedCanonTransitionRepo(db),
          transitionFactRefRepo: CanonTransitionFactRefRepo(db),
          loadRawTrackerState: (_) async => raw,
        );
      }
    },
  );

  test(
    'non-global transition and non-reviewable operation block before writes',
    () async {
      final stamp = await seed();
      final snapshot =
          jsonDecode(
                (await db.select(db.rewriteOperations).getSingle())
                    .operationJson,
              )
              as Map<String, dynamic>;
      (snapshot['transition'] as Map<String, dynamic>)['chatSessionId'] = 's';
      final invalid = jsonEncode(snapshot);
      await replaceOperationSnapshot('op', invalid);
      final repo = ManualRewriteApplyRepo(db: db, canonReader: reader);
      expect(
        (await repo.applyApproved(
          jobId: 'job',
          expectedCanonStamp: stamp,
          expectedJobVersion: 1,
        )).kind,
        'blocked',
      );
      expect((await characters.getById('c'))!.description, 'old text');
      await (db.update(db.rewriteOperations)..where((t) => t.id.equals('op')))
          .write(const RewriteOperationsCompanion(status: Value('pending')));
      expect(
        (await repo.applyApproved(
          jobId: 'job',
          expectedCanonStamp: stamp,
          expectedJobVersion: 1,
        )).kind,
        'blocked',
      );
    },
  );

  test(
    'stale stamp and injected post-character failure leave zero writes',
    () async {
      final stamp = await seed();
      final repo = ManualRewriteApplyRepo(db: db, canonReader: reader);
      expect(
        (await repo.applyApproved(
          jobId: 'job',
          expectedCanonStamp: 'bad',
          expectedJobVersion: 1,
        )).kind,
        'blocked',
      );
      expect((await characters.getById('c'))!.description, 'old text');
      final failing = ManualRewriteApplyRepo(
        db: db,
        canonReader: reader,
        failureHook: (point) {
          if (point == ManualRewriteApplyFailurePoint.afterProvenance) {
            throw StateError('injected');
          }
        },
      );
      await expectLater(
        () => failing.applyApproved(
          jobId: 'job',
          expectedCanonStamp: stamp,
          expectedJobVersion: 1,
        ),
        throwsStateError,
      );
      expect((await characters.getById('c'))!.description, 'old text');
      expect(await revisions.getForCharacter('c'), hasLength(1));
      expect(await db.select(db.appliedCanonTransitionRows).get(), isEmpty);
      expect(
        (await db.select(db.rewriteOperations).getSingle()).status,
        'reviewable',
      );
      expect((await db.select(db.rewriteJobs).getSingle()).status, 'pending');
    },
  );

  test(
    'second provenance write failure rolls every approved operation back',
    () async {
      await seed();
      await (db.update(db.characters)..where((t) => t.charId.equals('c')))
          .write(const CharactersCompanion(description: Value('first second')));
      final source = (await characters.getById('c'))!;
      final hash = CardCanonicalizer.sha256(source);
      await (db.update(
        db.characterRevisionRows,
      )..where((t) => t.characterId.equals('c') & t.revision.equals(1))).write(
        CharacterRevisionRowsCompanion(
          revisionHash: Value(hash),
          snapshotJson: Value(jsonEncode(source.toJson())),
        ),
      );
      await (db.update(db.rewriteJobs)..where((t) => t.id.equals('job'))).write(
        RewriteJobsCompanion(basisRevisionHash: Value(hash)),
      );
      await (db.update(
        db.rewriteOperations,
      )..where((t) => t.id.equals('op'))).write(
        RewriteOperationsCompanion(
          operationJson: Value(
            jsonEncode({
              'field': 'description',
              'patches': [
                {
                  'scopeKey': 'npc:alice',
                  'anchor': 'first',
                  'anchorSha256': CardCanonicalizer.scalarSha256('first'),
                  'value': 'FIRST',
                },
              ],
              'transition': {
                'id': 'transition',
                'scopeKey': 'npc:alice',
                'canonicalClaim': 'FIRST',
                'promotionDestination': 'card',
                'affectedTrackerKeys': <String>[],
                'factIds': <String>[],
                'chatSessionId': null,
              },
            }),
          ),
        ),
      );
      final op = await db.select(db.rewriteOperations).getSingle();
      await replaceOperationSnapshot('op', op.operationJson);
      await addApprovedOperation(id: 'op2', anchor: 'second', value: 'SECOND');
      final currentStamp = const EffectiveCanonAssembler()
          .assemble(
            await reader.readInTransaction(sessionId: 's', characterId: 'c'),
          )
          .identity;
      await (db.update(db.rewriteJobs)..where((t) => t.id.equals('job'))).write(
        RewriteJobsCompanion(canonStamp: Value(currentStamp)),
      );
      final failing = ManualRewriteApplyRepo(
        db: db,
        canonReader: reader,
        failureHook: (point) {
          if (point ==
              ManualRewriteApplyFailurePoint.afterSecondTransitionOrRefWrite) {
            throw StateError('second provenance failure');
          }
        },
      );
      await expectLater(
        () => failing.applyApproved(
          jobId: 'job',
          expectedCanonStamp: currentStamp,
          expectedJobVersion: 1,
        ),
        throwsStateError,
      );
      expect((await characters.getById('c'))!.description, 'first second');
      expect(await revisions.getForCharacter('c'), hasLength(1));
      expect(await db.select(db.appliedCanonTransitionRows).get(), isEmpty);
      expect(await db.select(db.canonTransitionFactRefs).get(), isEmpty);
      expect(
        (await db.select(db.rewriteOperations).get()).map((row) => row.status),
        everyElement('reviewable'),
      );
      expect((await db.select(db.rewriteJobs).getSingle()).status, 'pending');
    },
  );
}
