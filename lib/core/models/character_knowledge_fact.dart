enum CharacterKnowledgeFactClass {
  knowledge,
  relationship,
  behaviorChange,
  commitment,
  goal,
  persistentCondition,
  identityDevelopment;

  String get wireName => switch (this) {
    CharacterKnowledgeFactClass.knowledge => 'knowledge',
    CharacterKnowledgeFactClass.relationship => 'relationship',
    CharacterKnowledgeFactClass.behaviorChange => 'behavior_change',
    CharacterKnowledgeFactClass.commitment => 'commitment',
    CharacterKnowledgeFactClass.goal => 'goal',
    CharacterKnowledgeFactClass.persistentCondition => 'persistent_condition',
    CharacterKnowledgeFactClass.identityDevelopment => 'identity_development',
  };

  static CharacterKnowledgeFactClass fromWireName(String value) {
    return CharacterKnowledgeFactClass.values.firstWhere(
      (item) => item.wireName == value,
      orElse: () => CharacterKnowledgeFactClass.knowledge,
    );
  }
}

enum CharacterKnowledgeEpistemicState {
  observed,
  heardClaim,
  inferred,
  confirmed,
  disbelieved,
  forgotten,
  retracted;

  String get wireName => switch (this) {
    CharacterKnowledgeEpistemicState.observed => 'observed',
    CharacterKnowledgeEpistemicState.heardClaim => 'heard_claim',
    CharacterKnowledgeEpistemicState.inferred => 'inferred',
    CharacterKnowledgeEpistemicState.confirmed => 'confirmed',
    CharacterKnowledgeEpistemicState.disbelieved => 'disbelieved',
    CharacterKnowledgeEpistemicState.forgotten => 'forgotten',
    CharacterKnowledgeEpistemicState.retracted => 'retracted',
  };

  static CharacterKnowledgeEpistemicState fromWireName(String value) {
    return CharacterKnowledgeEpistemicState.values.firstWhere(
      (item) => item.wireName == value,
      orElse: () => CharacterKnowledgeEpistemicState.observed,
    );
  }
}

enum CharacterKnowledgeFactLifecycle {
  tentative,
  active,
  superseded,
  retracted;

  String get wireName => name;

  static CharacterKnowledgeFactLifecycle fromWireName(String value) {
    return CharacterKnowledgeFactLifecycle.values.firstWhere(
      (item) => item.wireName == value,
      orElse: () => CharacterKnowledgeFactLifecycle.tentative,
    );
  }
}

/// Immutable, provenance-anchored delta from a character's selected card.
/// Changes are represented by a successor fact, never an in-place edit.
class CharacterKnowledgeFact {
  const CharacterKnowledgeFact({
    required this.id,
    required this.chatSessionId,
    required this.knowerKey,
    required this.subjectKey,
    required this.factClass,
    required this.predicate,
    required this.object,
    required this.epistemicState,
    required this.sourceMessageId,
    required this.sourceSwipeId,
    required this.sourceAgentSwipeId,
    this.knowerName = '',
    this.subjectName = '',
    this.scopeKey = '',
    this.confidence = 0,
    this.importance = 0,
    this.entities = const [],
    this.topics = const [],
    this.sourceKind = 'studio_ledger',
    this.supersedesId,
    this.lifecycle = CharacterKnowledgeFactLifecycle.tentative,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  final String id;
  final String chatSessionId;
  final String knowerKey;
  final String knowerName;
  final String subjectKey;
  final String subjectName;
  final CharacterKnowledgeFactClass factClass;
  final String scopeKey;
  final String predicate;
  final String object;
  final CharacterKnowledgeEpistemicState epistemicState;
  final double confidence;
  final double importance;
  final List<String> entities;
  final List<String> topics;
  final String sourceMessageId;
  final int sourceSwipeId;
  final int sourceAgentSwipeId;
  final String sourceKind;
  final String? supersedesId;
  final CharacterKnowledgeFactLifecycle lifecycle;
  final int createdAt;
  final int updatedAt;

  CharacterKnowledgeFact copyWith({
    String? id,
    String? chatSessionId,
    String? knowerKey,
    String? knowerName,
    String? subjectKey,
    String? subjectName,
    CharacterKnowledgeFactClass? factClass,
    String? scopeKey,
    String? predicate,
    String? object,
    CharacterKnowledgeEpistemicState? epistemicState,
    double? confidence,
    double? importance,
    List<String>? entities,
    List<String>? topics,
    String? sourceMessageId,
    int? sourceSwipeId,
    int? sourceAgentSwipeId,
    String? sourceKind,
    String? supersedesId,
    bool clearSupersedesId = false,
    CharacterKnowledgeFactLifecycle? lifecycle,
    int? createdAt,
    int? updatedAt,
  }) => CharacterKnowledgeFact(
    id: id ?? this.id,
    chatSessionId: chatSessionId ?? this.chatSessionId,
    knowerKey: knowerKey ?? this.knowerKey,
    knowerName: knowerName ?? this.knowerName,
    subjectKey: subjectKey ?? this.subjectKey,
    subjectName: subjectName ?? this.subjectName,
    factClass: factClass ?? this.factClass,
    scopeKey: scopeKey ?? this.scopeKey,
    predicate: predicate ?? this.predicate,
    object: object ?? this.object,
    epistemicState: epistemicState ?? this.epistemicState,
    confidence: confidence ?? this.confidence,
    importance: importance ?? this.importance,
    entities: entities ?? this.entities,
    topics: topics ?? this.topics,
    sourceMessageId: sourceMessageId ?? this.sourceMessageId,
    sourceSwipeId: sourceSwipeId ?? this.sourceSwipeId,
    sourceAgentSwipeId: sourceAgentSwipeId ?? this.sourceAgentSwipeId,
    sourceKind: sourceKind ?? this.sourceKind,
    supersedesId: clearSupersedesId
        ? null
        : (supersedesId ?? this.supersedesId),
    lifecycle: lifecycle ?? this.lifecycle,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
