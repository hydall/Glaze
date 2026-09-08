import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/fallback_prompt_builder.dart';
import 'package:glaze_flutter/core/llm/prompt/prompt_payload.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

void main() {
  test('fallback prompt retains and budgets reasoning history', () {
    final result = buildFallbackPrompt(
      const PromptPayload(
        character: Character(id: 'c1', name: 'Character'),
        history: [
          ChatMessage(
            id: 'm1',
            role: 'user',
            content:
                'This deliberately long older user turn must fall outside the '
                'remaining prompt budget once recent reasoning is counted.',
          ),
          ChatMessage(
            id: 'm2',
            role: 'assistant',
            content: 'recent answer',
            reasoning: 'one two three four five six seven eight nine ten',
          ),
        ],
        apiConfig: ApiConfig(
          id: 'api',
          contextSize: 40,
          maxTokens: 5,
          reasoningHistoryCount: -1,
        ),
      ),
    );

    expect(result.messages, hasLength(2));
    expect(result.messages.first.role, 'system');
    expect(result.messages.last.sourceMessageId, 'm2');
    expect(result.messages.last.reasoningContent, contains('one two three'));
    expect(result.breakdown.cutoffIndex, 1);
    expect(
      result.breakdown.historyTokens,
      greaterThan(result.breakdown.trimmedHistory.single.content.length ~/ 4),
    );
  });
}
