import 'memory_provenance.dart';

enum MemoryEvidenceKind { memoryEntry, sourceMessage }

enum MemoryDerivedStateKind { tracker, arc, event, scene }

class MemoryEvidenceRef {
  final MemoryEvidenceKind kind;
  final String id;
  final String? memoryBookId;
  final String? chatSessionId;
  final int? messageIndex;
  final int? swipeId;

  const MemoryEvidenceRef.memoryEntry({
    required this.id,
    required String this.memoryBookId,
  }) : kind = MemoryEvidenceKind.memoryEntry,
       chatSessionId = null,
       messageIndex = null,
       swipeId = null;

  const MemoryEvidenceRef.sourceMessage({
    required this.id,
    required String this.chatSessionId,
    this.messageIndex,
    this.swipeId,
  }) : kind = MemoryEvidenceKind.sourceMessage,
       memoryBookId = null;

  bool get isValid {
    if (id.isEmpty) return false;
    switch (kind) {
      case MemoryEvidenceKind.memoryEntry:
        return memoryBookId != null && memoryBookId!.isNotEmpty;
      case MemoryEvidenceKind.sourceMessage:
        return chatSessionId != null && chatSessionId!.isNotEmpty;
    }
  }
}

class MemoryDerivedStateProposal {
  final String id;
  final MemoryDerivedStateKind kind;
  final String title;
  final String summary;
  final List<MemoryEvidenceRef> evidence;
  final MemoryProvenanceKey provenance;
  final int createdAtMillis;

  const MemoryDerivedStateProposal({
    required this.id,
    required this.kind,
    required this.title,
    required this.summary,
    required this.evidence,
    required this.provenance,
    required this.createdAtMillis,
  });

  bool get isEvidenceBacked {
    return evidence.isNotEmpty && evidence.every((ref) => ref.isValid);
  }

  MemoryDerivedArtifact<MemoryDerivedStateProposal> toReadOnlyArtifact() {
    return MemoryDerivedArtifact<MemoryDerivedStateProposal>(
      id: id,
      kind: _artifactKind(kind),
      provenance: provenance,
      value: this,
      createdAtMillis: createdAtMillis,
    );
  }

  static MemoryDerivedArtifactKind _artifactKind(MemoryDerivedStateKind kind) {
    switch (kind) {
      case MemoryDerivedStateKind.tracker:
        return MemoryDerivedArtifactKind.tracker;
      case MemoryDerivedStateKind.arc:
        return MemoryDerivedArtifactKind.tracker;
      case MemoryDerivedStateKind.event:
        return MemoryDerivedArtifactKind.proposedMemory;
      case MemoryDerivedStateKind.scene:
        return MemoryDerivedArtifactKind.scene;
    }
  }
}

class MemoryDerivedStateReadModel {
  final MemoryProvenanceIndex<MemoryDerivedStateProposal> _index;

  MemoryDerivedStateReadModel({
    MemoryProvenanceIndex<MemoryDerivedStateProposal>? index,
  }) : _index = index ?? MemoryProvenanceIndex<MemoryDerivedStateProposal>();

  bool propose(MemoryDerivedStateProposal proposal) {
    if (!proposal.isEvidenceBacked) return false;
    _index.put(proposal.toReadOnlyArtifact());
    return true;
  }

  List<MemoryDerivedArtifact<MemoryDerivedStateProposal>> freshFor(
    MemoryProvenanceKey active,
  ) {
    return _index.freshFor(active);
  }

  List<MemoryDerivedArtifact<MemoryDerivedStateProposal>> markStaleOutside(
    MemoryProvenanceKey active,
  ) {
    return _index.markStaleOutside(active);
  }
}
