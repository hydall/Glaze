import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/prompt/effective_canon_prompt_formatter.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_mode.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_policy.dart';
import 'package:glaze_flutter/core/models/tracker.dart';

void main() {
  const ledgerValue = 'UNIQUE_LEDGER_CHECKPOINT';
  final projection = EffectiveCanonPromptProjection(
    facts: const [],
    trackers: const [
      Tracker(
        sessionId: 's',
        name: 'scene.immediate_thread',
        value: ledgerValue,
        scope: 'ledger',
        provenance: 'messageId=evidence',
      ),
    ],
    unblockedTransitionClaims: const [],
    revisionNumber: 1,
    revisionHash: 'revision',
    cacheIdentity: 'canon',
  );

  PromptPayload payload({
    required List<ChatMessage> history,
    required int contextSize,
    bool freshnessProven = true,
  }) => PromptPayload(
    character: const Character(id: 'c', name: 'Character'),
    history: history,
    sessionId: 's',
    apiConfig: ApiConfig(id: 'api', contextSize: contextSize, maxTokens: 10),
    effectiveCanonProjection: projection,
    ledgerPromptInjectionPolicy: const LedgerPromptInjectionPolicy(
      presetOptIn: true,
      mode: LedgerPromptInjectionMode.gapFiller,
    ),
    ledgerProjectionFreshnessProvenCurrent: freshnessProven,
  );

  String promptText(PromptResult result) =>
      result.messages.map((message) => message.content).join('\n');

  test('visible evidence suppresses Ledger against frozen final IDs', () {
    final result = buildPrompt(
      payload(
        contextSize: 1000,
        history: const [
          ChatMessage(id: 'evidence', role: 'user', content: 'Visible event'),
        ],
      ),
    );

    expect(result.breakdown.visibleMessageIds, contains('evidence'));
    expect(promptText(result), isNot(contains(ledgerValue)));
  });

  test('evidence outside token trim does not suppress Ledger', () {
    final result = buildPrompt(
      payload(
        contextSize: 80,
        history: const [
          ChatMessage(
            id: 'evidence',
            role: 'user',
            content: 'Old establishing event that should leave the window.',
          ),
          ChatMessage(
            id: 'recent',
            role: 'assistant',
            content:
                'Recent response with enough repeated context words to consume '
                'the small remaining history budget completely and stay visible.',
          ),
        ],
      ),
    );

    expect(result.breakdown.visibleMessageIds, isNot(contains('evidence')));
    expect(promptText(result), contains(ledgerValue));
  });

  test('unknown freshness stays byte-equivalent to legacy projection', () {
    final result = buildPrompt(
      payload(
        contextSize: 1000,
        freshnessProven: false,
        history: const [
          ChatMessage(id: 'evidence', role: 'user', content: 'Visible event'),
        ],
      ),
    );

    expect(promptText(result), contains(ledgerValue));
  });

  test('fallback breakdown includes Ledger static channel token cost', () {
    final result = buildPrompt(
      payload(contextSize: 1000, freshnessProven: false, history: const []),
    );

    expect(promptText(result), contains(ledgerValue));
    expect(result.breakdown.staticTotal, greaterThan(6));
    expect(result.breakdown.totalTokens, result.breakdown.staticTotal);
  });
}
