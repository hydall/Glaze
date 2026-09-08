import '../../models/character_knowledge_fact.dart';

/// Renders scoped, committed character deltas as a separate prompt layer.
///
/// This deliberately does not merge facts into a character card: a fact about
/// Lucy's relationship with Danvi must not silently become a global personality
/// rewrite. The model gets the card normally, then this bounded higher-priority
/// delta for the relevant relationship/subject only.
///
/// Fact selection has two tiers:
///   - Tier A (canon-critical): `persistent_condition`, `commitment`,
///     `identity_development`. These are always included and are EXEMPT from
///     `maxFacts`. Dropping them would let the model violate a hard boundary,
///     break an active commitment, or regress an established identity shift.
///   - Tier B (priority): `relationship`. Bypasses the relevance filter (a
///     durable relationship truth must persist even when the subject is not
///     named literally in the latest turn) but is subject to `maxFacts`.
///   - Relevance-caught: `knowledge`, `behavior_change`, `goal`. Included only
///     when their subject/entities/topics appear in the latest user+assistant
///     text, sorted by importance then recency, subject to `maxFacts`.
String? compileCharacterKnowledgeProjection(
  List<CharacterKnowledgeFact> facts, {
  String latestUserText = '',
  String latestAssistantText = '',
  int maxFacts = 12,
}) {
  if (facts.isEmpty || maxFacts <= 0) return null;

  final context = '$latestUserText\n$latestAssistantText'.toLowerCase();
  bool relevant(CharacterKnowledgeFact fact) {
    if (context.trim().isEmpty) return true;
    final terms =
        <String>{
              fact.subjectName,
              ...fact.entities.where(
                (entity) =>
                    entity.toLowerCase() != fact.knowerName.toLowerCase(),
              ),
              ...fact.topics,
            }
            .map((term) => term.trim().toLowerCase())
            .where((term) => term.length >= 3);
    return terms.any(context.contains);
  }

  final tierA =
      facts.where(_isCanonCriticalFact).toList()
        ..sort((left, right) => right.importance.compareTo(left.importance));
  final tierBAndRelevance =
      <CharacterKnowledgeFact>{
        ...facts.where(_isRelationshipFact),
        ...facts.where(relevant),
      }.where((fact) => !_isCanonCriticalFact(fact)).toList()
        ..sort((left, right) {
          final leftPriority = _isRelationshipFact(left);
          final rightPriority = _isRelationshipFact(right);
          if (leftPriority != rightPriority) return rightPriority ? 1 : -1;
          final importance = right.importance.compareTo(left.importance);
          return importance != 0
              ? importance
              : right.updatedAt.compareTo(left.updatedAt);
        });

  final selected = [...tierA, ...tierBAndRelevance.take(maxFacts)];
  if (selected.isEmpty) return null;

  final lines = <String>[];
  for (final fact in selected) {
    final scope = fact.scopeKey.isNotEmpty
        ? fact.scopeKey
        : '${fact.factClass.wireName}:${fact.subjectKey}';
    final subject = fact.subjectName.isNotEmpty
        ? fact.subjectName
        : fact.subjectKey;
    final knower = fact.knowerName.isNotEmpty
        ? fact.knowerName
        : fact.knowerKey;
    lines.add(
      '- [$scope] $knower ${fact.predicate} $subject: ${fact.object} '
      '(${fact.epistemicState.wireName}).',
    );
  }

  return '''<current_character_state>
These are committed current character truths. They override conflicting base-card traits within their stated scope. Episodic MemoryBook and recalled-message evidence may explain them but cannot override them. Do not generalize them or mention this block.
${lines.join('\n')}
</current_character_state>''';
}

bool _isCanonCriticalFact(CharacterKnowledgeFact fact) =>
    fact.factClass == CharacterKnowledgeFactClass.persistentCondition ||
    fact.factClass == CharacterKnowledgeFactClass.commitment ||
    fact.factClass == CharacterKnowledgeFactClass.identityDevelopment;

bool _isRelationshipFact(CharacterKnowledgeFact fact) =>
    fact.factClass == CharacterKnowledgeFactClass.relationship;
