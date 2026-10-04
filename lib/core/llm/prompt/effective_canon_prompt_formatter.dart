import '../../models/character_knowledge_fact.dart';
import '../../models/tracker.dart';
import '../../services/card_rewriter/effective_canon_context_loader.dart';
import '../knowledge/character_knowledge_projection.dart';
import 'studio_session_state_compiler.dart';

/// Serializable, already-resolved canon data. This is deliberately free of
/// repositories so the prompt isolate can only format the main-thread result.
final class EffectiveCanonPromptProjection {
  const EffectiveCanonPromptProjection({
    required this.facts,
    required this.trackers,
    required this.unblockedTransitionClaims,
    this.transitions = const <EffectiveCanonTransitionProjection>[],
    required this.revisionNumber,
    required this.revisionHash,
    required this.cacheIdentity,
  });

  final List<CharacterKnowledgeFact> facts;
  final List<Tracker> trackers;
  final List<String> unblockedTransitionClaims;

  /// Structured form used by selective projection. The legacy claim list is
  /// retained so legacy materialization remains byte-for-byte compatible.
  final List<EffectiveCanonTransitionProjection> transitions;
  final int revisionNumber;
  final String revisionHash;
  final String cacheIdentity;

  factory EffectiveCanonPromptProjection.fromContext(
    EffectiveCanonContext context,
  ) {
    return EffectiveCanonPromptProjection(
      facts: context.resolution.activeFacts,
      // Controls are required by the state compiler to apply explicit user
      // overrides/locks; stale committed rows never cross this boundary.
      trackers: [
        ...context.resolution.activeTrackers,
        ...context.manualControls,
      ],
      unblockedTransitionClaims: context.resolution.scopes.values
          .where((scope) => !scope.isBlocked)
          .map((scope) => scope.currentClaim)
          .where((claim) => claim.trim().isNotEmpty)
          .toList(growable: false),
      transitions: context.resolution.scopes.values
          .where((scope) => !scope.isBlocked)
          .map(
            (scope) => EffectiveCanonTransitionProjection(
              id: scope.transition.id,
              semanticScopeKey: scope.scopeKey,
              affectedTrackerKeys: scope.transition.affectedTrackerKeys,
              claim: scope.currentClaim,
            ),
          )
          .where((item) => item.claim.trim().isNotEmpty)
          .toList(growable: false),
      revisionNumber: context.effectiveRevision.number,
      revisionHash: context.effectiveRevision.hash,
      cacheIdentity: context.cacheIdentity,
    );
  }

  Map<String, dynamic> toJson() => {
    'facts': facts.map(_factToJson).toList(),
    'trackers': trackers.map((value) => value.toJson()).toList(),
    'unblockedTransitionClaims': unblockedTransitionClaims,
    'transitions': transitions.map((value) => value.toJson()).toList(),
    'revisionNumber': revisionNumber,
    'revisionHash': revisionHash,
    'cacheIdentity': cacheIdentity,
  };

  factory EffectiveCanonPromptProjection.fromJson(Map<String, dynamic> json) =>
      EffectiveCanonPromptProjection(
        facts: (json['facts'] as List? ?? const [])
            .map((value) => _factFromJson(value as Map<String, dynamic>))
            .toList(growable: false),
        trackers: (json['trackers'] as List? ?? const [])
            .map((value) => Tracker.fromJson(value as Map<String, dynamic>))
            .toList(growable: false),
        unblockedTransitionClaims:
            (json['unblockedTransitionClaims'] as List? ?? const [])
                .cast<String>(),
        transitions: (json['transitions'] as List? ?? const [])
            .map(
              (value) => EffectiveCanonTransitionProjection.fromJson(
                value as Map<String, dynamic>,
              ),
            )
            .toList(growable: false),
        revisionNumber: json['revisionNumber'] as int,
        revisionHash: json['revisionHash'] as String,
        cacheIdentity: json['cacheIdentity'] as String,
      );
}

final class EffectiveCanonTransitionProjection {
  EffectiveCanonTransitionProjection({
    required this.id,
    required this.semanticScopeKey,
    required Iterable<String> affectedTrackerKeys,
    required this.claim,
  }) : affectedTrackerKeys = List.unmodifiable(affectedTrackerKeys);

  final String id;
  final String semanticScopeKey;
  final List<String> affectedTrackerKeys;
  final String claim;

  Map<String, Object?> toJson() => {
    'id': id,
    'semanticScopeKey': semanticScopeKey,
    'affectedTrackerKeys': affectedTrackerKeys,
    'claim': claim,
  };

