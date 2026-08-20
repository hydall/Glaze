import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/generation_context_inputs.dart';
import 'package:glaze_flutter/core/llm/prompt/effective_canon_prompt_formatter.dart';
import 'package:glaze_flutter/core/llm/prompt/prompt_payload.dart';
import 'package:glaze_flutter/core/llm/prompt_inputs.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_mode.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_policy.dart';
import 'package:glaze_flutter/core/models/tracker.dart';

void main() {
  const disabled = LedgerPromptInjectionPolicy(
    presetOptIn: false,
    mode: LedgerPromptInjectionMode.disabled,
  );

  test('disabled policy cannot resurrect raw projected fields', () {
    final payload = PromptPayload.fromGenerationContext(
      GenerationContextInputs(
        character: const Character(id: 'c', name: 'Character'),
        history: const [],
        apiConfig: const ApiConfig(id: 'api'),
        ledgerPromptInjectionPolicy: disabled,
        arcContent: '<arc_state>raw arc</arc_state>',
        studioSessionStateContent:
            '<studio_session_state>raw state</studio_session_state>',
        characterKnowledgeContent:
            '<current_character_state>raw fact</current_character_state>',
      ),
      preset: null,
    );

    expect(payload.arcContent, isNull);
    expect(payload.studioSessionStateContent, isNull);
    expect(payload.characterKnowledgeContent, isNull);
  });

  test('saved Studio payload honors the frozen disabled turn policy', () {
    final payload = PromptPayload.fromGenerationContext(
      GenerationContextInputs(
        character: const Character(id: 'c', name: 'Character'),
        history: const [],
        apiConfig: const ApiConfig(id: 'api'),
        // Simulates mutable collection-time state disagreeing with the turn
        // snapshot passed by StreamGenerationService.
        ledgerPromptInjectionPolicy: const LedgerPromptInjectionPolicy(
          presetOptIn: true,
          mode: LedgerPromptInjectionMode.legacy,
        ),
        arcContent: '<arc_state>raw arc</arc_state>',
        studioSessionStateContent:
            '<studio_session_state>raw state</studio_session_state>',
        characterKnowledgeContent:
            '<current_character_state>raw fact</current_character_state>',
      ),
      preset: null,
      ledgerPromptInjectionPolicy: disabled,
      consumerPath: 'studio-saved',
    );

    expect(payload.ledgerPromptInjectionPolicy, disabled);
    expect(payload.arcContent, isNull);
    expect(payload.studioSessionStateContent, isNull);
    expect(payload.characterKnowledgeContent, isNull);
  });

  test('classic disabled policy suppresses an effective canon projection', () {
    final projection = EffectiveCanonPromptProjection(
      facts: const [],
      trackers: const [
        Tracker(
          sessionId: 's',
          name: 'world:weather',
          value: 'rain',
          scope: 'ledger',
        ),
      ],
      unblockedTransitionClaims: const ['The storm has ended.'],
      revisionNumber: 1,
      revisionHash: 'revision',
      cacheIdentity: 'canon',
    );
    final payload = PromptPayload.fromGenerationContext(
      GenerationContextInputs(
        character: const Character(id: 'c', name: 'Character'),
        history: const [],
        sessionId: 's',
        apiConfig: const ApiConfig(id: 'api'),
        effectiveCanonProjection: projection,
      ),
      preset: null,
      ledgerPromptInjectionPolicy: disabled,
    );

    expect(payload.studioSessionStateContent, isNull);
    expect(payload.characterKnowledgeContent, isNull);
    expect(payload.arcContent, isNull);
  });

  test('raw-input codec defaults absent policy to legacy', () {
    final source = PromptInputs(
      character: const Character(id: 'c', name: 'Character'),
      history: const [],
      apiConfig: const ApiConfig(id: 'api'),
      ledgerPromptInjectionPolicy: disabled,
      ledgerInjectionCacheIdentity: 'identity',
    );
    final roundTrip = PromptInputs.fromJson(source.toJson());
    expect(roundTrip.ledgerPromptInjectionPolicy, disabled);
    expect(roundTrip.ledgerInjectionCacheIdentity, 'identity');

    final legacyJson = source.toJson()
      ..remove('ledgerPromptInjectionPolicy')
      ..remove('ledgerInjectionCacheIdentity');
    final legacy = PromptInputs.fromJson(legacyJson);
    expect(
      legacy.ledgerPromptInjectionPolicy.effectiveMode,
      LedgerPromptInjectionMode.legacy,
    );
  });
}
