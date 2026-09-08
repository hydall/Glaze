import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/memory_provenance.dart';

MemoryProvenanceKey _key({
  String sessionId = 'session1',
  String branchId = 'branchA',
  String anchorMessageId = 'message1',
  int anchorSwipeId = 0,
  String settingsRevision = 'settings1',
  String memoryRevision = 'memory1',
  String historyRevision = 'history1',
}) {
  return MemoryProvenanceKey(
    sessionId: sessionId,
    branchId: branchId,
    anchorMessageId: anchorMessageId,
    anchorSwipeId: anchorSwipeId,
    settingsRevision: settingsRevision,
    memoryRevision: memoryRevision,
    historyRevision: historyRevision,
  );
}

MemoryDerivedArtifact<String> _artifact({
  String id = 'artifact1',
  MemoryProvenanceKey? provenance,
}) {
  return MemoryDerivedArtifact<String>(
    id: id,
    kind: MemoryDerivedArtifactKind.tracker,
    provenance: provenance ?? _key(),
    value: 'derived output',
    createdAtMillis: 10,
  );
}

void main() {
  test('matching active provenance remains fresh', () {
    final artifact = _artifact();

    expect(artifact.markStaleIfNeeded(_key()), same(artifact));
    expect(artifact.provenance.matches(_key()), isTrue);
  });

  test('detects stale reason for branch swipe settings memory and history', () {
    final cases = {
      _key(sessionId: 'session2'): MemoryProvenanceStaleReason.sessionChanged,
      _key(branchId: 'branchB'): MemoryProvenanceStaleReason.branchChanged,
      _key(anchorSwipeId: 1): MemoryProvenanceStaleReason.swipeChanged,
      _key(anchorMessageId: 'message2'):
          MemoryProvenanceStaleReason.swipeChanged,
      _key(settingsRevision: 'settings2'):
          MemoryProvenanceStaleReason.settingsChanged,
      _key(memoryRevision: 'memory2'):
          MemoryProvenanceStaleReason.memoryChanged,
      _key(historyRevision: 'history2'):
          MemoryProvenanceStaleReason.historyChanged,
    };

    for (final entry in cases.entries) {
      expect(_key().staleReasonFor(entry.key), entry.value);
    }
  });

  test('active branch changes mark only stale artifacts', () {
    final index = MemoryProvenanceIndex<String>();
    index.put(_artifact(id: 'matching'));
    index.put(_artifact(id: 'oldBranch'));

    final stale = index.markStaleOutside(_key(branchId: 'branchB'));

    expect(stale, hasLength(2));
    expect(
      index.getById('oldBranch')!.staleReason,
      MemoryProvenanceStaleReason.branchChanged,
    );
    expect(index.freshFor(_key(branchId: 'branchB')), isEmpty);
  });

  test('freshFor excludes stale artifacts and mismatched active scope', () {
    final index = MemoryProvenanceIndex<String>();
    index.put(_artifact(id: 'current'));
    index.put(
      _artifact(
        id: 'otherBranch',
        provenance: _key(branchId: 'branchB'),
      ),
    );
    index.put(
      _artifact(
        id: 'oldSettings',
      ).markStale(MemoryProvenanceStaleReason.settingsChanged),
    );

    final fresh = index.freshFor(_key());

    expect(fresh.map((artifact) => artifact.id), ['current']);
  });
}
