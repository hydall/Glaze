import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../converters/openrouter_messages.dart';
import '../converters/cache_breakpoint_marker.dart';
import 'chat_transport.dart';
import 'chat_transport_request.dart';
import 'openai_chat_transport.dart';

/// OpenRouter transport. Hardcodes the OR base URL and layers OR-specific
/// behaviour on top of the OpenAI Chat Completions wire format:
/// - URL: always `https://openrouter.ai/api/v1/chat/completions`. Any
///   endpoint passed in [ChatTransportRequest] is ignored.
/// - Required headers: `HTTP-Referer` and `X-Title` for OR analytics
///   attribution.
/// - For Claude-via-OR models: applies `cachingAtDepthForOpenRouterClaude`
///   and `cachingSystemPromptForOpenRouter` when [ChatTransportRequest.cacheControlTtl]
///   is enabled. Other models leave messages untouched.
///
/// Streaming/parsing reuses [OpenAiChatTransport] verbatim — OR's SSE chunks
/// are OpenAI-compatible.
class OpenRouterChatTransport implements ChatTransport {
  static const String baseUrl = 'https://openrouter.ai/api/v1';
  static const String referer = 'https://github.com/hydall/Glaze';
  static const String title = 'Glaze';

  /// Cache depth used when the user enables `cacheControlTtl`.
  static const int _cacheDepth = 2;

  final OpenAiChatTransport _inner;

  OpenRouterChatTransport({Dio? dio, OpenAiChatTransport? inner})
    : _inner =
          inner ??
          OpenAiChatTransport(
            dio: dio,
            extraHeaders: const {'HTTP-Referer': referer, 'X-Title': title},
          );

  /// Pure: maps a neutral request to the OR-shaped request that
  /// [OpenAiChatTransport] will execute (URL forced, headers padded,
  /// cache_control applied where applicable). Exposed for unit testing.
  static ChatTransportRequest buildRouterRequest(ChatTransportRequest input) {
    final ttl = _resolveTtl(input.cacheControlTtl);

    var messages = input.messages;
    if (ttl != null && isClaudeModelOnOpenRouter(input.model)) {
      messages = cachingSystemPromptForOpenRouter(messages, ttl: ttl);
      if (input.cacheBreakpointMode == cacheBreakpointModeStablePrefix) {
        final previousMessages = input.previousMessages == null
            ? null
            : cachingSystemPromptForOpenRouter(
                input.previousMessages!,
                ttl: ttl,
              );
        messages = markStablePrefixCacheControl(
          messages,
          previousMessages,
          ttl: ttl,
        );
      } else {
        messages = cachingAtDepthForOpenRouterClaude(
          messages,
          _cacheDepth,
          ttl,
        );
      }
    } else if (ttl == null && isClaudeModelOnOpenRouter(input.model)) {
      debugPrint(
        '[openrouter] Claude model "${input.model}" — cacheControlTtl is off; '
        'cache breakpoints not applied',
      );
    }

    // Endpoint is hardcoded — OR's base URL is the only legal one. We
    // overwrite whatever the caller passed (Phase 1 UI already hides the
    // endpoint field for OR, but this is defence-in-depth).
    return ChatTransportRequest(
      endpoint: baseUrl,
      apiKey: input.apiKey,
      model: input.model,
      messages: messages,
      maxTokens: input.maxTokens,
      temperature: input.temperature,
      topP: input.topP,
      topK: input.topK,
      frequencyPenalty: input.frequencyPenalty,
      presencePenalty: input.presencePenalty,
      stream: input.stream,
      requestReasoning: input.requestReasoning,
      reasoningEffort: input.reasoningEffort,
      omitTemperature: input.omitTemperature,
      omitTopP: input.omitTopP,
      omitTopK: input.omitTopK,
      omitFrequencyPenalty: input.omitFrequencyPenalty,
      omitPresencePenalty: input.omitPresencePenalty,
      omitReasoning: input.omitReasoning,
      omitReasoningEffort: input.omitReasoningEffort,
      showNativeReasoning: input.showNativeReasoning,
      receiveTimeoutMs: input.receiveTimeoutMs,
      sessionId: input.sessionId,
      previousMessages: input.previousMessages,
      sessionIdMode: input.sessionIdMode,
      // OR doesn't take cache_control on the body level the same way the
      // OpenAI builder expects — strip it so the body doesn't grow a stray
      // top-level `cache_control` field. Cache markers are now on the
      // message parts via the helpers above.
      cacheControlTtl: 'off',
      extraRequestParameters: input.extraRequestParameters,
    );
  }

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) {
    final routed = buildRouterRequest(request);
    return _inner.stream(
      request: routed,
      cancelToken: cancelToken,
      onUpdate: onUpdate,
      onComplete: onComplete,
      onError: onError,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) {
    // OR's models list lives at the hardcoded base regardless of what the
    // caller passes.
    return _inner.fetchModels(endpoint: baseUrl, apiKey: apiKey);
  }

  /// Adapter wrapping Dio's [Interceptor] is overkill for two static
  /// headers — instead the OR transport uses its own [Dio] with default
  /// headers. Exposed for tests that want to verify presence.
  static Map<String, String> get extraHeaders => const {
    'HTTP-Referer': referer,
    'X-Title': title,
  };

  static String? _resolveTtl(String cacheControlTtl) {
    switch (cacheControlTtl) {
      case '5min':
        return '5m';
      case '1h':
        return '1h';
      default:
        return null;
    }
  }
}
