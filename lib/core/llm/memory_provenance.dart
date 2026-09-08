enum MemoryDerivedArtifactKind { tracker, proposedMemory, scene }

enum MemoryProvenanceStaleReason {
  sessionChanged,
  branchChanged,
  swipeChanged,
  settingsChanged,
  memoryChanged,
  historyChanged,
}

class MemoryProvenanceKey {
  final String sessionId;
  final String branchId;
  final String anchorMessageId;
  final int anchorSwipeId;
  final String settingsRevision;
  final String memoryRevision;
  final String historyRevision;

  const MemoryProvenanceKey({
    required this.sessionId,
    required this.branchId,
    required this.anchorMessageId,
    required this.anchorSwipeId,
    required this.settingsRevision,
    required this.memoryRevision,
    required this.historyRevision,
  });

  MemoryProvenanceStaleReason? staleReasonFor(MemoryProvenanceKey active) {
    if (sessionId != active.sessionId) {
      return MemoryProvenanceStaleReason.sessionChanged;
    }
    if (branchId != active.branchId) {
      return MemoryProvenanceStaleReason.branchChanged;
    }
    if (anchorMessageId != active.anchorMessageId ||
        anchorSwipeId != active.anchorSwipeId) {
      return MemoryProvenanceStaleReason.swipeChanged;
    }
    if (settingsRevision != active.settingsRevision) {
      return MemoryProvenanceStaleReason.settingsChanged;
    }
    if (memoryRevision != active.memoryRevision) {
      return MemoryProvenanceStaleReason.memoryChanged;
    }
    if (historyRevision != active.historyRevision) {
      return MemoryProvenanceStaleReason.historyChanged;
    }
    return null;
  }

  bool matches(MemoryProvenanceKey active) => staleReasonFor(active) == null;
}

class MemoryDerivedArtifact<T> {
  final String id;
  final MemoryDerivedArtifactKind kind;
  final MemoryProvenanceKey provenance;
  final T value;
  final int createdAtMillis;
  final MemoryProvenanceStaleReason? staleReason;

  const MemoryDerivedArtifact({
    required this.id,
    required this.kind,
    required this.provenance,
    required this.value,
    required this.createdAtMillis,
    this.staleReason,
  });

  bool get isStale => staleReason != null;

  MemoryDerivedArtifact<T> markStale(MemoryProvenanceStaleReason staleReason) {
    if (isStale) return this;
    return MemoryDerivedArtifact<T>(
      id: id,
      kind: kind,
      provenance: provenance,
      value: value,
      createdAtMillis: createdAtMillis,
      staleReason: staleReason,
    );
  }

  MemoryDerivedArtifact<T> markStaleIfNeeded(MemoryProvenanceKey active) {
    final reason = provenance.staleReasonFor(active);
    if (reason == null) return this;
    return markStale(reason);
  }
}

class MemoryProvenanceIndex<T> {
  final Map<String, MemoryDerivedArtifact<T>> _artifacts = {};

  void put(MemoryDerivedArtifact<T> artifact) {
    _artifacts[artifact.id] = artifact;
  }

  MemoryDerivedArtifact<T>? getById(String id) => _artifacts[id];

  List<MemoryDerivedArtifact<T>> markStaleOutside(MemoryProvenanceKey active) {
    final updated = <MemoryDerivedArtifact<T>>[];
    for (final artifact in _artifacts.values.toList(growable: false)) {
      final next = artifact.markStaleIfNeeded(active);
      if (!identical(next, artifact)) {
        _artifacts[artifact.id] = next;
        updated.add(next);
      }
    }
    return updated;
  }

  List<MemoryDerivedArtifact<T>> freshFor(MemoryProvenanceKey active) {
    return _artifacts.values
        .where((artifact) => !artifact.isStale)
        .where((artifact) => artifact.provenance.matches(active))
        .toList(growable: false);
  }

  void clear() => _artifacts.clear();
}
