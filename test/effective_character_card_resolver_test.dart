import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/knowledge/effective_character_card_resolver.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/character_session_baseline.dart';

void main() {
  const baseline = CharacterSessionBaseline(
    chatSessionId: 'session-1',
    characterId: 'lucy',
    baselineCardJson: '{"personality":"cold and distrustful"}',
    baselineHash: 'old-card',
    sourceHashLastSeen: 'old-card',
  );
  const source = '{"personality":"more open in general"}';
  const delta = CharacterKnowledgeFact(
    id: 'trust-danvi',
    chatSessionId: 'session-1',
    knowerKey: 'entity:lucy',
    subjectKey: 'entity:danvi',
    factClass: CharacterKnowledgeFactClass.relationship,
    scopeKey: 'relationship:danvi',
    predicate: 'trusts',
    object: 'trusts Danvi with vulnerable work',
    epistemicState: CharacterKnowledgeEpistemicState.confirmed,
    sourceMessageId: 'm1',
    sourceSwipeId: 0,
    sourceAgentSwipeId: 0,
    lifecycle: CharacterKnowledgeFactLifecycle.active,
  );

  test(
    'follow_source adopts source-card changes and preserves scoped delta',
    () {
      final result = EffectiveCharacterCardResolver.resolve(
        baseline: baseline,
        sourceCardJson: source,
        sourceHash: 'new-card',
        activeFacts: const [delta],
      );

      expect(result.cardJson, source);
      expect(result.sourceChanged, isTrue);
      expect(result.requiresUserDecision, isFalse);
      expect(result.sessionDelta, const [delta]);
    },
  );

  test(
    'pinned_baseline uses immutable session-start card after source edit',
    () {
      final result = EffectiveCharacterCardResolver.resolve(
        baseline: baseline.copyWith(
          cardUpdatePolicy: CharacterCardUpdatePolicy.pinnedBaseline,
        ),
        sourceCardJson: source,
        sourceHash: 'new-card',
        activeFacts: const [delta],
      );

      expect(result.cardJson, baseline.baselineCardJson);
      expect(result.sourceChanged, isTrue);
      expect(result.requiresUserDecision, isFalse);
      expect(result.sessionDelta.single.scopeKey, 'relationship:danvi');
    },
  );

  test('ask_on_change retains baseline while requesting explicit choice', () {
    final result = EffectiveCharacterCardResolver.resolve(
      baseline: baseline.copyWith(
        cardUpdatePolicy: CharacterCardUpdatePolicy.askOnChange,
      ),
      sourceCardJson: source,
      sourceHash: 'new-card',
      activeFacts: const [delta],
    );

    expect(result.cardJson, baseline.baselineCardJson);
    expect(result.sourceChanged, isTrue);
    expect(result.requiresUserDecision, isTrue);
    expect(result.sessionDelta, const [delta]);
  });
}
