import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../utils/error_format.dart';
import 'chat_transport.dart';
import 'chat_transport_request.dart';
import 'extra_request_parameters.dart';

/// OpenAI Chat Completions transport. Also handles any OpenAI-compatible
/// custom endpoint (LM Studio, Koboldcpp, vLLM, OpenRouter-as-custom, etc.).
///
/// This is the exact behavior the legacy `SseClient` had — the class is the
/// canonical home for that logic; `SseClient` is now a thin compatibility
/// shim that delegates here.
class OpenAiChatTransport implements ChatTransport {
  final Dio _dio;

  /// Number of automatic retries on HTTP 408 (Request Timeout) — common on
  /// mobile networks where the upload is too slow for the provider.
  static const int _maxRetries = 1;

  /// Extra headers merged into every HTTP request. Used by
  /// `OpenRouterChatTransport` to inject `HTTP-Referer` and `X-Title`.
  final Map<String, String> _extraHeaders;

  OpenAiChatTransport({Dio? dio, Map<String, String>? extraHeaders})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 60),
              receiveTimeout: const Duration(seconds: 120),
            ),
          ),
      _extraHeaders = extraHeaders ?? const {};

  static String normalizeEndpoint(String endpoint) {
    var normalized = endpoint.trim();
    if (normalized.isEmpty) return '';
    if (!normalized.startsWith(RegExp(r'https?://'))) {
      normalized = 'https://$normalized';
    }
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static String buildChatUrl(String endpoint) {
    final base = normalizeEndpoint(endpoint);
    if (base.isEmpty) return '';
    if (base.toLowerCase().endsWith('/chat/completions')) return base;
    return '$base/chat/completions';
  }

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
    final url = buildChatUrl(request.endpoint);

    final body = buildBody(request);

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
            omitReasoning:
                !(request.showNativeReasoning ?? !request.omitReasoning),
            receiveTimeoutMs: request.receiveTimeoutMs,
          );
        } else {
          await _oneShotResponse(
            url,
            request.apiKey,
            body,
            cancelToken,
            onComplete,
            omitReasoning:
                !(request.showNativeReasoning ?? !request.omitReasoning),
            receiveTimeoutMs: request.receiveTimeoutMs,
          );
        }
        return; // success — no retry needed
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
        onError?.call(await decodeStreamingError(e));
        return;
      } catch (e) {
        onError?.call(e);
        return;
      }
    }
  }

  /// Builds the JSON body for a chat completion request. Public so the
  /// OpenRouter transport (which reuses the same shape with extra fields) and
  /// the request-preview UI can reproduce the exact on-the-wire body.
  static Map<String, dynamic> buildBody(ChatTransportRequest r) {
    final body = <String, dynamic>{
      'model': r.model,
      'messages': r.messages,
      'stream': r.stream,
    };

    if (r.maxTokens > 0) {
      body['max_tokens'] = r.maxTokens;
    }
    if (!r.omitTemperature && r.temperature > 0) {
      body['temperature'] = r.temperature;
    }
    if (!r.omitTopP && r.topP > 0 && r.topP < 1) {
      body['top_p'] = r.topP;
    }
    if (!r.omitTopK && r.topK > 0) {
      body['top_k'] = r.topK;
    }
    if (!r.omitFrequencyPenalty && r.frequencyPenalty != 0) {
      body['frequency_penalty'] = r.frequencyPenalty;
    }
    if (!r.omitPresencePenalty && r.presencePenalty != 0) {
      body['presence_penalty'] = r.presencePenalty;
    }
    if (!r.omitReasoning &&
        r.requestReasoning &&
        !r.omitReasoningEffort &&
        r.reasoningEffort != null &&
        r.reasoningEffort != 'auto') {
      body['reasoning_effort'] = r.reasoningEffort;
    }

    if (r.cacheControlTtl == '5min' || r.cacheControlTtl == '1h') {
      body['cache_control'] = <String, dynamic>{
        'type': 'ephemeral',
        if (r.cacheControlTtl == '1h') 'ttl': '1h',
      };
    }
    final shouldSendSessionId =
        r.sessionId != null &&
        r.sessionId!.isNotEmpty &&
        (r.sessionIdMode == 'always' ||
            (r.sessionIdMode == 'openrouter' &&
                r.endpoint.contains('openrouter.ai')));
    if (shouldSendSessionId) {
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
    StreamSubscription<List<int>>? subscription;
    var buffer = '';
    var fullText = '';
    var fullReasoning = '';
    var doneReceived = false;
    String? lastRawJsonPayload;

    subscription = (responseStream as Stream<List<int>>).listen(
      (chunk) {
        if (cancelToken?.isCancelled == true) {
          debugPrint(
            '[SSE] cancel detected in listen callback, stopping stream',
          );
          subscription?.cancel();
          if (!completer.isCompleted) completer.complete();
          return;
        }
        buffer += utf8.decode(chunk, allowMalformed: true);
        final lines = buffer.split('\n');
        buffer = lines.removeLast();

        for (final line in lines) {
          if (cancelToken?.isCancelled == true) {
            debugPrint(
              '[SSE] cancel detected while parsing lines, stopping immediately',
            );
            buffer = '';
            subscription?.cancel();
            if (!completer.isCompleted) completer.complete();
            return;
          }
          final trimmed = line.trim();
          if (!trimmed.startsWith('data: ')) continue;
          final data = trimmed.substring(6).trim();
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
            subscription?.cancel();
            if (!completer.isCompleted) completer.complete();
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
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object e) {
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      },
      cancelOnError: true,
    );

    if (cancelToken != null) {
      unawaited(
        cancelToken.whenCancel.then((_) {
          debugPrint(
            '[SSE] CancelToken fired — cancelling stream subscription',
          );
          subscription?.cancel();
          if (!completer.isCompleted) completer.complete();
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
      final trimmed = line.trim();
      if (!trimmed.startsWith('data: ')) continue;
      final payload = trimmed.substring(6).trim();
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

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async {
    final base = normalizeEndpoint(endpoint);
    final url = '$base/models';

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        url,
        options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
      );
      final data = response.data?['data'] as List?;
      return data?.cast<Map<String, dynamic>>() ?? [];
    } catch (_) {
      return [];
    }
  }
}
