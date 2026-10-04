import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/context_calculator.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/llm/request_tokens.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';

/// The Context tab, the drawer and the Prompt Inspector's request views must
/// agree on how big a prompt is. The breakdown used to count preset blocks with
/// their external injections blanked (the preset-row view of INV-PS5), so the
/// character card, persona and example dialogue — and every `{{char}}` /
/// `{{user}}` — were missing from the total and from the history budget.
void main() {
  PromptPayload payload({
    String description = 'Alice is a tall knight with silver hair.',
    int contextSize = 100000,
    List<ChatMessage>? history,
  }) => PromptPayload(
    character: Character(
      id: 'c1',
      name: 'Alice',
      description: description,
      personality: 'Brave and stubborn.',
      scenario: 'A tavern at the edge of the kingdom.',
      mesExample: '<START>\n{{user}}: Hi\n{{char}}: Hello, traveller.',
    ),
    persona: const Persona(id: 'p', name: 'Bob', prompt: 'A merchant.'),
    preset: const Preset(
      id: 'p1',
      name: 'Prompt',
      blocks: [
        PresetBlock(
          id: 'main',
          name: 'Main',
          role: 'system',
          content: 'You are {{char}}. Reply to {{user}}. {{personality}}',
        ),
        PresetBlock(id: 'char_card', name: 'Char', role: 'system', content: ''),
        PresetBlock(
          id: 'scenario',
          name: 'Scenario',
          role: 'system',
          content: '{{scenario}}',
        ),
        PresetBlock(
          id: 'user_persona',
          name: 'Persona',
          role: 'system',
          content: '',
        ),
        PresetBlock(
          id: 'example_dialogue',
          name: 'Examples',
          role: 'system',
          content: '',
        ),
        PresetBlock(
          id: 'chat_history',
          name: 'History',
          role: 'system',
          content: '',
        ),
        PresetBlock(
          id: 'vars',
          name: 'Vars',
          role: 'system',
          content: '{{setvar::mood::calm}}',
        ),
      ],
    ),
    history:
        history ??
        [
          for (var i = 0; i < 6; i++)
            ChatMessage(
              id: 'm$i',
              role: i.isEven ? 'user' : 'assistant',
              content: 'Message $i — {{char}} looks at {{user}}.',
            ),
        ],
    apiConfig: ApiConfig(
      id: 'api',
      name: 'API',
      contextSize: contextSize,
      maxTokens: 100,
    ),
  );

  test('the total is what the request carries', () {
    final result = buildPrompt(payload());
    final sent = countRequestTokens(buildApiMessages(result.messages));

    expect(result.breakdown.totalTokens, sent);
  });

  test('card fields land on their own rows, the preset row keeps chrome', () {
    final result = buildPrompt(payload());
    final sources = result.breakdown.sourceTokens;

    expect(
      sources['description'],
      estimateTokens('Alice is a tall knight with silver hair.'),
    );
    expect(sources['persona'], greaterThan(0));
    expect(sources['mesExamples'], greaterThan(0));
    // Only the main block's own words, not the injected personality or names.
    expect(
      sources['preset'],
      lessThan(estimateTokens(result.messages[0].content)),
    );
  });

  test('the history budget leaves room for the character card', () {
    final history = [
      for (var i = 0; i < 40; i++)
        ChatMessage(
          id: 'm$i',
          role: i.isEven ? 'user' : 'assistant',
          content: 'x' * 400,
        ),
    ];
    final small = buildPrompt(
      payload(contextSize: 3000, history: history),
    ).breakdown;
    final big = buildPrompt(
      payload(contextSize: 3000, history: history, description: 'y' * 4000),
    ).breakdown;

    expect(big.cutoffIndex, greaterThan(small.cutoffIndex));
    expect(big.totalTokens, lessThanOrEqualTo(3000 - 100));
  });

  test('a vector lorebook count keeps the history window it was added to', () {
    final base = buildPrompt(payload()).breakdown;
    final withVector = TokenBreakdown(
      sourceTokens: base.sourceTokens,
      staticTotal: base.staticTotal,
      historyBudget: base.historyBudget,
      historyTokens: base.historyTokens,
      totalTokens: base.totalTokens,
      cutoffIndex: base.cutoffIndex,
      trimmedHistory: base.trimmedHistory,
      historyAnchorId: 'm2',
      visibleMessageIds: const {'m2', 'm3'},
      remaining: base.remaining,
    ).withVectorLore(50);

    expect(withVector.vectorLoreTokens, 50);
    expect(withVector.sourceTokens['vectorLore'], 50);
    expect(withVector.totalTokens, base.totalTokens + 50);
    expect(withVector.remaining, base.remaining - 50);
    expect(withVector.historyAnchorId, 'm2');
    expect(withVector.visibleMessageIds, {'m2', 'm3'});
  });
}
