/// Pure, revision-lineage-aware filtering for canon transitions.
library;

import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

final class CanonRevisionIdentity {
  const CanonRevisionIdentity({required this.number, required this.hash});
  final int number;
  final String hash;
}

/// Authoritative known revision identity. Revision numbers are device-local;
/// hashes identify the same semantic revision across cloud-synced devices.
/// `(0, '')` is the one explicit legacy-compatible pair.
final class CanonRevisionLineage {
  CanonRevisionLineage(Iterable<CanonRevisionIdentity> revisions)
    : revisions = List.unmodifiable(revisions) {
    if (this.revisions.any((item) => item.number == 0 && item.hash.isEmpty)) {
      throw ArgumentError.value(
        revisions,
        'revisions',
        'must not include legacy identity',
      );
    }
  }
  final List<CanonRevisionIdentity> revisions;

  bool contains(int number, String hash) =>
      (number == 0 && hash.isEmpty) ||
      revisions.any((item) => item.number == number && item.hash == hash);

  /// Resolves persisted fact/tracker provenance to this device's local
  /// revision number. A known hash remains authoritative even when the source
  /// device assigned it a different ordinal. Unknown hashes fail closed.
  CanonRevisionIdentity? resolveRecord(int number, String hash) {
    if (number == 0 && hash.isEmpty) {
      return const CanonRevisionIdentity(number: 0, hash: '');
    }
    final exact = revisions
        .where((item) => item.number == number && item.hash == hash)
        .firstOrNull;
    if (exact != null) return exact;
    final matches = revisions.where((item) => item.hash == hash).toList();
    return matches.length == 1 ? matches.single : null;
  }
}

