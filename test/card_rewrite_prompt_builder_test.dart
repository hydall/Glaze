import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewrite_prompt_builder.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

void main() {
  Character character() => Character(
    id: 'local-id',
    name: 'Ada',
    description: 'A {{char}} who assists {{user}}.',
    personality: 'Precise.',
    scenario: 'Set in the study of {{description}}.',
    systemPrompt: 'Stay in character.',
    creatorNotes: 'Keep the tone dry.',
    alternateGreetings: const ['Hello'],
  );

  String buildPrompt({
    Character? card,
    CardRewriteField field = CardRewriteField.description,
    String instruction = 'Tighten the prose.',
  }) => CardRewriterPromptBuilder.build(
    character: card ?? character(),
    field: field,
    instruction: instruction,
  );

  test(
    'identical character, field, and instruction produce a byte-identical prompt',
    () {
      final first = buildPrompt();
      final second = buildPrompt();
      expect(first, equals(second));
      expect(first.codeUnits, equals(second.codeUnits));
    },
  );

  test('a different instruction changes the prompt', () {
    expect(
      buildPrompt(instruction: 'Make it warmer.'),
      isNot(equals(buildPrompt())),
    );
  });

  test('a different target field changes the prompt', () {
    expect(
      buildPrompt(field: CardRewriteField.personality),
      isNot(equals(buildPrompt())),
    );
  });

  test(
    'a character differing only outside the snapshot yields the same prompt',
    () {
      final uiOnly = character().copyWith(
        avatarPath: '/tmp/avatar.png',
        color: '#fff',
        updatedAt: 5,
        currentSessionIndex: 9,
        fav: true,
        hidden: true,
      );
      expect(buildPrompt(card: uiOnly), equals(buildPrompt()));
    },
  );

  test('prompt names the target field and current field size', () {
    final prompt = buildPrompt(field: CardRewriteField.creatorNotes);
    expect(prompt, contains('- field: creatorNotes'));
    expect(
      prompt,
      contains('- currentFieldCodeUnits: ${'Keep the tone dry.'.length}'),
    );
    expect(
      prompt,
      contains('Respond with exactly ONE JSON object and nothing else'),
    );
  });

  test('prompt lists the writable fields and forbids non-target fields', () {
    final prompt = buildPrompt(field: CardRewriteField.scenario);
    expect(
      prompt,
      contains(
        'Writable fields across this workflow: '
        'description, personality, scenario, systemPrompt, '
        'postHistoryInstructions, creatorNotes.',
      ),
    );
    expect(prompt, contains('For THIS operation only "scenario" is writable.'));
    expect(prompt, contains('read-only'));
  });

  test('evolution prompt prioritizes refining existing card text', () {
    final prompt = CardRewriterPromptBuilder.buildEvolution(
      character: character(),
      instruction: 'Reflect durable changes.',
    );

    expect(
      prompt,
      contains('Prefer replacing or refining an existing outdated'),
    );
    expect(prompt, contains('Append only when no existing fragment'));
    expect(prompt, contains('smallest exact anchors, not the fewest patches'));
    expect(prompt, contains('every directly conflicting fragment'));
    expect(prompt, contains('obsolete state as current canon'));
    expect(prompt, contains('every supplied writable field'));
    expect(prompt, contains('one operation per affected field'));
    expect(prompt, contains('timeline, scenario, appearance, motivation'));
  });

  test('evolution prompt keeps one-off events in Ledger', () {
    final prompt = CardRewriterPromptBuilder.buildEvolution(
      character: character(),
      instruction: 'Reflect durable changes.',
    );

    expect(prompt, contains('long-term character reference, not an event log'));
    expect(prompt, contains('accepting a drink is a Ledger event'));
    expect(prompt, contains('Do not turn a single event into a permanent'));
  });

  test('evolution prompt treats durable relationship status as card canon', () {
    final prompt = CardRewriterPromptBuilder.buildEvolution(
      character: character(),
      instruction: 'Reflect durable changes.',
    );

    expect(prompt, contains('temporary relationship moods'));
    expect(prompt, contains('engagement forming or ending'));
    expect(prompt, contains('changes the baseline premise'));
    expect(
      prompt,
      isNot(contains('current state of a relationship in Ledger')),
    );
  });

  test(
    'chat-confirmed active contradiction cannot produce an empty proposal',
    () {
      final prompt = CardRewriterPromptBuilder.buildEvolution(
        character: character().copyWith(
          personality: 'Ada is newly engaged to Richard.',
        ),
        instruction: 'Reflect durable changes.',
        accumulatedObservations: const [
          {
            'status': 'active',
            'key': 'relationship.ada.richard.engagement_broken',
            'canonicalClaim': 'The engagement has permanently ended.',
          },
        ],
      );

      expect(prompt, contains('Ada is newly engaged to Richard.'));
      expect(prompt, contains('relationship.ada.richard.engagement_broken'));
      expect(prompt, contains('directly contradicts supplied card text'));
      expect(prompt, contains('regardless of whether the candidate status'));
      expect(prompt, contains('smallest valid patch'));
      expect(prompt, contains('An empty operations list is not valid'));
    },
  );

  test('prompt describes the operation snapshot shape and scope grammar', () {
    final prompt = buildPrompt();
    expect(
      prompt,
      contains('"patches":[{"scopeKey":"...","anchor":"...","value":"..."}]'),
    );
    expect(prompt, contains('"affectedTrackerKeys":[]'));
    expect(prompt, contains('"chatSessionId":null'));
    expect(prompt, contains('- "field" MUST be exactly "description".'));
    expect(prompt, contains('- "patches" MUST be a non-empty list'));
    expect(prompt, contains('npc:<subject>'));
    expect(prompt, contains('relationship:<subject-a>:<subject-b>'));
    expect(prompt, contains('always contains both subjects'));
    expect(prompt, contains('arc:<subject>'));
    expect(prompt, contains('world:<subject>'));
    expect(prompt, contains('scene.<subject>'));
    expect(prompt, contains('EXACTLY ONCE'));
    expect(prompt, isNot(contains('anchorSha256')));
  });

  test(
    'prompt forbids macro expansion and demands literal {{...}} preservation',
    () {
      final prompt = buildPrompt();
      expect(prompt, contains('{{user}}'));
      expect(prompt, contains('{{char}}'));
      expect(prompt, contains('{{description}}'));
      expect(
        prompt,
        contains('NEVER expand, substitute, rename, translate, or delete'),
      );
      expect(prompt, contains('byte-for-byte'));
    },
  );

  test('prompt embeds the canonical snapshot and macros verbatim', () {
    final prompt = buildPrompt();
    expect(prompt, contains(CardCanonicalizer.serialize(character())));
    expect(prompt, contains('A {{char}} who assists {{user}}.'));
    expect(prompt, contains('Set in the study of {{description}}.'));
  });

  test('prompt embeds the user instruction', () {
    final prompt = buildPrompt(
      instruction: 'Fold the backstory near {{user}} references.\nLine two.',
    );
    expect(prompt, contains('# User instruction'));
    expect(
      prompt,
      contains('Fold the backstory near {{user}} references.\nLine two.'),
    );
  });

  test(
    'evolution prompt omits empty writable fields and forbids empty anchors',
    () {
      final prompt = CardRewriterPromptBuilder.buildEvolution(
        character: character().copyWith(description: '', scenario: null),
        instruction: 'Update durable facts.',
      );

      expect(
        prompt,
        contains('Only these non-empty fields are writable: personality.'),
      );
      expect(prompt, contains('Empty fields are omitted and MUST NOT appear'));
      expect(prompt, contains('Empty anchors are forbidden.'));
      expect(prompt, contains('exact owning scopeKey'));
      expect(prompt, contains('knowledge_fact retrieval target'));
      expect(prompt, contains('put those keys in affectedTrackerKeys'));
      expect(prompt, contains('destination in promotionDestination'));
      expect(prompt, isNot(contains('"description":""')));
      expect(prompt, isNot(contains('"scenario":""')));
    },
  );

  test(
    'evolution prompts use Ledger as evidence without copying its event log',
    () {
      final cardPrompt = CardRewriterPromptBuilder.buildEvolution(
        character: character(),
        instruction: 'Update durable facts.',
      );
      final lorePrompt = CardRewriterPromptBuilder.buildLorebookEvolution(
        instruction: 'Update injected setting facts.',
      );

      expect(
        cardPrompt,
        contains('event records are not themselves card content'),
      );
      expect(cardPrompt, contains('Ledger may establish the evidence'));
      expect(lorePrompt, contains('Avoid only card-lorebook duplication'));
      expect(lorePrompt, contains('proposed card operations'));
      expect(lorePrompt, contains('not alternate durable targets'));
      expect(
        lorePrompt,
        contains(
          'Ledger fact is accepted evidence, not a reason to omit an eligible lorebook patch',
        ),
      );
    },
  );
}
