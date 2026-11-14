import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/anthropic_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/gemini_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/openai_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/openai_responses_transport.dart';

/// The omit* flags are the only switch for sampling parameters. A parameter
/// must never disappear because of the value the user picked — `temperature: 0`
/// and `top_p: 1` are legal settings, and dropping them silently turned the
/// sliders into no-ops with no trace in the prompt inspector.
ChatTransportRequest _req({
  String model = 'test-model',
  double temperature = 0.7,
  double topP = 0.9,
  int topK = 0,
  double frequencyPenalty = 0,
  double presencePenalty = 0,
  bool omitTemperature = false,
  bool omitTopP = false,
  bool omitTopK = false,
  bool omitFrequencyPenalty = false,
  bool omitPresencePenalty = false,
  bool requestReasoning = false,
  bool omitReasoning = false,
  bool omitReasoningEffort = false,
  bool? showNativeReasoning,
  String? reasoningEffort,
}) => ChatTransportRequest(
  endpoint: 'https://example.test',
  apiKey: 'key',
  model: model,
  messages: const [
    {'role': 'user', 'content': 'hi'},
  ],
  maxTokens: 1000,
  temperature: temperature,
  topP: topP,
  topK: topK,
  frequencyPenalty: frequencyPenalty,
  presencePenalty: presencePenalty,
  omitTemperature: omitTemperature,
  omitTopP: omitTopP,
  omitTopK: omitTopK,
  omitFrequencyPenalty: omitFrequencyPenalty,
  omitPresencePenalty: omitPresencePenalty,
  requestReasoning: requestReasoning,
  omitReasoning: omitReasoning,
  omitReasoningEffort: omitReasoningEffort,
  showNativeReasoning: showNativeReasoning,
  reasoningEffort: reasoningEffort,
);

Map<String, dynamic> _geminiConfig(ChatTransportRequest r) =>
    GeminiChatTransport.buildRequest(r).body['generationConfig']
        as Map<String, dynamic>;

