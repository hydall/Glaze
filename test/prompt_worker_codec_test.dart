import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/llm/prompt_worker_codec.dart';
import 'package:glaze_flutter/core/llm/studio/studio_stream_interceptor.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/preset.dart';

void main() {
  const sessionState =
      '<studio_session_state>trust: full</studio_session_state>';
  const characterState =
      '<current_character_state>Alison trusts the user.</current_character_state>';

  PromptPayload payload() => const PromptPayload(
    character: Character(id: 'character', name: 'Alison'),
    history: [],
    apiConfig: ApiConfig(id: 'api'),
    studioSessionStateContent: sessionState,
    characterKnowledgeContent: characterState,
  );

  test('prompt isolate codec preserves both current-canon layers', () {
    final restored = deserializePayload(serializePayload(payload()));

    expect(restored.studioSessionStateContent, sessionState);
    expect(restored.characterKnowledgeContent, characterState);
  });

  test('Studio source-window clone preserves both current-canon layers', () {
    final cloned = StudioStreamInterceptor.payloadWithSourceWindow(
      payload(),
      const {'message'},
    );

    expect(cloned.studioSessionStateContent, sessionState);
    expect(cloned.characterKnowledgeContent, characterState);
  });

  test('prompt orders canon above memory and card', () {
    final result = buildPrompt(
      PromptPayload(
        character: const Character(id: 'character', name: 'Alison'),
        apiConfig: const ApiConfig(id: 'api'),
        history: const [ChatMessage(id: 'user', role: 'user', content: 'Hi')],
        preset: const Preset(
          id: 'preset',
          name: 'Preset',
          blocks: [
            PresetBlock(
              id: 'char_card',
              name: 'Card',
              role: 'system',
              content: '{{description}}',
            ),
            PresetBlock(
              id: 'chat_history',
              name: 'History',
              role: 'system',
              content: '',
            ),
          ],
        ),
        memoryContent: 'Memory context:\nAlison once trusted the user.',
        memoryInjectionTarget: 'hard_block',
        characterKnowledgeContent: characterState,
        studioSessionStateContent: sessionState,
      ),
    );
    final ids = result.messages.map((message) => message.blockId).toList();

    expect(ids.indexOf('char_card'), lessThan(ids.indexOf('memory')));
    expect(
      ids.indexOf('memory'),
      lessThan(ids.indexOf('current_character_state')),
    );
    expect(
      ids.indexOf('current_character_state'),
      lessThan(ids.indexOf('studio_session_state')),
    );
  });
}