  factory EffectiveCanonTransitionProjection.fromJson(
    Map<String, dynamic> json,
  ) => EffectiveCanonTransitionProjection(
    id: json['id'] as String? ?? '',
    semanticScopeKey: json['semanticScopeKey'] as String? ?? '',
    affectedTrackerKeys: (json['affectedTrackerKeys'] as List? ?? const [])
        .cast<String>(),
    claim: json['claim'] as String? ?? '',
  );
}

Map<String, dynamic> _factToJson(CharacterKnowledgeFact value) => {
  'id': value.id,
  'chatSessionId': value.chatSessionId,
  'knowerKey': value.knowerKey,
  'knowerName': value.knowerName,
  'subjectKey': value.subjectKey,
  'subjectName': value.subjectName,
  'factClass': value.factClass.wireName,
  'scopeKey': value.scopeKey,
  'predicate': value.predicate,
  'object': value.object,
  'epistemicState': value.epistemicState.wireName,
  'confidence': value.confidence,
  'importance': value.importance,
  'entities': value.entities,
  'topics': value.topics,
  'sourceMessageId': value.sourceMessageId,
  'sourceSwipeId': value.sourceSwipeId,
  'sourceAgentSwipeId': value.sourceAgentSwipeId,
  'sourceKind': value.sourceKind,
  'supersedesId': value.supersedesId,
  'lifecycle': value.lifecycle.wireName,
  'basisRevisionNumber': value.basisRevisionNumber,
  'basisRevisionHash': value.basisRevisionHash,
  'createdAt': value.createdAt,
  'updatedAt': value.updatedAt,
};

CharacterKnowledgeFact _factFromJson(Map<String, dynamic> value) =>
    CharacterKnowledgeFact(
      id: value['id'] as String,
      chatSessionId: value['chatSessionId'] as String,
      knowerKey: value['knowerKey'] as String,
      knowerName: value['knowerName'] as String? ?? '',
      subjectKey: value['subjectKey'] as String,
      subjectName: value['subjectName'] as String? ?? '',
      factClass: CharacterKnowledgeFactClass.fromWireName(
        value['factClass'] as String,
      ),
      scopeKey: value['scopeKey'] as String? ?? '',
      predicate: value['predicate'] as String,
      object: value['object'] as String,
      epistemicState: CharacterKnowledgeEpistemicState.fromWireName(
        value['epistemicState'] as String,
      ),
      confidence: (value['confidence'] as num).toDouble(),
      importance: (value['importance'] as num).toDouble(),
      entities: (value['entities'] as List).cast<String>(),
      topics: (value['topics'] as List).cast<String>(),
      sourceMessageId: value['sourceMessageId'] as String,
      sourceSwipeId: value['sourceSwipeId'] as int,
      sourceAgentSwipeId: value['sourceAgentSwipeId'] as int,
      sourceKind: value['sourceKind'] as String,
      supersedesId: value['supersedesId'] as String?,
      lifecycle: CharacterKnowledgeFactLifecycle.fromWireName(
        value['lifecycle'] as String,
      ),
      basisRevisionNumber: value['basisRevisionNumber'] as int,
      basisRevisionHash: value['basisRevisionHash'] as String,
      createdAt: value['createdAt'] as int,
      updatedAt: value['updatedAt'] as int,
    );

final class EffectiveCanonPromptContent {
  const EffectiveCanonPromptContent({
    this.characterKnowledge,
    this.sessionState,
  });
  final String? characterKnowledge;
  final String? sessionState;
}

abstract final class EffectiveCanonPromptFormatter {
  static EffectiveCanonPromptContent format(
    EffectiveCanonPromptProjection projection, {
    required String sessionId,
    required String latestUserText,
    required String latestAssistantText,
  }) {
    final state = compileStudioSessionState(
      projection.trackers,
      sessionId,
      latestUserText: latestUserText,
      latestAssistantText: latestAssistantText,
    );
    final claims = projection.unblockedTransitionClaims;
    final transitions = claims.isEmpty
        ? null
        : '<effective_canon_transitions>\n'
              'Canonical transition claims for unblocked scopes:\n'
              '${claims.map((claim) => '- $claim').join('\n')}\n'
              '</effective_canon_transitions>';
    return EffectiveCanonPromptContent(
      characterKnowledge: compileCharacterKnowledgeProjection(
        projection.facts,
        latestUserText: latestUserText,
        latestAssistantText: latestAssistantText,
      ),
      sessionState:
          [state, transitions].whereType<String>().join('\n\n').trim().isEmpty
          ? null
          : [state, transitions].whereType<String>().join('\n\n'),
    );
  }
}
