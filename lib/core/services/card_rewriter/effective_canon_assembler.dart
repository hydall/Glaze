import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/character_session_baseline.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_fence_resolver.dart';

final class EffectiveCanonAssemblyUnavailable implements Exception {
  const EffectiveCanonAssemblyUnavailable(this.message);
  final String message;
  @override
  String toString() => 'EffectiveCanonContextUnavailable: $message';
}

final class EffectiveCanonAssemblyInput {
  const EffectiveCanonAssemblyInput({
    required this.sourceCharacter,
    required this.lineage,
    required this.baseline,
    required this.facts,
    required this.committedTrackers,
    required this.manualControls,
    required this.transitions,
    required this.transitionFactRefs,
  });
  final Character sourceCharacter;
  final List<CharacterRevisionRecord> lineage;
  final CharacterSessionBaseline? baseline;
  final List<CharacterKnowledgeFact> facts;
  final List<Tracker> committedTrackers;
  final List<Tracker> manualControls;
  final List<AppliedCanonTransitionRecord> transitions;
  final List<CanonTransitionFactRef> transitionFactRefs;
}

final class EffectiveCanonAssembly {
  const EffectiveCanonAssembly({
    required this.character,
    required this.effectiveRevision,
    required this.lineage,
    required this.resolution,
    required this.requiresBaselineDecision,
    required this.identity,
  });
  final Character character;
  final CanonRevisionIdentity effectiveRevision;
  final CanonRevisionLineage lineage;
  final EffectiveCanonFenceResolution resolution;
  final bool requiresBaselineDecision;
  final String identity;
}

/// Pure effective-canon selection, fence assembly, and deterministic stamp.
class EffectiveCanonAssembler {
  const EffectiveCanonAssembler();

  /// [stampVolatileState] controls whether per-turn Ledger state (knowledge
  /// facts and committed trackers) participates in the identity hash. Manual
  /// rewrite jobs keep the full fence. Automated evolution proposals use the
  /// stable stamp: the per-turn Ledger mutates committed trackers and facts on
  /// every turn, and per-operation anchor CAS plus dedicated evidence
  /// validation already protect the automated lane's targets.
  EffectiveCanonAssembly assemble(
    EffectiveCanonAssemblyInput input, {
    bool stampVolatileState = true,
  }) {
    if (input.lineage.isEmpty) {
      throw const EffectiveCanonAssemblyUnavailable('Source lineage is empty.');
    }
    final selection = _selectBaseline(input.baseline, input);
    final lineage = CanonRevisionLineage(input.lineage.map(_identity));
    final resolution = EffectiveCanonFenceResolver.resolve(
      facts: input.facts,
      trackers: input.committedTrackers,
      transitions: input.transitions.map((item) => item.toFenceTransition()),
      currentRevision: selection.revision,
      lineage: lineage,
      transitionFactRefs: input.transitionFactRefs,
      manualControls: input.manualControls,
    );
    return EffectiveCanonAssembly(
      character: selection.character,
      effectiveRevision: selection.revision,
      lineage: lineage,
      resolution: resolution,
      requiresBaselineDecision: selection.requiresDecision,
      identity: _stampIdentity(
        input,
        selection.revision,
        stampVolatileState: stampVolatileState,
      ),
    );
  }

  _Selection _selectBaseline(
    CharacterSessionBaseline? baseline,
    EffectiveCanonAssemblyInput input,
  ) {
    final current = input.lineage.last;
    if (baseline == null ||
        baseline.cardUpdatePolicy == CharacterCardUpdatePolicy.followSource) {
      return _Selection(input.sourceCharacter, _identity(current), false);
    }
    final mapped = input.lineage.where(
      (item) => item.revisionHash == baseline.baselineHash,
    );
    if (mapped.isEmpty) {
      throw EffectiveCanonAssemblyUnavailable(
        'Baseline ${baseline.baselineHash} is not in ${input.sourceCharacter.id} lineage.',
      );
    }
    // Hashes identify content, not a unique lineage occurrence. A valid
    // A -> B -> A history can contain the baseline hash more than once; the
    // earliest occurrence is the one that originally established this
    // hash-only legacy baseline.
    final revision = mapped.first;
    final changed = current.revisionHash != baseline.sourceHashLastSeen;
    if (baseline.cardUpdatePolicy == CharacterCardUpdatePolicy.askOnChange &&
        !changed) {
      return _Selection(input.sourceCharacter, _identity(current), false);
    }
    try {
      return _Selection(
        Character.fromJson(
          jsonDecode(revision.snapshotJson) as Map<String, dynamic>,
        ),
        _identity(revision),
        baseline.cardUpdatePolicy == CharacterCardUpdatePolicy.askOnChange,
      );
    } catch (_) {
      throw const EffectiveCanonAssemblyUnavailable(
        'Baseline revision snapshot is unmappable.',
      );
    }
  }

