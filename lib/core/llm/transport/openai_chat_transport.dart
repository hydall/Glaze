import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../utils/error_format.dart';
import '../converters/reasoning_effort.dart';
import 'chat_transport.dart';
import 'chat_transport_request.dart';
import 'endpoint_normalizer.dart';
import 'endpoint_resolution_cache.dart';
import 'extra_request_parameters.dart';
import 'llm_protocol.dart';

/// OpenAI Chat Completions transport. Also handles any OpenAI-compatible
/// custom endpoint (LM Studio, Koboldcpp, vLLM, OpenRouter-as-custom, etc.).
///
/// This is the exact behavior the legacy `SseClient` had — the class is the
/// canonical home for that logic; `SseClient` is now a thin compatibility
/// shim that delegates here.
class OpenAiChatTransport implements ChatTransport {
  final Dio _dio;
  final String _protocol;

  /// Number of automatic retries on HTTP 408 (Request Timeout) — common on
  /// mobile networks where the upload is too slow for the provider.
  static const int _maxRetries = 1;

  /// Extra headers merged into every HTTP request. Used by
  /// `OpenRouterChatTransport` to inject `HTTP-Referer` and `X-Title`.
  final Map<String, String> _extraHeaders;

  OpenAiChatTransport({
    Dio? dio,
    Map<String, String>? extraHeaders,
    this._protocol = LlmProtocol.openai,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 30),
               sendTimeout: const Duration(seconds: 60),
               receiveTimeout: const Duration(seconds: 120),
             ),
           ),
       _extraHeaders = extraHeaders ?? const {};

  static const String _chatRoute = '/chat/completions';
  static const String _modelsRoute = '/models';

  /// HTTP statuses that mean "wrong URL, not wrong request" — the endpoint is
  /// retried against the next candidate instead of failing the generation.
  static const Set<int> _routeMismatchStatuses = {404, 405};

  static String normalizeEndpoint(String endpoint) =>
      EndpointNormalizer.baseUrl(endpoint);

  static String buildChatUrl(String endpoint) =>
      EndpointNormalizer.chatCompletionsUrl(endpoint);

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    if (request.apiKey.isEmpty) {
      onError?.call(Exception('API key is empty'));
      return;
    }
    final urls = EndpointResolutionCache.order(
      request.endpoint,
      _chatRoute,
      EndpointNormalizer.chatCompletionsCandidates(request.endpoint),
    );
    if (urls.isEmpty) {
      onError?.call(Exception('Endpoint is empty or not a valid URL'));
      return;
    }

    final Map<String, dynamic> body;
    try {
      body = buildBody(request, protocol: _protocol);
    } catch (e) {
      onError?.call(e);
      return;
    }

    // The first failure is the one worth reporting: later candidates exist
    // only to rescue a mistyped base path, and their errors describe a URL
    // the user never entered.
    DioException? firstError;

    for (var i = 0; i < urls.length; i++) {
      final url = urls[i];
      try {
        await _send(
          url: url,
          request: request,
          body: body,
          cancelToken: cancelToken,
          onUpdate: onUpdate,
          onComplete: onComplete,
        );
        EndpointResolutionCache.record(request.endpoint, _chatRoute, url);
        return;
      } on DioException catch (e) {
        final reportable = firstError ?? e;
        firstError = reportable;
        final canFallBack =
            i < urls.length - 1 &&
            _routeMismatchStatuses.contains(e.response?.statusCode) &&
            cancelToken?.isCancelled != true;
        if (canFallBack) {
          debugPrint(
            '[OpenAI] ${e.response?.statusCode} on $url — '
            'trying ${urls[i + 1]}',
          );
          continue;
        }
        onError?.call(await decodeStreamingError(reportable));
        return;
      } catch (e) {
        onError?.call(e);
        return;
      }
    }
  }

  /// One POST against [url], with the 408 retry that slow mobile uploads need.
  Future<void> _send({
    required String url,
    required ChatTransportRequest request,
    required Map<String, dynamic> body,
    required CancelToken? cancelToken,
    required ChatTransportOnUpdate? onUpdate,
    required ChatTransportOnComplete? onComplete,
  }) async {
    final omitReasoning =
        !(request.showNativeReasoning ?? !request.omitReasoning);

    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        if (request.stream) {
          await _streamResponse(
            url,
            request.apiKey,
            body,
            cancelToken,
            onUpdate,
            onComplete,
            omitReasoning: omitReasoning,
            receiveTimeoutMs: request.receiveTimeoutMs,
          );
        } else {
          await _oneShotResponse(
            url,
            request.apiKey,
            body,
            cancelToken,
            onComplete,
            omitReasoning: omitReasoning,
            receiveTimeoutMs: request.receiveTimeoutMs,
          );
        }
        return;
      } on DioException catch (e) {
        if (attempt < _maxRetries &&
            e.response?.statusCode == 408 &&
            cancelToken?.isCancelled != true) {
          debugPrint(
            '[OpenAI] HTTP 408 on attempt ${attempt + 1}/$_maxRetries — retrying',
          );
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }
        rethrow;
      }
    }
  }

  /// Builds the JSON body for a chat completion request. Public so the
  /// OpenRouter transport (which reuses the same shape with extra fields) and
  /// the request-preview UI can reproduce the exact on-the-wire body.
  static Map<String, dynamic> buildBody(
    ChatTransportRequest r, {
    String protocol = LlmProtocol.openai,
  }) {
    final body = <String, dynamic>{
      'model': r.model,
      'messages': r.messages,
      'stream': r.stream,
    };

    if (r.maxTokens > 0) {
      body['max_tokens'] = r.maxTokens;
    }
    // The omit* flags are the ONLY switch for these — never suppress a
    // parameter because of its value. `temperature: 0` and `top_p: 1` are
    // settings the user can pick in the UI, and dropping them silently made
    // the slider a no-op with no trace in the prompt inspector.
    if (!r.omitTemperature) {
      body['temperature'] = r.temperature;
    }
    if (!r.omitTopP) {
      body['top_p'] = r.topP;
    }
    // top_k is the exception: 0 is not a legal value upstream (Anthropic and
    // Gemini both require >= 1), so 0 keeps meaning "not set".
    if (!r.omitTopK && r.topK > 0) {
      body['top_k'] = r.topK;
    }
    if (!r.omitFrequencyPenalty) {
      body['frequency_penalty'] = r.frequencyPenalty;
    }
    if (!r.omitPresencePenalty) {
      body['presence_penalty'] = r.presencePenalty;
    }
    if (!r.omitReasoning && r.requestReasoning && !r.omitReasoningEffort) {
      // Wire values are protocol-specific: official OpenAI caps at `high`,
      // while a selected Custom Chat Completion protocol keeps `max`.
      final effort = resolveReasoningEffort(
        protocol: protocol,
        effort: r.reasoningEffort,
        model: r.model,
      );
      if (effort != null) body['reasoning_effort'] = effort;
    }

    if (r.cacheControlTtl == '5min' || r.cacheControlTtl == '1h') {
      body['cache_control'] = <String, dynamic>{
        'type': 'ephemeral',
        if (r.cacheControlTtl == '1h') 'ttl': '1h',
      };
    }
    if (r.shouldSendOpenAiSessionId) {
      body['session_id'] = r.sessionId;
    }

    if (r.tools != null && r.tools!.isNotEmpty) {
      body['tools'] = r.tools;
      body['tool_choice'] = r.toolChoice ?? 'auto';
    }

    applyExtraRequestParameters(body, r.extraRequestParameters);

    return body;
  }

  Future<void> _streamResponse(
    String url,
    String apiKey,
    Map<String, dynamic> body,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete, {
    bool omitReasoning = false,
    int? receiveTimeoutMs,
  }) async {
    final response = await _dio.post<ResponseBody>(
      url,
      options: Options(
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
          ..._extraHeaders,
        },
        responseType: ResponseType.stream,
        receiveTimeout: _receiveTimeout(receiveTimeoutMs),
      ),
      data: body,
      cancelToken: cancelToken,
    );

    final responseBody = response.data;
    if (responseBody == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        message: 'Empty stream response body',
      );
    }
    final responseStream = responseBody.stream;
    final completer = Completer<void>();
    StreamSubscription<String>? subscription;
    var buffer = '';
    var fullText = '';
    var fullReasoning = '';
    var doneReceived = false;
    String? lastRawJsonPayload;

    Future<void> finishAfterCancel([Object? error, StackTrace? stack]) async {
      await subscription?.cancel();
      if (completer.isCompleted) return;
      if (error == null) {
        completer.complete();
      } else {
        completer.completeError(error, stack);
      }
    }

    subscription = utf8.decoder
        .bind(responseStream)
        .listen(
          (chunk) {
            if (cancelToken?.isCancelled == true) {
              debugPrint(
                '[SSE] cancel detected in listen callback, stopping stream',
              );
              unawaited(finishAfterCancel());
              return;
            }
            buffer += chunk;
            final lines = buffer.split('\n');
            buffer = lines.removeLast();

            for (final line in lines) {
              if (cancelToken?.isCancelled == true) {
                debugPrint(
                  '[SSE] cancel detected while parsing lines, stopping immediately',
                );
                buffer = '';
                unawaited(finishAfterCancel());
                return;
              }
              final data = _sseData(line);
              if (data == null) continue;
              if (data == '[DONE]') {
                if (cancelToken != null && cancelToken.isCancelled) {
                  debugPrint(
                    '[SSE] cancel detected at [DONE], suppressing onComplete',
                  );
                } else {
                  onComplete?.call(
                    fullText,
                    fullReasoning.isNotEmpty ? fullReasoning : null,
                    rawResponseJson: _buildAggregatedRawResponse(
                      fullText: fullText,
                      fullReasoning: fullReasoning,
                      fallbackRawJsonPayload: lastRawJsonPayload,
                    ),
                  );
                  doneReceived = true;
                }
                unawaited(finishAfterCancel());
                return;
              }

              lastRawJsonPayload = data;

              try {
                final json = jsonDecode(data) as Map<String, dynamic>;
                final choice = json['choices']?[0];
                final delta = choice?['delta'];

                final contentDelta = delta?['content'] as String? ?? '';
                // When omitReasoning is set, skip native reasoning_content so
                // inline <think> parsing in StreamAccumulator is not suppressed
                // by _hasExternalReasoning. The provider may still emit the
                // field, but we discard it on the response side.
                final reasoningDelta = omitReasoning
                    ? null
                    : (delta?['reasoning_content'] as String? ??
                          delta?['reasoning'] as String?);

                if (contentDelta.isNotEmpty) {
                  fullText += contentDelta;
                }
                if (reasoningDelta != null && reasoningDelta.isNotEmpty) {
                  fullReasoning += reasoningDelta;
                }

                if (contentDelta.isNotEmpty || reasoningDelta != null) {
                  onUpdate?.call(contentDelta, reasoningDelta);
                }
              } catch (_) {}
            }
          },
          onDone: () => unawaited(finishAfterCancel()),
          onError: (Object e, StackTrace stack) =>
              unawaited(finishAfterCancel(e, stack)),
          cancelOnError: true,
        );

    if (cancelToken != null) {
      unawaited(
        cancelToken.whenCancel.then((_) async {
          debugPrint(
            '[SSE] CancelToken fired — cancelling stream subscription',
          );
          await finishAfterCancel();
        }),
      );
    }

    await completer.future;

    if (cancelToken != null && cancelToken.isCancelled) {
      debugPrint(
        '[SSE] stream completed with cancel active; suppressing onComplete',
      );
      return;
    }

    if (doneReceived) return;

    // Server dropped connection without [DONE] — treat as normal completion
    // if any text was accumulated (provider returned 200 but omitted [DONE]).
    if (fullText.isNotEmpty || fullReasoning.isNotEmpty) {
      onComplete?.call(
        fullText,
        fullReasoning.isNotEmpty ? fullReasoning : null,
        rawResponseJson: _buildAggregatedRawResponse(
          fullText: fullText,
          fullReasoning: fullReasoning,
          fallbackRawJsonPayload: lastRawJsonPayload,
        ),
      );
      return;
    }
    throw DioException(
      requestOptions: RequestOptions(path: url),
      message: 'Stream ended without [DONE] (server dropped connection)',
      type: DioExceptionType.connectionError,
    );
  }

  Future<void> _oneShotResponse(
    String url,
    String apiKey,
    Map<String, dynamic> body,
    CancelToken? cancelToken,
    ChatTransportOnComplete? onComplete, {
    bool omitReasoning = false,
    int? receiveTimeoutMs,
  }) async {
    final response = await _dio.post<dynamic>(
      url,
      options: Options(
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          ..._extraHeaders,
        },
        receiveTimeout: _receiveTimeout(receiveTimeoutMs),
      ),
      data: body,
      cancelToken: cancelToken,
    );

    final raw = response.data;
    Map<String, dynamic>? data;

    String? rawResponseJson;
    if (raw is Map<String, dynamic>) {
      data = raw;
      try {
        rawResponseJson = jsonEncode(raw);
      } catch (_) {}
    } else if (raw is String && raw.trim().isNotEmpty) {
      final trimmed = raw.trim();
      rawResponseJson = trimmed;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) data = decoded;
      } catch (_) {}
      if (data == null && trimmed.contains('data:')) {
        final agg = _aggregateSseString(trimmed);
        onComplete?.call(
          agg.$1,
          (omitReasoning || agg.$2.isEmpty) ? null : agg.$2,
          rawResponseJson: rawResponseJson,
        );
        return;
      }
    }

    if (data == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        message: 'Unexpected response body (${raw.runtimeType})',
      );
    }

    final choice =
        (data['choices'] is List && (data['choices'] as List).isNotEmpty)
        ? (data['choices'] as List).first
        : null;
    final message = choice is Map<String, dynamic> ? choice['message'] : null;
    final content =
        (message is Map<String, dynamic> ? message['content'] : null)
            as String? ??
        '';
    final reasoningRaw = message is Map<String, dynamic>
        ? (message['reasoning_content'] ?? message['reasoning'])
        : null;
    final reasoning = omitReasoning
        ? null
        : (reasoningRaw is String ? reasoningRaw : null);

    onComplete?.call(
      content,
      reasoning,
      rawResponseJson: rawResponseJson ?? jsonEncode(data),
    );
  }

  Duration? _receiveTimeout(int? timeoutMs) =>
      timeoutMs == null ? null : Duration(milliseconds: timeoutMs);

  (String, String) _aggregateSseString(String body) {
    var fullText = '';
    var fullReasoning = '';
    for (final line in body.split('\n')) {
      final payload = _sseData(line);
      if (payload == null) continue;
      if (payload == '[DONE]') break;
      try {
        final json = jsonDecode(payload) as Map<String, dynamic>;
        final choice =
            (json['choices'] is List && (json['choices'] as List).isNotEmpty)
            ? (json['choices'] as List).first
            : null;
        final delta = choice is Map<String, dynamic> ? choice['delta'] : null;
        final msg = choice is Map<String, dynamic> ? choice['message'] : null;
        final src = delta is Map<String, dynamic>
            ? delta
            : (msg is Map<String, dynamic> ? msg : null);
        if (src == null) continue;
        final c = src['content'];
        if (c is String) fullText += c;
        final r = src['reasoning_content'] ?? src['reasoning'];
        if (r is String) fullReasoning += r;
      } catch (_) {}
    }
    return (fullText, fullReasoning);
  }

  String? _buildAggregatedRawResponse({
    required String fullText,
    required String fullReasoning,
    String? fallbackRawJsonPayload,
  }) {
    if (fullText.isEmpty && fullReasoning.isEmpty) {
      return fallbackRawJsonPayload;
    }

    final message = <String, dynamic>{'role': 'assistant', 'content': fullText};
    if (fullReasoning.isNotEmpty) {
      message['reasoning'] = fullReasoning;
    }

    if (fallbackRawJsonPayload != null) {
      try {
        final base = jsonDecode(fallbackRawJsonPayload) as Map<String, dynamic>;
        final rawChoices = base['choices'];
        List<dynamic> newChoices;
        if (rawChoices is List && rawChoices.isNotEmpty) {
          newChoices = rawChoices.asMap().entries.map((entry) {
            final choice = Map<String, dynamic>.from(
              entry.value is Map
                  ? entry.value as Map<String, dynamic>
                  : <String, dynamic>{},
            );
            if (entry.key == 0) {
              choice.remove('delta');
              choice['message'] = message;
            }
            return choice;
          }).toList();
        } else {
          newChoices = [
            {'index': 0, 'message': message, 'finish_reason': 'stop'},
          ];
        }

        final merged = Map<String, dynamic>.from(base);
        merged['choices'] = newChoices;
        merged['object'] = merged['object'] ?? 'chat.completion';

        return jsonEncode(merged);
      } catch (_) {}
    }

    return jsonEncode({
      'object': 'chat.completion',
      'choices': [
        {'index': 0, 'message': message, 'finish_reason': 'stop'},
      ],
    });
  }

  /// Extract an SSE data field without trimming its JSON payload. The optional
  /// single space after `data:` is framing, not content.
  String? _sseData(String line) {
    final normalized = line.endsWith('\r')
        ? line.substring(0, line.length - 1)
        : line;
    if (!normalized.startsWith('data:')) return null;
    final value = normalized.substring(5);
    return value.startsWith(' ') ? value.substring(1) : value;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async {
    final urls = EndpointResolutionCache.order(
      endpoint,
      _modelsRoute,
      EndpointNormalizer.modelsCandidates(endpoint),
    );

    for (final url in urls) {
      try {
        final response = await _dio.get<Map<String, dynamic>>(
          url,
          options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
        );
        final data = response.data?['data'] as List?;
        if (data == null) continue;
        EndpointResolutionCache.record(endpoint, _modelsRoute, url);
        return data.cast<Map<String, dynamic>>();
      } catch (_) {
        continue;
      }
    }
    return [];
  }
}
