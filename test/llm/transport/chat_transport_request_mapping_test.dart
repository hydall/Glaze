import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';

void main() {
  const messages = <Map<String, dynamic>>[
    {'role': 'user', 'content': 'Hello'},
  ];
  const extraParameters = <ExtraRequestParameter>[
    ExtraRequestParameter(key: 'seed', value: '42'),
  ];
  const config = ApiConfig(
    id: 'api-id',
    endpoint: 'https://example.com/v1',
    apiKey: 'secret',
    model: 'configured-model',
    maxTokens: 1234,
    temperature: 0.12,
    topP: 0.34,
    topK: 56,
    frequencyPenalty: 0.78,
    presencePenalty: 0.9,
    stream: false,
    reasoningEffort: 'high',
    requestReasoning: true,
    useResponsesApi: true,
    showNativeReasoning: false,
    omitTemperature: true,
    omitTopP: true,
    omitTopK: true,
    omitFrequencyPenalty: true,
    omitPresencePenalty: true,
    omitReasoning: true,
    omitReasoningEffort: true,
    cacheControlTtl: '1h',
    cacheBreakpointMode: 'stable_prefix',
    sessionIdMode: 'always',
    extraRequestParameters: extraParameters,
  );

  test('forwards every ApiConfig transport option', () {
    final request = ChatTransportRequest.fromApiConfig(
      config,
      messages: messages,
    );

    final cases = <({String name, Object? actual, Object? expected})>[
      (name: 'endpoint', actual: request.endpoint, expected: config.endpoint),
      (name: 'apiKey', actual: request.apiKey, expected: config.apiKey),
      (name: 'model', actual: request.model, expected: config.model),
      (
        name: 'maxTokens',
        actual: request.maxTokens,
        expected: config.maxTokens,
      ),
      (
        name: 'temperature',
        actual: request.temperature,
        expected: config.temperature,
      ),
      (name: 'topP', actual: request.topP, expected: config.topP),
      (name: 'topK', actual: request.topK, expected: config.topK),
      (
        name: 'frequencyPenalty',
        actual: request.frequencyPenalty,
        expected: config.frequencyPenalty,
      ),
      (
        name: 'presencePenalty',
        actual: request.presencePenalty,
        expected: config.presencePenalty,
      ),
      (name: 'stream', actual: request.stream, expected: config.stream),
      (
        name: 'requestReasoning',
        actual: request.requestReasoning,
        expected: config.requestReasoning,
      ),
      (
        name: 'useResponsesApi',
        actual: request.useResponsesApi,
        expected: config.useResponsesApi,
      ),
      (
        name: 'reasoningEffort',
        actual: request.reasoningEffort,
        expected: config.reasoningEffort,
      ),
      (
        name: 'omitTemperature',
        actual: request.omitTemperature,
        expected: config.omitTemperature,
      ),
      (name: 'omitTopP', actual: request.omitTopP, expected: config.omitTopP),
      (name: 'omitTopK', actual: request.omitTopK, expected: config.omitTopK),
      (
        name: 'omitFrequencyPenalty',
        actual: request.omitFrequencyPenalty,
        expected: config.omitFrequencyPenalty,
      ),
      (
        name: 'omitPresencePenalty',
        actual: request.omitPresencePenalty,
        expected: config.omitPresencePenalty,
      ),
      (
        name: 'omitReasoning',
        actual: request.omitReasoning,
        expected: config.omitReasoning,
      ),
      (
        name: 'omitReasoningEffort',
        actual: request.omitReasoningEffort,
        expected: config.omitReasoningEffort,
      ),
      (
        name: 'showNativeReasoning',
        actual: request.showNativeReasoning,
        expected: config.showNativeReasoning,
      ),
      (
        name: 'cacheControlTtl',
        actual: request.cacheControlTtl,
        expected: config.cacheControlTtl,
      ),
      (
        name: 'cacheBreakpointMode',
        actual: request.cacheBreakpointMode,
        expected: config.cacheBreakpointMode,
      ),
      (
        name: 'sessionIdMode',
        actual: request.sessionIdMode,
        expected: config.sessionIdMode,
      ),
      (
        name: 'extraRequestParameters',
        actual: request.extraRequestParameters,
        expected: config.extraRequestParameters,
      ),
    ];

    expect(request.messages, same(messages));
    for (final testCase in cases) {
      expect(
        testCase.actual,
        testCase.expected,
        reason: '${testCase.name} was not forwarded',
      );
    }
  });

  test('applies per-call request data and overrides', () {
    const previousMessages = <Map<String, dynamic>>[
      {'role': 'assistant', 'content': 'Earlier'},
    ];
    const tools = <Map<String, dynamic>>[
      {'type': 'function'},
    ];

    final request = ChatTransportRequest.fromApiConfig(
      config,
      messages: messages,
      model: 'override-model',
      stream: true,
      receiveTimeoutMs: 9876,
      sessionId: 'session-id',
      previousMessages: previousMessages,
      tools: tools,
      toolChoice: 'required',
    );

    expect(request.model, 'override-model');
    expect(request.stream, isTrue);
    expect(request.receiveTimeoutMs, 9876);
    expect(request.sessionId, 'session-id');
    expect(request.previousMessages, same(previousMessages));
    expect(request.tools, same(tools));
    expect(request.toolChoice, 'required');
  });
}
