import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/knowledge/character_knowledge_projection.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';

void main() {
  CharacterKnowledgeFact fact({
    required String id,
    required String subject,
    double importance = 0.5,
    CharacterKnowledgeFactClass factClass =
        CharacterKnowledgeFactClass.relationship,
    String? predicate,
    String? object,
  }) => CharacterKnowledgeFact(
    id: id,
    chatSessionId: 'session-1',
    knowerKey: 'entity:lucy',
    knowerName: 'Lucy',
    subjectKey: 'entity:${subject.toLowerCase()}',
    subjectName: subject,
    factClass: factClass,
    scopeKey: '${factClass.wireName}:${subject.toLowerCase()}',
    predicate: predicate ?? 'trusts',
    object: object ?? 'trusts $subject with vulnerable work',
    epistemicState: CharacterKnowledgeEpistemicState.confirmed,
    importance: importance,
    entities: ['Lucy', subject],
    sourceMessageId: 'm1',
    sourceSwipeId: 0,
    sourceAgentSwipeId: 0,
    lifecycle: CharacterKnowledgeFactLifecycle.active,
  );

  test(
    'projects only context-relevant scoped facts without globalizing them',
    () {
      final content = compileCharacterKnowledgeProjection([
        fact(id: 'danvi', subject: 'Danvi'),
        fact(id: 'david', subject: 'David'),
      ], latestUserText: 'Danvi watches Lucy closely.');

      expect(content, contains('<current_character_state>'));
      expect(content, contains('[relationship:danvi]'));
      expect(content, contains('[relationship:david]'));
      expect(content, contains('within their stated scope'));
    },
  );

  test('caps projected facts by importance', () {
    final content = compileCharacterKnowledgeProjection([
      fact(id: 'low', subject: 'Low', importance: 0.1),
      fact(id: 'high', subject: 'High', importance: 0.9),
    ], maxFacts: 1);

    expect(content, contains('High'));
    expect(content, isNot(contains('Low')));
  });

  test('keeps current relationship truth without a literal context match', () {
    final content = compileCharacterKnowledgeProjection([
      fact(id: 'trust', subject: 'Danvi', importance: 0.9),
    ], latestUserText: 'Продолжаю разговор как обычно.');

    expect(content, contains('[relationship:danvi]'));
    expect(content, contains('override conflicting base-card traits'));
  });

  test(
    'exempts persistent_condition, commitment, and identity_development from cap',
    () {
      final content = compileCharacterKnowledgeProjection([
        fact(
          id: 'boundary',
          subject: 'Danvi',
          importance: 0.9,
          factClass: CharacterKnowledgeFactClass.persistentCondition,
          predicate: 'has_hard_boundary',
          object: 'no anal on him',
        ),
        fact(
          id: 'promise',
          subject: 'Maisie',
          importance: 0.9,
          factClass: CharacterKnowledgeFactClass.commitment,
          predicate: 'committed_to',
          object: 'directly express desires',
        ),
        fact(
          id: 'arc',
          subject: 'Maisie',
          importance: 0.9,
          factClass: CharacterKnowledgeFactClass.identityDevelopment,
          predicate: 'aroused_by',
          object: 'rough scenarios',
        ),
        for (var i = 0; i < 10; i++)
          fact(
            id: 'rel$i',
            subject: 'NPC$i',
            importance: 0.5,
          ),
      ], maxFacts: 2);

      // All three canon-critical facts survive despite maxFacts=2.
      expect(content, contains('[persistent_condition:danvi]'));
      expect(content, contains('[commitment:maisie]'));
      expect(content, contains('[identity_development:maisie]'));
      // Only top 2 of 10 relationship facts fit the cap.
      final relMatches =
          RegExp(r'\[relationship:npc\d+\]').allMatches(content ?? '');
      expect(relMatches.length, 2);
    },
  );

  test('subjects relationship facts to the cap when no tier A is present', () {
    final content = compileCharacterKnowledgeProjection([
      for (var i = 0; i < 5; i++)
        fact(
          id: 'rel$i',
          subject: 'NPC$i',
          importance: 0.5 + i * 0.05,
        ),
    ], maxFacts: 2);

    final matches = RegExp(r'\[relationship:npc\d+\]').allMatches(content ?? '');
    expect(matches.length, 2);
    // Highest-importance two win.
    expect(content, contains('[relationship:npc4]'));
    expect(content, contains('[relationship:npc3]'));
    expect(content, isNot(contains('[relationship:npc0]')));
  });
}