final class CanonFenceTransition {
  CanonFenceTransition({
    required this.id,
    required this.scopeKey,
    required this.revisionNumber,
    required this.revisionHash,
    required this.canonicalClaim,
    Iterable<String> affectedTrackerKeys = const <String>[],
    this.provenance = '',
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : affectedTrackerKeys = List.unmodifiable(affectedTrackerKeys),
       metadata = Map.unmodifiable(metadata);
  final String id;
  final String scopeKey;
  final int revisionNumber;
  final String revisionHash;
  final String canonicalClaim;
  final List<String> affectedTrackerKeys;
  final String provenance;
  final Map<String, Object?> metadata;
}

/// Mirrors the explicit transition-to-fact relationship without persistence.
final class CanonTransitionFactRef {
  const CanonTransitionFactRef({
    required this.transitionId,
    required this.factId,
  });
  final String transitionId;
  final String factId;
}

enum CanonFenceRejection {
  invalidScope,
  invalidRevision,
  unknownRevision,
  futureRevision,
}

enum CanonFenceRecordRejection { unknownBasisRevision, futureBasisRevision }

final class RejectedCanonFenceTransition {
  const RejectedCanonFenceTransition(this.transition, this.reason);
  final CanonFenceTransition transition;
  final CanonFenceRejection reason;
}

final class RejectedCanonFenceFact {
  const RejectedCanonFenceFact(this.fact, this.reason);
  final CharacterKnowledgeFact fact;
  final CanonFenceRecordRejection reason;
}

final class RejectedCanonFenceTracker {
  const RejectedCanonFenceTracker(this.tracker, this.reason);
  final Tracker tracker;
  final CanonFenceRecordRejection reason;
}

final class EffectiveCanonScope {
  EffectiveCanonScope({
    required this.scopeKey,
    required this.transition,
    required this.currentClaim,
    required this.isBlocked,
    required Iterable<String> referencedFactIds,
    required Map<String, String> manualClaimsByTrackerKey,
  }) : referencedFactIds = Set.unmodifiable(referencedFactIds),
       manualClaimsByTrackerKey = Map.unmodifiable(manualClaimsByTrackerKey);
  final String scopeKey;
  final CanonFenceTransition transition;
  final String currentClaim;
  final bool isBlocked;
  final Set<String> referencedFactIds;

  /// Opaque manual values, keyed by their exact affected Ledger key.
  final Map<String, String> manualClaimsByTrackerKey;
}

final class EffectiveCanonFenceResolution {
  EffectiveCanonFenceResolution({
    required Iterable<CharacterKnowledgeFact> activeFacts,
    required Iterable<CharacterKnowledgeFact> historicalFacts,
    required Iterable<Tracker> activeTrackers,
    required Iterable<Tracker> filteredTrackers,
    required Map<String, EffectiveCanonScope> scopes,
    required Iterable<RejectedCanonFenceTransition> rejectedTransitions,
    required Iterable<RejectedCanonFenceFact> rejectedFacts,
    required Iterable<RejectedCanonFenceTracker> rejectedTrackers,
  }) : activeFacts = List.unmodifiable(activeFacts),
       historicalFacts = List.unmodifiable(historicalFacts),
       activeTrackers = List.unmodifiable(activeTrackers),
       filteredTrackers = List.unmodifiable(filteredTrackers),
       scopes = Map.unmodifiable(scopes),
       rejectedTransitions = List.unmodifiable(rejectedTransitions),
       rejectedFacts = List.unmodifiable(rejectedFacts),
       rejectedTrackers = List.unmodifiable(rejectedTrackers);
  final List<CharacterKnowledgeFact> activeFacts;
  final List<CharacterKnowledgeFact> historicalFacts;
  final List<Tracker> activeTrackers;
  final List<Tracker> filteredTrackers;
  final Map<String, EffectiveCanonScope> scopes;
  final List<RejectedCanonFenceTransition> rejectedTransitions;
  final List<RejectedCanonFenceFact> rejectedFacts;
  final List<RejectedCanonFenceTracker> rejectedTrackers;
}

abstract final class EffectiveCanonFenceResolver {
  static EffectiveCanonFenceResolution resolve({
    required Iterable<CharacterKnowledgeFact> facts,
    required Iterable<Tracker> trackers,
    required Iterable<CanonFenceTransition> transitions,
    required CanonRevisionIdentity currentRevision,
    required CanonRevisionLineage lineage,
    Iterable<CanonTransitionFactRef> transitionFactRefs =
        const <CanonTransitionFactRef>[],
    Iterable<Tracker> manualControls = const <Tracker>[],
  }) {
    if (!lineage.contains(currentRevision.number, currentRevision.hash)) {
      throw ArgumentError.value(
        currentRevision,
        'currentRevision',
        'must be in authoritative lineage',
      );
    }
    final accepted = <String, CanonFenceTransition>{};
    final rejected = <RejectedCanonFenceTransition>[];
    for (final transition in transitions) {
      final reason = _transitionRejection(transition, lineage, currentRevision);
      if (reason != null) {
        rejected.add(RejectedCanonFenceTransition(transition, reason));
      } else if (accepted[transition.scopeKey] == null ||
          transition.revisionNumber >
              accepted[transition.scopeKey]!.revisionNumber) {
        accepted[transition.scopeKey] = transition;
      }
    }
    final acceptedIds = accepted.values.map((item) => item.id).toSet();
    final referenced = <String, Set<String>>{};
    for (final ref in transitionFactRefs) {
      if (acceptedIds.contains(ref.transitionId)) {
        referenced
            .putIfAbsent(ref.transitionId, () => <String>{})
            .add(ref.factId);
      }
    }
    final controls = _latestControls(manualControls);
    final scopes = <String, EffectiveCanonScope>{};
    for (final transition in accepted.values) {
      final claims = <String, String>{};
      for (final key in transition.affectedTrackerKeys) {
        final override = controls['canon_override:$key'];
        final lock = controls['canon_lock:$key'];
        if (override != null) claims[key] = override.value;
        if (lock != null) claims[key] = lock.value;
      }
      scopes[transition.scopeKey] = EffectiveCanonScope(
        scopeKey: transition.scopeKey,
        transition: transition,
        currentClaim: claims.isEmpty
            ? transition.canonicalClaim
            : claims.values.first,
        isBlocked: claims.isNotEmpty,
        referencedFactIds: referenced[transition.id] ?? const <String>{},
        manualClaimsByTrackerKey: claims,
      );
    }
    final activeFacts = <CharacterKnowledgeFact>[];
    final historicalFacts = <CharacterKnowledgeFact>[];
    final rejectedFacts = <RejectedCanonFenceFact>[];
    for (final fact in facts) {
      final basis = lineage.resolveRecord(
        fact.basisRevisionNumber,
        fact.basisRevisionHash,
      );
      if (basis == null) {
        rejectedFacts.add(
          RejectedCanonFenceFact(
            fact,
            CanonFenceRecordRejection.unknownBasisRevision,
          ),
        );
        continue;
      }
      if (basis.number > currentRevision.number) {
        rejectedFacts.add(
          RejectedCanonFenceFact(
            fact,
            CanonFenceRecordRejection.futureBasisRevision,
          ),
        );
        continue;
      }
      final scope = scopes[fact.scopeKey];
      if (scope != null && basis.number < scope.transition.revisionNumber) {
        historicalFacts.add(fact);
      } else {
        activeFacts.add(fact);
      }
    }
    final fencesByTracker = <String, CanonFenceTransition>{
      for (final transition in accepted.values)
        for (final key in transition.affectedTrackerKeys) key: transition,
    };
    final activeTrackers = <Tracker>[];
    final filteredTrackers = <Tracker>[];
    final rejectedTrackers = <RejectedCanonFenceTracker>[];
    for (final tracker in trackers) {
      final basis = lineage.resolveRecord(
        tracker.basisRevisionNumber,
        tracker.basisRevisionHash,
      );
      if (basis == null) {
        rejectedTrackers.add(
          RejectedCanonFenceTracker(
            tracker,
            CanonFenceRecordRejection.unknownBasisRevision,
          ),
        );
      } else if (basis.number > currentRevision.number) {
        rejectedTrackers.add(
          RejectedCanonFenceTracker(
            tracker,
            CanonFenceRecordRejection.futureBasisRevision,
          ),
        );
      } else if (fencesByTracker[tracker.name] case final fence?
          when basis.number < fence.revisionNumber) {
        filteredTrackers.add(tracker);
      } else {
        activeTrackers.add(tracker);
      }
    }
    return EffectiveCanonFenceResolution(
      activeFacts: activeFacts,
      historicalFacts: historicalFacts,
      activeTrackers: activeTrackers,
      filteredTrackers: filteredTrackers,
      scopes: scopes,
      rejectedTransitions: rejected,
      rejectedFacts: rejectedFacts,
      rejectedTrackers: rejectedTrackers,
    );
  }

  static CanonFenceRejection? _transitionRejection(
    CanonFenceTransition value,
    CanonRevisionLineage lineage,
    CanonRevisionIdentity currentRevision,
  ) {
    if (CardRewriteScope.tryParse(value.scopeKey) == null) {
      return CanonFenceRejection.invalidScope;
    }
    if (value.id.isEmpty ||
        value.revisionNumber < 0 ||
        value.revisionHash.isEmpty) {
      return CanonFenceRejection.invalidRevision;
    }
    if (!lineage.contains(value.revisionNumber, value.revisionHash)) {
      return CanonFenceRejection.unknownRevision;
    }
    if (value.revisionNumber > currentRevision.number) {
      return CanonFenceRejection.futureRevision;
    }
    return null;
  }

  static Map<String, Tracker> _latestControls(Iterable<Tracker> controls) {
    final result = <String, Tracker>{};
    for (final control in controls) {
      final existing = result[control.name];
      if (existing == null || control.updatedAt > existing.updatedAt) {
        result[control.name] = control;
      }
    }
    return result;
  }
}