void main() {
  group('edge values survive to the wire', () {
    test('OpenAI sends temperature 0 and top_p 1', () {
      final body = OpenAiChatTransport.buildBody(
        _req(temperature: 0, topP: 1),
      );

      expect(body, containsPair('temperature', 0.0));
      expect(body, containsPair('top_p', 1.0));
    });

    test('OpenAI sends penalties at their neutral value', () {
      final body = OpenAiChatTransport.buildBody(_req());

      expect(body, containsPair('frequency_penalty', 0.0));
      expect(body, containsPair('presence_penalty', 0.0));
    });

    test('Anthropic sends temperature 0 and top_p 1', () {
      final body = AnthropicChatTransport.buildRequest(
        _req(model: 'claude-3-5-sonnet', temperature: 0, topP: 1),
      ).body;

      expect(body, containsPair('temperature', 0.0));
      expect(body, containsPair('top_p', 1.0));
    });

    test('Gemini sends temperature 0 and topP 1', () {
      final config = _geminiConfig(
        _req(model: 'gemini-2.5-flash', temperature: 0, topP: 1),
      );

      expect(config, containsPair('temperature', 0.0));
      expect(config, containsPair('topP', 1.0));
    });

    test('Responses API carries sampling like Chat Completions', () {
      final body = OpenAiResponsesTransport.buildBody(
        _req(temperature: 0, topP: 1),
      );

      expect(body, containsPair('temperature', 0.0));
      expect(body, containsPair('top_p', 1.0));
    });
  });

  group('omit flags drop the parameter', () {
    test('OpenAI', () {
      final body = OpenAiChatTransport.buildBody(
        _req(
          frequencyPenalty: 0.5,
          presencePenalty: 0.5,
          omitTemperature: true,
          omitTopP: true,
          omitFrequencyPenalty: true,
          omitPresencePenalty: true,
        ),
      );

      expect(body, isNot(contains('temperature')));
      expect(body, isNot(contains('top_p')));
      expect(body, isNot(contains('frequency_penalty')));
      expect(body, isNot(contains('presence_penalty')));
    });

    test('Anthropic', () {
      final body = AnthropicChatTransport.buildRequest(
        _req(
          model: 'claude-3-5-sonnet',
          omitTemperature: true,
          omitTopP: true,
        ),
      ).body;

      expect(body, isNot(contains('temperature')));
      expect(body, isNot(contains('top_p')));
    });

    test('Gemini', () {
      final config = _geminiConfig(
        _req(model: 'gemini-2.5-flash', omitTemperature: true, omitTopP: true),
      );

      expect(config, isNot(contains('temperature')));
      expect(config, isNot(contains('topP')));
    });

    test('Responses API', () {
      final body = OpenAiResponsesTransport.buildBody(
        _req(omitTemperature: true, omitTopP: true),
      );

      expect(body, isNot(contains('temperature')));
      expect(body, isNot(contains('top_p')));
    });
  });

  group('top_k keeps 0 as "not set"', () {
    test('OpenAI omits top_k at 0 and sends it above 0', () {
      expect(OpenAiChatTransport.buildBody(_req()), isNot(contains('top_k')));
      expect(
        OpenAiChatTransport.buildBody(_req(topK: 40)),
        containsPair('top_k', 40),
      );
    });

    test('Gemini omits topK at 0', () {
      expect(
        _geminiConfig(_req(model: 'gemini-2.5-flash')),
        isNot(contains('topK')),
      );
    });
  });

  group('Responses API reasoning', () {
    test('keeps the effort when the summary is hidden', () {
      final body = OpenAiResponsesTransport.buildBody(
        _req(
          model: 'gpt-5.1',
          requestReasoning: true,
          reasoningEffort: 'high',
          showNativeReasoning: false,
        ),
      );

      final reasoning = body['reasoning'] as Map<String, dynamic>;
      expect(reasoning, containsPair('effort', 'high'));
      expect(
        reasoning,
        isNot(contains('summary')),
        reason: 'hiding native reasoning only suppresses the summary',
      );
    });

    test('asks for a summary when reasoning is shown', () {
      final body = OpenAiResponsesTransport.buildBody(
        _req(
          model: 'gpt-5.1',
          requestReasoning: true,
          reasoningEffort: 'medium',
          showNativeReasoning: true,
        ),
      );

      expect(body['reasoning'], containsPair('summary', 'auto'));
      expect(body['reasoning'], containsPair('effort', 'medium'));
    });

    test('sends no reasoning block when it is not requested', () {
      final body = OpenAiResponsesTransport.buildBody(
        _req(requestReasoning: false, reasoningEffort: 'high'),
      );

      expect(body, isNot(contains('reasoning')));
    });

    test('omitReasoningEffort keeps the summary but drops the effort', () {
      final body = OpenAiResponsesTransport.buildBody(
        _req(
          requestReasoning: true,
          reasoningEffort: 'high',
          omitReasoningEffort: true,
        ),
      );

      expect(body['reasoning'], containsPair('summary', 'auto'));
      expect(body['reasoning'], isNot(contains('effort')));
    });
  });

  group('reasoning effort stays protocol-normalized', () {
    test("official OpenAI caps 'max' at 'high'", () {
      final body = OpenAiChatTransport.buildBody(
        _req(requestReasoning: true, reasoningEffort: 'max'),
        protocol: LlmProtocol.openai,
      );

      expect(body, containsPair('reasoning_effort', 'high'));
    });

    test("a custom endpoint keeps 'max'", () {
      final body = OpenAiChatTransport.buildBody(
        _req(requestReasoning: true, reasoningEffort: 'max'),
        protocol: LlmProtocol.customChatCompletion,
      );

      expect(body, containsPair('reasoning_effort', 'max'));
    });
  });
}
