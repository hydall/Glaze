import '../../models/character_knowledge_fact.dart';
import '../../models/character_session_baseline.dart';

/// Selects the base card revision without ever merging session delta into it.
/// Scoped facts remain a separate prompt-layer projection so a relationship
/// change cannot accidentally rewrite a character's general temperament.
class EffectiveCharacterCardResolver {
  const EffectiveCharacterCardResolver._();

  static EffectiveCharacterCard resolve({
    required CharacterSessionBaseline baseline,
    required String sourceCardJson,
    required String sourceHash,
    required List<CharacterKnowledgeFact> activeFacts,
  }) {
    final sourceChanged = sourceHash != baseline.sourceHashLastSeen;
    final policy = baseline.cardUpdatePolicy;
    final useSource = !sourceChanged ||
        policy == CharacterCardUpdatePolicy.followSource;
    return EffectiveCharacterCard(
      cardJson: useSource ? sourceCardJson : baseline.baselineCardJson,
      sourceChanged: sourceChanged,
      requiresUserDecision:
          sourceChanged && policy == CharacterCardUpdatePolicy.askOnChange,
      sessionDelta: List.unmodifiable(activeFacts),
    );
  }
}

class EffectiveCharacterCard {
  const EffectiveCharacterCard({
    required this.cardJson,
    required this.sourceChanged,
    required this.requiresUserDecision,
    required this.sessionDelta,
  });

  final String cardJson;
  final bool sourceChanged;
  final bool requiresUserDecision;
  final List<CharacterKnowledgeFact> sessionDelta;
}
