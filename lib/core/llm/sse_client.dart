import 'package:dio/dio.dart';

import 'transport/chat_transport.dart';
import 'transport/chat_transport_request.dart';
import 'transport/openai_chat_transport.dart';

typedef SseOnUpdate = ChatTransportOnUpdate;
typedef SseOnComplete = ChatTransportOnComplete;
typedef SseOnError = ChatTransportOnError;

/// Legacy entry point — preserved so existing consumers keep compiling
/// while transports land. New code should use [ChatTransport] via
/// `pickChatTransport(...)` or the Riverpod factory provider.
///
/// Behavior: identical to OpenAI Chat Completions (Bearer + `/v1/chat/completions`).
/// For Anthropic / Gemini / OpenRouter, use the factory.
class SseClient {
  final OpenAiChatTransport _transport;

  SseClient({OpenAiChatTransport? transport})
    : _transport = transport ?? OpenAiChatTransport();

  static String normalizeEndpoint(String endpoint) =>
      OpenAiChatTransport.normalizeEndpoint(endpoint);

  static String buildChatUrl(String endpoint) =>
      OpenAiChatTransport.buildChatUrl(endpoint);

  Future<void> streamChatCompletion({
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required int maxTokens,
    required double temperature,
    required double topP,
    required bool stream,
    CancelToken? cancelToken,
    SseOnUpdate? onUpdate,
    SseOnComplete? onComplete,
    SseOnError? onError,
    bool requestReasoning = false,
    String? reasoningEffort,
    bool omitTemperature = false,
    bool omitTopP = false,
    bool omitReasoning = false,
    bool omitReasoningEffort = false,
    String? sessionId,
    String cacheControlTtl = 'off',
  }) {
    return _transport.stream(
      request: ChatTransportRequest(
        endpoint: endpoint,
        apiKey: apiKey,
        model: model,
        messages: messages,
        maxTokens: maxTokens,
        temperature: temperature,
        topP: topP,
        stream: stream,
        requestReasoning: requestReasoning,
        reasoningEffort: reasoningEffort,
        omitTemperature: omitTemperature,
        omitTopP: omitTopP,
        omitReasoning: omitReasoning,
        omitReasoningEffort: omitReasoningEffort,
        sessionId: sessionId,
        cacheControlTtl: cacheControlTtl,
      ),
      cancelToken: cancelToken,
      onUpdate: onUpdate,
      onComplete: onComplete,
      onError: onError,
    );
  }

  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) {
    return _transport.fetchModels(endpoint: endpoint, apiKey: apiKey);
  }
}
