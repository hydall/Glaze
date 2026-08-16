import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_fence_resolver.dart';

void main() {
  const revision5 = CanonRevisionIdentity(number: 5, hash: 'h5');
  const revision10 = CanonRevisionIdentity(number: 10, hash: 'h10');
  final lineage = CanonRevisionLineage([revision5, revision10]);
  CharacterKnowledgeFact fact(String id, int number, String hash) =>
      CharacterKnowledgeFact(
        id: id,
        chatSessionId: 's',
        knowerKey: 'a',
        subjectKey: 'b',
        factClass: CharacterKnowledgeFactClass.knowledge,
        scopeKey: 'npc:ada',
        predicate: 'is',
        object: id,
        epistemicState: CharacterKnowledgeEpistemicState.confirmed,
        sourceMessageId: 'm',
        sourceSwipeId: 0,
        sourceAgentSwipeId: 0,
        basisRevisionNumber: number,
        basisRevisionHash: hash,
      );
  Tracker tracker(String name, int number, String hash, {String value = ''}) =>
      Tracker(
        sessionId: 's',
        name: name,
        scope: 'ledger',
        value: value,
        basisRevisionNumber: number,
        basisRevisionHash: hash,
      );
  CanonFenceTransition transition({String hash = 'h5', int revision = 5}) =>
      CanonFenceTransition(
        id: 't',
        scopeKey: 'npc:ada',
        revisionNumber: revision,
        revisionHash: hash,
        canonicalClaim: 'canon',
        affectedTrackerKeys: ['ledger:ada'],
      );
  EffectiveCanonFenceResolution resolve({
    Iterable<CharacterKnowledgeFact> facts = const [],
    Iterable<Tracker> trackers = const [],
    Iterable<Tracker> controls = const [],
    Iterable<CanonFenceTransition>? transitions,
    Iterable<CanonTransitionFactRef> refs = const [],
    CanonRevisionIdentity currentRevision = revision10,
  }) => EffectiveCanonFenceResolver.resolve(
    facts: facts,
    trackers: trackers,
    manualControls: controls,
    transitions: transitions ?? [transition()],
    transitionFactRefs: refs,
    currentRevision: currentRevision,
    lineage: lineage,
  );

  test(
    'fences old known facts, retains successors, and exposes explicit refs',
    () {
      final result = resolve(
        facts: [fact('old', 0, ''), fact('new', 5, 'h5')],
        refs: [const CanonTransitionFactRef(transitionId: 't', factId: 'old')],
      );
      expect(result.historicalFacts.single.id, 'old');
      expect(result.activeFacts.single.id, 'new');
      expect(result.scopes['npc:ada']!.referencedFactIds, {'old'});
    },
  );

  test('rejects unknown transition and record revision/hash pairs', () {
    final result = resolve(
      facts: [fact('bad-fact', 5, 'wrong')],
      trackers: [tracker('ledger:ada', 4, 'unknown')],
      transitions: [transition(hash: 'wrong')],
    );
    expect(
      result.rejectedTransitions.single.reason,
      CanonFenceRejection.unknownRevision,
    );
    expect(result.rejectedFacts.single.fact.id, 'bad-fact');
    expect(result.rejectedTrackers.single.tracker.name, 'ledger:ada');
  });

  test('resolves cloud record ordinals by authoritative revision hash', () {
    final result = resolve(
      facts: [fact('cloud-fact', 5, 'h10')],
      trackers: [tracker('cloud-tracker', 5, 'h10')],
    );

    expect(result.activeFacts.single.id, 'cloud-fact');
    expect(result.activeTrackers.single.name, 'cloud-tracker');
    expect(result.rejectedFacts, isEmpty);
    expect(result.rejectedTrackers, isEmpty);
  });

  test(
    'uses local hash ordinal when checking cloud records for future data',
    () {
      final result = resolve(
        currentRevision: revision5,
        facts: [fact('cloud-future', 5, 'h10')],
        trackers: [tracker('cloud-future', 5, 'h10')],
      );

      expect(
        result.rejectedFacts.single.reason,
        CanonFenceRecordRejection.futureBasisRevision,
      );
      expect(
        result.rejectedTrackers.single.reason,
        CanonFenceRecordRejection.futureBasisRevision,
      );
    },
  );

  test('rejects a foreign ordinal when its hash is ambiguous locally', () {
    final ambiguousLineage = CanonRevisionLineage([
      const CanonRevisionIdentity(number: 1, hash: 'same'),
      const CanonRevisionIdentity(number: 3, hash: 'same'),
    ]);

    expect(ambiguousLineage.resolveRecord(2, 'same'), isNull);
    expect(ambiguousLineage.resolveRecord(3, 'same')?.number, 3);
  });

  test('filters only old affected known trackers', () {
    final result = resolve(
      trackers: [
        tracker('ledger:ada', 0, ''),
        tracker('ledger:ada', 5, 'h5'),
        tracker('other', 0, ''),
      ],
    );
    expect(result.filteredTrackers.single.basisRevisionNumber, 0);
    expect(
      result.activeTrackers.map((item) => item.name),
      containsAll(['ledger:ada', 'other']),
    );
  });

  test('manual controls use exact affected ledger keys, not scope aliases', () {
    final result = resolve(
      controls: [
        tracker('canon_override:npc:ada', 0, '', value: 'ignored'),
        tracker('canon_lock:ledger:ada', 0, '', value: 'opaque'),
      ],
    );
    final scope = result.scopes['npc:ada']!;
    expect(scope.isBlocked, isTrue);
    expect(scope.currentClaim, 'opaque');
    expect(scope.manualClaimsByTrackerKey, {'ledger:ada': 'opaque'});
  });

  test('outputs are immutable and transitions snapshot mutable inputs', () {
    final keys = ['ledger:ada'];
    final item = CanonFenceTransition(
      id: 't',
      scopeKey: 'npc:ada',
      revisionNumber: 5,
      revisionHash: 'h5',
      canonicalClaim: 'canon',
      affectedTrackerKeys: keys,
    );
    final result = resolve(transitions: [item]);
    keys.add('later');
    expect(result.scopes['npc:ada']!.transition.affectedTrackerKeys, [
      'ledger:ada',
    ]);
    expect(
      () => result.activeFacts.add(fact('x', 0, '')),
      throwsUnsupportedError,
    );
  });

  test('rejects lineage-valid future data for a pinned current revision', () {
    final result = resolve(
      currentRevision: revision5,
      transitions: [
        transition(),
        transition(revision: 10, hash: 'h10'),
      ],
      facts: [fact('at-five', 5, 'h5'), fact('at-ten', 10, 'h10')],
      trackers: [
        tracker('ledger:ada', 5, 'h5'),
        tracker('ledger:ada', 10, 'h10'),
      ],
    );

    expect(
      result.rejectedTransitions.single.reason,
      CanonFenceRejection.futureRevision,
    );
    expect(
      result.rejectedFacts.single.reason,
      CanonFenceRecordRejection.futureBasisRevision,
    );
    expect(
      result.rejectedTrackers.single.reason,
      CanonFenceRecordRejection.futureBasisRevision,
    );
    expect(result.scopes['npc:ada']!.transition.revisionNumber, 5);
    expect(result.activeFacts.single.id, 'at-five');
    expect(result.activeTrackers.single.basisRevisionNumber, 5);
  });
}
