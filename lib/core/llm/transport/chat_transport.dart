import 'package:dio/dio.dart';

import 'chat_transport_request.dart';

/// Streaming text delta. `reasoningDelta` is non-null only for models that
/// emit a separate thinking stream (Claude extended thinking, Gemini thought
/// parts, OpenAI/OpenRouter reasoning models).
typedef ChatTransportOnUpdate = void Function(String delta, String? reasoningDelta);

/// Final assistant message after streaming finishes (or after a one-shot
/// non-streaming call). `rawResponseJson` is the raw provider payload
/// (or an aggregated synthetic one for streamed responses) — used by the
/// UI raw-view tab.
typedef ChatTransportOnComplete = void Function(
  String text,
  String? reasoning, {
  String? rawResponseJson,
});

typedef ChatTransportOnError = void Function(Object error);

/// Abstraction over provider-specific HTTP/SSE chat completion clients.
/// One implementation per [LlmProtocol].
///
/// Implementations are responsible for:
/// - URL construction (or hardcoding, in OpenRouter's case)
/// - Auth header shape (`Bearer` / `x-api-key` / `?key=`)
/// - Request body conversion (OpenAI / Claude / Gemini / OR shape)
/// - SSE chunk parsing → unified delta callbacks
/// - Raw response JSON aggregation for the UI raw view
///
/// Callers should not branch on provider — they go through the factory in
/// `transport_factory.dart`.
abstract class ChatTransport {
  /// Streams (or one-shot fetches) a chat completion. `onUpdate` fires per
  /// chunk while streaming; `onComplete` fires once at the end with the full
  /// aggregated text. `onError` fires on transport-level errors. Cancellation
  /// is via [cancelToken].
  ///
  /// If the provider returns HTTP 408 (Request Timeout — common on mobile
  /// networks where the upload is slow), the transport retries up to
  /// [maxRetries] times before surfacing the error.
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  });

  /// Lists available models for the UI's "fetch models" affordance. Empty
  /// list on failure (transports should not throw here).
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  });
}