  CanonRevisionIdentity _identity(CharacterRevisionRecord item) =>
      CanonRevisionIdentity(number: item.revision, hash: item.revisionHash);

  String _stampIdentity(
    EffectiveCanonAssemblyInput input,
    CanonRevisionIdentity revision, {
    bool stampVolatileState = true,
  }) => _hash(
    _json({
      'baseline': input.baseline == null
          ? null
          : {
              'sessionId': input.baseline!.chatSessionId,
              'characterId': input.baseline!.characterId,
              'baselineCardJson': input.baseline!.baselineCardJson,
              'baselineHash': input.baseline!.baselineHash,
              'sourceHashLastSeen': input.baseline!.sourceHashLastSeen,
              'policy': input.baseline!.cardUpdatePolicy.wireName,
            },
      'effectiveRevision': {'number': revision.number, 'hash': revision.hash},
      'transitions': _sorted(
        input.transitions.map(
          (item) => {
            'id': item.id,
            'characterId': item.characterId,
            'chatSessionId': item.chatSessionId,
            'rewriteOperationId': item.rewriteOperationId,
            'revision': item.revision,
            'revisionHash': item.revisionHash,
            'scopeKey': item.semanticScopeKey,
            'canonicalClaim': item.canonicalClaim,
            'promotionDestination': item.promotionDestination,
            'affectedTrackerKeys': [...item.affectedTrackerKeys]..sort(),
            'transitionJson': item.transitionJson,
          },
        ),
      ),
      if (stampVolatileState)
        'facts': _sorted(
          input.facts.map(
            (item) => {
              'id': item.id,
              'chatSessionId': item.chatSessionId,
              'knowerKey': item.knowerKey,
              'knowerName': item.knowerName,
              'subjectKey': item.subjectKey,
              'subjectName': item.subjectName,
              'factClass': item.factClass.wireName,
              'scopeKey': item.scopeKey,
              'predicate': item.predicate,
              'object': item.object,
              'epistemicState': item.epistemicState.wireName,
              'confidence': item.confidence,
              'importance': item.importance,
              'entities': [...item.entities]..sort(),
              'topics': [...item.topics]..sort(),
              'sourceMessageId': item.sourceMessageId,
              'sourceSwipeId': item.sourceSwipeId,
              'sourceAgentSwipeId': item.sourceAgentSwipeId,
              'sourceKind': item.sourceKind,
              'supersedesId': item.supersedesId,
              'lifecycle': item.lifecycle.wireName,
              'basisRevisionNumber': item.basisRevisionNumber,
              'basisRevisionHash': item.basisRevisionHash,
            },
          ),
        ),
      if (stampVolatileState)
        'committedTrackers': _sorted(input.committedTrackers.map(_tracker)),
      'manualControls': _sorted(input.manualControls.map(_tracker)),
      'transitionFactRefs': _sorted(
        input.transitionFactRefs.map(
          (item) => {'transitionId': item.transitionId, 'factId': item.factId},
        ),
      ),
    }),
  );

  Map<String, Object?> _tracker(Tracker item) => {
    'sessionId': item.sessionId,
    'name': item.name,
    'value': item.value,
    'scope': item.scope,
    'provenance': item.provenance,
    'basisRevisionNumber': item.basisRevisionNumber,
    'basisRevisionHash': item.basisRevisionHash,
  };
  List<Object?> _sorted(Iterable<Object?> items) {
    final result = items.toList();
    result.sort((a, b) => _json(a).compareTo(_json(b)));
    return result;
  }

  String _json(Object? value) {
    Object? normalize(Object? item) {
      if (item is Map) {
        final keys = item.keys.map((key) => key.toString()).toList()..sort();
        return {for (final key in keys) key: normalize(item[key])};
      }
      if (item is Iterable) return item.map(normalize).toList();
      return item;
    }

    return jsonEncode(normalize(value));
  }

  String _hash(String value) =>
      crypto.sha256.convert(utf8.encode(value)).toString();
}

final class _Selection {
  const _Selection(this.character, this.revision, this.requiresDecision);
  final Character character;
  final CanonRevisionIdentity revision;
  final bool requiresDecision;
}
