import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/llm/prompt_worker_codec.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_mode.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_policy.dart';

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
    effectiveCanonRevisionNumber: 7,
    effectiveCanonRevisionHash: 'revision-hash',
    effectiveCanonCacheIdentity: 'canon-cache-identity',
  );

  test('prompt isolate codec preserves both current-canon layers', () {
    final restored = deserializePayload(serializePayload(payload()));

    expect(restored.studioSessionStateContent, sessionState);
    expect(restored.characterKnowledgeContent, characterState);
    expect(restored.effectiveCanonRevisionNumber, 7);
    expect(restored.effectiveCanonRevisionHash, 'revision-hash');
    expect(restored.effectiveCanonCacheIdentity, 'canon-cache-identity');
  });

  test('prompt isolate codec preserves the ledger game clock', () {
    final source = PromptPayload(
      character: const Character(id: 'character', name: 'Alison'),
      history: const [],
      apiConfig: const ApiConfig(id: 'api'),
      gameTime: '19:45',
      gameDate: '08.11.2027',
      gameDay: '3',
    );

    final restored = deserializePayload(serializePayload(source));

    expect(restored.gameTime, '19:45');
    expect(restored.gameDate, '08.11.2027');
    expect(restored.gameDay, '3');
  });

  test(
    'prompt isolate codec preserves Ledger policy and injection identity',
    () {
      final source = PromptPayload(
        character: const Character(id: 'character', name: 'Alison'),
        history: const [],
        apiConfig: const ApiConfig(id: 'api'),
        ledgerPromptInjectionPolicy: const LedgerPromptInjectionPolicy(
          presetOptIn: true,
          mode: LedgerPromptInjectionMode.gapFiller,
          reverseScanDepth: 17,
        ),
        ledgerInjectionCacheIdentity: 'selected-ledger-v1',
      );

      final restored = deserializePayload(serializePayload(source));

      expect(
        restored.ledgerPromptInjectionPolicy,
        source.ledgerPromptInjectionPolicy,
      );
      expect(restored.ledgerInjectionCacheIdentity, 'selected-ledger-v1');
    },
  );

  test('absent isolate policy decodes as legacy for compatibility', () {
    final json = serializePayload(payload())
      ..remove('ledgerPromptInjectionPolicy')
      ..remove('ledgerInjectionCacheIdentity');

    final restored = deserializePayload(json);

    expect(
      restored.ledgerPromptInjectionPolicy.effectiveMode,
      LedgerPromptInjectionMode.legacy,
    );
    expect(restored.ledgerInjectionCacheIdentity, isEmpty);
  });

  test('disabled payload isolate codec cannot resurrect raw Ledger fields', () {
    final json = serializePayload(payload());
    json['arcContent'] = '<arc_state>raw</arc_state>';
    json['ledgerPromptInjectionPolicy'] = const LedgerPromptInjectionPolicy(
      presetOptIn: false,
      mode: LedgerPromptInjectionMode.disabled,
    ).toJson();

    final restored = deserializePayload(json);

    expect(restored.arcContent, isNull);
    expect(restored.studioSessionStateContent, isNull);
    expect(restored.characterKnowledgeContent, isNull);
  });

  test('Studio source-window payload preserves both current-canon layers', () {
    final sourcePayload = PromptPayload(
      character: const Character(id: 'character', name: 'Alison'),
      history: const [],
      apiConfig: const ApiConfig(id: 'api'),
      studioSessionStateContent: sessionState,
      characterKnowledgeContent: characterState,
      effectiveCanonRevisionNumber: 7,
      effectiveCanonRevisionHash: 'revision-hash',
      effectiveCanonCacheIdentity: 'canon-cache-identity',
      sourceWindowVisibleMessageIds: const {'message'},
    );

    expect(sourcePayload.studioSessionStateContent, sessionState);
    expect(sourcePayload.characterKnowledgeContent, characterState);
    expect(sourcePayload.effectiveCanonCacheIdentity, 'canon-cache-identity');
    expect(sourcePayload.sourceWindowVisibleMessageIds, const {'message'});
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
