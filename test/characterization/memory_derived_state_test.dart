import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/memory_derived_state.dart';
import 'package:glaze_flutter/core/llm/memory_provenance.dart';

MemoryProvenanceKey _key({String branchId = 'branchA'}) {
  return MemoryProvenanceKey(
    sessionId: 'session1',
    branchId: branchId,
    anchorMessageId: 'assistant1',
    anchorSwipeId: 0,
    settingsRevision: 'settings1',
    memoryRevision: 'memory1',
    historyRevision: 'history1',
  );
}

MemoryDerivedStateProposal _proposal({
  String id = 'proposal1',
  MemoryDerivedStateKind kind = MemoryDerivedStateKind.scene,
  List<MemoryEvidenceRef> evidence = const [
    MemoryEvidenceRef.memoryEntry(id: 'mem1', memoryBookId: 'book1'),
  ],
  MemoryProvenanceKey? provenance,
}) {
  return MemoryDerivedStateProposal(
    id: id,
    kind: kind,
    title: 'Scene state',
    summary: 'The party is at the bridge.',
    evidence: evidence,
    provenance: provenance ?? _key(),
    createdAtMillis: 10,
  );
}

void main() {
  test('proposals require Memory Book or source message evidence', () {
    expect(_proposal().isEvidenceBacked, isTrue);
    expect(
      _proposal(
        evidence: const [
          MemoryEvidenceRef.sourceMessage(
            id: 'message1',
            chatSessionId: 'session1',
            messageIndex: 4,
            swipeId: 0,
          ),
        ],
      ).isEvidenceBacked,
      isTrue,
    );
    expect(_proposal(evidence: const []).isEvidenceBacked, isFalse);
    expect(
      _proposal(
        evidence: const [
          MemoryEvidenceRef.memoryEntry(id: '', memoryBookId: ''),
        ],
      ).isEvidenceBacked,
      isFalse,
    );
  });

  test('read model accepts only evidence-backed proposed state', () {
    final model = MemoryDerivedStateReadModel();

    expect(model.propose(_proposal(id: 'valid')), isTrue);
    expect(
      model.propose(_proposal(id: 'invalid', evidence: const [])),
      isFalse,
    );

    expect(model.freshFor(_key()).map((artifact) => artifact.id), ['valid']);
  });

  test('derived state remains read-only artifact with provenance', () {
    final proposal = _proposal(kind: MemoryDerivedStateKind.event);
    final artifact = proposal.toReadOnlyArtifact();

    expect(artifact.kind, MemoryDerivedArtifactKind.proposedMemory);
    expect(artifact.value, same(proposal));
    expect(artifact.provenance.matches(_key()), isTrue);
  });

  test('active branch change stales proposed derived state', () {
    final model = MemoryDerivedStateReadModel();
    model.propose(_proposal(id: 'scene'));
    model.propose(
      _proposal(id: 'tracker', kind: MemoryDerivedStateKind.tracker),
    );

    final stale = model.markStaleOutside(_key(branchId: 'branchB'));

    expect(stale.map((artifact) => artifact.id), ['scene', 'tracker']);
    expect(stale.map((artifact) => artifact.staleReason).toSet(), {
      MemoryProvenanceStaleReason.branchChanged,
    });
    expect(model.freshFor(_key(branchId: 'branchB')), isEmpty);
  });
}
