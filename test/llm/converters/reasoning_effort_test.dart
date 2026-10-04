import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/converters/reasoning_effort.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';

String? _resolve(String protocol, String? effort, {String model = 'gpt-4o'}) =>
    resolveReasoningEffort(protocol: protocol, effort: effort, model: model);

void main() {
  test('the same six steps are offered for every protocol', () {
    expect(reasoningEffortSteps, [
      'auto',
      'min',
      'low',
      'medium',
      'high',
      'max',
    ]);
    for (final protocol in LlmProtocol.all) {
      for (final step in reasoningEffortSteps) {
        expect(isValidReasoningEffort(step), isTrue, reason: '$protocol $step');
      }
    }
  });

  test('auto, null and empty send nothing', () {
    for (final protocol in LlmProtocol.all) {
      expect(_resolve(protocol, 'auto'), isNull, reason: protocol);
      expect(_resolve(protocol, null), isNull, reason: protocol);
      expect(_resolve(protocol, ''), isNull, reason: protocol);
    }
  });

  group('official OpenAI-style protocols', () {
    const protocols = [
      LlmProtocol.openai,
      LlmProtocol.openaiResponses,
      LlmProtocol.openrouter,
    ];

    test('max is capped at high', () {
      for (final protocol in protocols) {
        expect(_resolve(protocol, 'max'), 'high', reason: protocol);
      }
    });

    test('min becomes minimal only on the GPT-5 family', () {
      for (final protocol in protocols) {
        expect(
          _resolve(protocol, 'min', model: 'gpt-5.1'),
          'minimal',
          reason: protocol,
        );
        // Proxy-prefixed names still match.
        expect(
          _resolve(protocol, 'min', model: 'openai/gpt-5-mini'),
          'minimal',
        );
        // Older reasoning models do not accept `minimal`.
        expect(_resolve(protocol, 'min', model: 'o3-mini'), 'low');
        expect(_resolve(protocol, 'min', model: 'gpt-4o'), 'low');
      }
    });

    test('low/medium/high pass through', () {
      for (final protocol in protocols) {
        for (final step in const ['low', 'medium', 'high']) {
          expect(_resolve(protocol, step), step, reason: '$protocol $step');
        }
      }
    });

    test('an unknown step sends nothing rather than a rejected value', () {
      expect(_resolve(LlmProtocol.openai, 'ludicrous'), isNull);
    });
  });

  test('Custom Chat Completion keeps max distinct from high', () {
    expect(_resolve(LlmProtocol.customChatCompletion, 'max'), 'max');
    expect(_resolve(LlmProtocol.customChatCompletion, 'high'), 'high');
  });

  test('Anthropic and Gemini keep the full scale as a budget share', () {
    for (final protocol in const [LlmProtocol.anthropic, LlmProtocol.gemini]) {
      for (final step in const ['min', 'low', 'medium', 'high', 'max']) {
        expect(_resolve(protocol, step), step, reason: '$protocol $step');
      }
    }
  });
}
