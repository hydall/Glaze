import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/llm/prompt/ledger_tracker_loader.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/character_session_baseline.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_context_loader.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_assembler.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_fence_resolver.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_read_repository.dart';

void main() {
  late AppDatabase db;
  late CharacterRevisionRepo revisions;
  late CharacterSessionBaselineRepo baselines;
  late AppliedCanonTransitionRepo transitions;
  late CharacterRepo characters;
  late CharacterKnowledgeFactRepo facts;
  late CanonTransitionFactRefRepo refs;
  late LedgerRawTrackerState raw;
  late EffectiveCanonContextLoader loader;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    revisions = CharacterRevisionRepo(db);
    baselines = CharacterSessionBaselineRepo(db);
    transitions = AppliedCanonTransitionRepo(db);
    characters = CharacterRepo(db);
    facts = CharacterKnowledgeFactRepo(db);
    refs = CanonTransitionFactRefRepo(db);
    raw = LedgerRawTrackerState(
      committedTrackers: const [],
      manualControls: const [],
    );
    loader = EffectiveCanonContextLoader(
      characterRevisionRepo: revisions,
      db: db,
      characterRepo: characters,
      baselineRepo: baselines,
      factRepo: facts,
      transitionRepo: transitions,
      transitionFactRefRepo: refs,
      loadRawTrackerState: (_) async => raw,
    );
  });
  tearDown(() => db.close());

  test(
    'bootstraps lineage, appends source edits, and invalidates revision stamp',
    () async {
      final first = _character('one');
      final context = await loader.load(sessionId: 's', sourceCharacter: first);
      expect(context.effectiveRevision.number, 1);
      expect((await revisions.getForCharacter('c')), hasLength(1));
      final edited = first.copyWith(description: 'two');
      expect(
        await loader.isStillCurrent(
          sessionId: 's',
          sourceCharacter: edited,
          stamp: context.stamp,
        ),
        isFalse,
      );
      final next = await loader.load(sessionId: 's', sourceCharacter: edited);
      expect(next.effectiveRevision.number, 2);
      expect(
        (await revisions.getForCharacter('c')).last.parentRevisionHash,
        CardCanonicalizer.sha256(first),
      );

      final reverted = await loader.load(
        sessionId: 's',
        sourceCharacter: first,
      );
      final lineage = await revisions.getForCharacter('c');
      expect(reverted.effectiveRevision.number, 3);
      expect(lineage.map((item) => item.revision), [1, 2, 3]);
      expect(lineage[2].revisionHash, lineage[0].revisionHash);
      expect(lineage[2].parentRevisionHash, lineage[1].revisionHash);
    },
  );

  test(
    'read-only stamp check detects source edits without reconciling writes',
    () async {
      final first = _character('one');
      final context = await loader.load(sessionId: 's', sourceCharacter: first);
      final before = await revisions.getForCharacter('c');

      expect(
        await loader.isStillCurrentReadOnly(
          sessionId: 's',
          sourceCharacter: first.copyWith(description: 'two'),
          stamp: context.stamp,
        ),
        isFalse,
      );
      expect(await revisions.getForCharacter('c'), hasLength(before.length));
    },
  );

  test('read-only load models initial lineage without persisting it', () async {
    final context = await loader.loadReadOnly(
      sessionId: 's',
      sourceCharacter: _character('one'),
    );

    expect(context.effectiveRevision.number, 1);
    expect(await revisions.getForCharacter('c'), isEmpty);
  });

  test('read-only exact state overrides current Ledger and facts', () async {
    final character = _character('one');
    raw = LedgerRawTrackerState(
      committedTrackers: const [
        Tracker(
          sessionId: 's',
          name: 'world:time',
          value: 'current',
          scope: 'ledger',
        ),
      ],
      manualControls: const [],
    );

    final context = await loader.loadReadOnlyFromReconciliationState(
      sessionId: 's',
      sourceCharacter: character,
      ledgerTrackers: const [
        Tracker(
          sessionId: 's',
          name: 'world:time',
          value: 'captured',
          scope: 'ledger',
        ),
        Tracker(
          sessionId: 's',
          name: 'canon_lock:world:time',
          value: 'true',
          scope: 'ledger',
        ),
      ],
      knowledgeFacts: [
        CharacterKnowledgeFact(
          id: 'captured-fact',
          chatSessionId: 's',
          knowerKey: 'entity:a',
          subjectKey: 'entity:b',
          factClass: CharacterKnowledgeFactClass.knowledge,
          predicate: 'knows',
          object: 'captured fact',
          epistemicState: CharacterKnowledgeEpistemicState.confirmed,
          sourceMessageId: 'm1',
          sourceSwipeId: 0,
          sourceAgentSwipeId: 0,
          lifecycle: CharacterKnowledgeFactLifecycle.active,
        ),
      ],
    );

    expect(context.committedTrackers.single.value, 'captured');
    expect(context.manualControls.single.name, 'canon_lock:world:time');
    expect(context.resolution.activeFacts.single.id, 'captured-fact');
    expect(await revisions.getForCharacter('c'), isEmpty);
  });

  test(
    'follow, pinned, ask, and unmappable baseline policies fail safely',
    () async {
      final first = _character('one');
      await loader.load(sessionId: 's', sourceCharacter: first);
      final second = first.copyWith(description: 'two');
      await loader.load(sessionId: 's', sourceCharacter: second);
      final firstHash = CardCanonicalizer.sha256(first);
      await baselines.ensureBaseline(
        CharacterSessionBaseline(
          chatSessionId: 's',
          characterId: 'c',
          baselineCardJson: jsonEncode(first.toJson()),
          baselineHash: firstHash,
          sourceHashLastSeen: firstHash,
          cardUpdatePolicy: CharacterCardUpdatePolicy.pinnedBaseline,
        ),
      );
      var context = await loader.load(sessionId: 's', sourceCharacter: second);
      expect(context.character.description, 'one');
      await loader.load(sessionId: 's', sourceCharacter: first);
      context = await loader.load(sessionId: 's', sourceCharacter: first);
      expect(context.character.description, 'one');
      expect(context.effectiveRevision.number, 1);
      await baselines.updatePolicy(
        sessionId: 's',
        policy: CharacterCardUpdatePolicy.askOnChange,
      );
      context = await loader.load(sessionId: 's', sourceCharacter: second);
      expect(context.requiresBaselineDecision, isTrue);
      await db.customStatement(
        "UPDATE character_session_baseline_rows SET baseline_hash = 'missing' WHERE chat_session_id = 's'",
      );
      expect(
        () => loader.load(sessionId: 's', sourceCharacter: second),
        throwsA(isA<EffectiveCanonContextUnavailable>()),
      );
    },
  );

  test(
    'raw controls stay separate and transition/control changes invalidate stamp',
    () async {
      final character = _character('one');
      final initial = await loader.load(
        sessionId: 's',
        sourceCharacter: character,
      );
      await transitions.insert(
        AppliedCanonTransitionRecord(
          id: 't',
          characterId: 'c',
          chatSessionId: 's',
          rewriteOperationId: 'op',
          revision: 1,
          revisionHash: initial.effectiveRevision.hash,
          semanticScopeKey: 'npc:alice',
          canonicalClaim: 'new',
          promotionDestination: 'card',
          affectedTrackerKeys: const ['alice.status'],
          transitionJson: '{}',
        ),
      );
      raw = LedgerRawTrackerState(
        committedTrackers: const [
          Tracker(
            sessionId: 's',
            name: 'alice.status',
            scope: 'ledger',
            basisRevisionNumber: 0,
          ),
        ],
        manualControls: const [
          Tracker(
            sessionId: 's',
            name: 'canon_override:alice.status',
            value: 'manual',
            scope: 'ledger',
            updatedAt: 1,
          ),
        ],
      );
      final next = await loader.load(
        sessionId: 's',
        sourceCharacter: character,
      );
      expect(next.committedTrackers.single.name, 'alice.status');
      expect(next.manualControls.single.name, 'canon_override:alice.status');
      expect(next.resolution.filteredTrackers, hasLength(1));
      expect(
        await loader.isStillCurrentReadOnly(
          sessionId: 's',
          sourceCharacter: character,
          stamp: initial.stamp,
        ),
        isFalse,
      );
    },
  );

  test('stamp detects content-only changes with unchanged timestamps', () async {
    final character = _character('one');
    final base = await loader.load(sessionId: 's', sourceCharacter: character);
    raw = LedgerRawTrackerState(
      committedTrackers: const [
        Tracker(
          sessionId: 's',
          name: 'world:time',
          value: 'day',
          scope: 'ledger',
          provenance: 'p',
          updatedAt: 1,
        ),
      ],
      manualControls: const [
        Tracker(
          sessionId: 's',
          name: 'canon_override:world:time',
          value: 'day',
          scope: 'ledger',
          provenance: 'p',
          updatedAt: 1,
        ),
      ],
    );
    final trackerStamp = (await loader.load(
      sessionId: 's',
      sourceCharacter: character,
    )).stamp;
    raw = LedgerRawTrackerState(
      committedTrackers: const [
        Tracker(
          sessionId: 's',
          name: 'world:time',
          value: 'night',
          scope: 'ledger',
          provenance: 'p',
          updatedAt: 1,
        ),
      ],
      manualControls: const [
        Tracker(
          sessionId: 's',
          name: 'canon_override:world:time',
          value: 'night',
          scope: 'ledger',
          provenance: 'p',
          updatedAt: 1,
        ),
      ],
    );
    expect(
      await loader.isStillCurrentReadOnly(
        sessionId: 's',
        sourceCharacter: character,
        stamp: trackerStamp,
      ),
      isFalse,
    );

    await facts.insertTentative(_fact('f'));
    final factStamp = (await loader.load(
      sessionId: 's',
      sourceCharacter: character,
    )).stamp;
    await db.customStatement(
      "UPDATE character_knowledge_fact_rows SET lifecycle = 'retracted', object = 'changed' WHERE id = 'f'",
    );
    expect(
      await loader.isStillCurrentReadOnly(
        sessionId: 's',
        sourceCharacter: character,
        stamp: factStamp,
      ),
      isFalse,
    );

    await transitions.insert(
      const AppliedCanonTransitionRecord(
        id: 't',
        characterId: 'c',
        chatSessionId: 's',
        rewriteOperationId: 'op',
        revision: 1,
        revisionHash: 'h',
        semanticScopeKey: 'scope',
        canonicalClaim: 'claim',
        promotionDestination: 'card',
        affectedTrackerKeys: ['a'],
        transitionJson: '{}',
      ),
    );
    final transitionStamp = (await loader.load(
      sessionId: 's',
      sourceCharacter: character,
    )).stamp;
    await db.customStatement(
      "UPDATE applied_canon_transition_rows SET semantic_scope_key = 'changed', canonical_claim = 'changed', affected_tracker_keys_json = '[\"b\"]' WHERE id = 't'",
    );
    expect(
      await loader.isStillCurrentReadOnly(
        sessionId: 's',
        sourceCharacter: character,
        stamp: transitionStamp,
      ),
      isFalse,
    );

    await refs.insert(
      const CanonTransitionFactRef(transitionId: 't', factId: 'f'),
    );
    final refStamp = (await loader.load(
      sessionId: 's',
      sourceCharacter: character,
    )).stamp;
    await db.customStatement(
      "UPDATE canon_transition_fact_refs SET character_knowledge_fact_id = 'other' WHERE applied_canon_transition_id = 't' AND character_knowledge_fact_id = 'f'",
    );
    expect(
      await loader.isStillCurrentReadOnly(
        sessionId: 's',
        sourceCharacter: character,
        stamp: refStamp,
      ),
      isFalse,
    );
    expect(base.stamp.identity, isNotEmpty);
  });

  test('stamp is independent of raw tracker ordering', () async {
    final character = _character('one');
    raw = LedgerRawTrackerState(
      committedTrackers: const [
        Tracker(sessionId: 's', name: 'b', value: '2'),
        Tracker(sessionId: 's', name: 'a', value: '1'),
      ],
      manualControls: const [
        Tracker(sessionId: 's', name: 'canon_lock:b', value: 'true'),
        Tracker(sessionId: 's', name: 'canon_lock:a', value: 'true'),
      ],
    );
    final stamp = (await loader.load(
      sessionId: 's',
      sourceCharacter: character,
    )).stamp;
    raw = LedgerRawTrackerState(
      committedTrackers: const [
        Tracker(sessionId: 's', name: 'a', value: '1'),
        Tracker(sessionId: 's', name: 'b', value: '2'),
      ],
      manualControls: const [
        Tracker(sessionId: 's', name: 'canon_lock:a', value: 'true'),
        Tracker(sessionId: 's', name: 'canon_lock:b', value: 'true'),
      ],
    );
    expect(
      await loader.isStillCurrentReadOnly(
        sessionId: 's',
        sourceCharacter: character,
        stamp: stamp,
      ),
      isTrue,
    );
  });

  test(
    'aggregate transaction read and pure assembly match loader context',
    () async {
      const character = Character(
        id: 'c',
        name: 'Character',
        description: 'one',
      );
      await characters.put(character);
      final storedCharacter = (await characters.getById('c'))!;
      raw = LedgerRawTrackerState(
        committedTrackers: const [
          Tracker(
            sessionId: 's',
            name: 'world:time',
            value: 'night',
            scope: 'ledger',
          ),
        ],
        manualControls: const [
          Tracker(
            sessionId: 's',
            name: 'canon_lock:world:time',
            value: 'true',
            scope: 'ledger',
          ),
        ],
      );
      final loaded = await loader.load(
        sessionId: 's',
        sourceCharacter: storedCharacter,
      );
      final reader = EffectiveCanonReadRepository.runtime(
        db: db,
        characterRepo: characters,
        revisionRepo: revisions,
        baselineRepo: baselines,
        factRepo: facts,
        transitionRepo: transitions,
        transitionFactRefRepo: refs,
        loadRawTrackerState: (_) async => raw,
      );
      final input = await reader.read(sessionId: 's', characterId: 'c');
      final assembled = const EffectiveCanonAssembler().assemble(input);

      expect(assembled.character, loaded.character);
      expect(
        assembled.effectiveRevision.number,
        loaded.effectiveRevision.number,
      );
      expect(assembled.effectiveRevision.hash, loaded.effectiveRevision.hash);
      expect(assembled.resolution.activeFacts, loaded.resolution.activeFacts);
      expect(
        assembled.resolution.activeTrackers,
        loaded.resolution.activeTrackers,
      );
      expect(assembled.identity, loaded.stamp.identity);
    },
  );
}

Character _character(String description) =>
    Character(id: 'c', name: 'Character', description: description);

CharacterKnowledgeFact _fact(String id) => CharacterKnowledgeFact(
  id: id,
  chatSessionId: 's',
  knowerKey: 'alice',
  subjectKey: 'bob',
  factClass: CharacterKnowledgeFactClass.knowledge,
  predicate: 'knows',
  object: 'original',
  epistemicState: CharacterKnowledgeEpistemicState.observed,
  sourceMessageId: 'm',
  sourceSwipeId: 0,
  sourceAgentSwipeId: 0,
);
