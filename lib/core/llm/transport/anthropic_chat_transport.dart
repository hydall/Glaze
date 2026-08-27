import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../utils/error_format.dart';
import '../converters/claude_messages.dart';
import '../converters/cache_breakpoint_marker.dart';
import '../converters/thinking_budget.dart';
import 'chat_transport.dart';
import 'chat_transport_request.dart';
import 'endpoint_normalizer.dart';
import 'endpoint_resolution_cache.dart';
import 'extra_request_parameters.dart';

/// Result of [AnthropicChatTransport.buildRequest] — body + headers + the
/// detected prefill text (null when no trailing assistant turn was used).
class AnthropicBuiltRequest {
  final Map<String, dynamic> body;
  final Map<String, String> headers;
  final String? prefill;

  const AnthropicBuiltRequest({
    required this.body,
    required this.headers,
    this.prefill,
  });
}

/// Anthropic Messages API transport.
///
/// Handles:
/// - URL & auth (`x-api-key`, `anthropic-version`).
/// - Conversion to Anthropic shape via `convertClaudeMessages`.
/// - Prefill: trailing assistant message is taken as Anthropic continuation;
///   its text is prepended back to the streamed response so consumers see a
///   continuous reply.
/// - Extended thinking: traditional (`{type: enabled, budget_tokens}`) and
///   adaptive (`{type: adaptive}` + `output_config.effort`) per model id.
///   When thinking is on, prefill is dropped (Anthropic constraint).
/// - Cache control: when [ChatTransportRequest.cacheControlTtl] is set, marks
///   the last system part and a message at depth=2 with `ephemeral` cache.
/// - System handling: the leading run of `system` messages goes to the
///   top-level `system` field unless [ChatTransportRequest.useSystemInstruction]
///   is off, in which case it stays inline as user turns.
/// - SSE events: `content_block_delta` → text/reasoning; `message_stop` → done.
class AnthropicChatTransport implements ChatTransport {
  static const String _apiVersion = '2023-06-01';

  /// Default cache breakpoint depth when user enables `cacheControlTtl` but
  /// hasn't specified a depth.
  static const int _defaultCacheDepth = 2;

  /// Minimum response budget when extended thinking is on.
  static const int _minThinkResponseTokens = 1024;

  final Dio _dio;

  /// Number of automatic retries on HTTP 408 (Request Timeout) — common on
  /// mobile networks where the upload is too slow for the provider.
  static const int _maxRetries = 1;

  AnthropicChatTransport({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 60),
              receiveTimeout: const Duration(seconds: 180),
            ),
          );

  static const String _messagesRoute = '/messages';
  static const String _modelsRoute = '/models';

  static String buildMessagesUrl(String endpoint) =>
      EndpointNormalizer.messagesUrl(endpoint);

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    if (request.apiKey.isEmpty) {
      onError?.call(Exception('Anthropic API key is empty'));
      return;
    }

    final urls = EndpointResolutionCache.order(
      request.endpoint,
      _messagesRoute,
      EndpointNormalizer.messagesCandidates(request.endpoint),
    );
    if (urls.isEmpty) {
      onError?.call(Exception('Endpoint is empty or not a valid URL'));
      return;
    }

    final AnthropicBuiltRequest built;
    try {
      built = buildRequest(request);
    } catch (e) {
      onError?.call(e);
      return;
    }
    final omitReasoning =
        !(request.showNativeReasoning ?? !request.omitReasoning);

    // A 404/405 means the base path is wrong, not the request — walk the
    // remaining candidates before surfacing the (first) failure.
    DioException? firstError;

    for (var i = 0; i < urls.length; i++) {
      final url = urls[i];
      for (var attempt = 0; attempt <= _maxRetries; attempt++) {
        try {
          if (request.stream) {
            await _streamResponse(
              url,
              built.headers,
              built.body,
              prefill: built.prefill,
              cancelToken: cancelToken,
              onUpdate: onUpdate,
              onComplete: onComplete,
              omitReasoning: omitReasoning,
              receiveTimeoutMs: request.receiveTimeoutMs,
            );
          } else {
            await _oneShotResponse(
              url,
              built.headers,
              built.body,
              prefill: built.prefill,
              cancelToken: cancelToken,
              onComplete: onComplete,
              omitReasoning: omitReasoning,
              receiveTimeoutMs: request.receiveTimeoutMs,
            );
          }
          EndpointResolutionCache.record(request.endpoint, _messagesRoute, url);
          return; // success — no retry needed
        } on DioException catch (e) {
          if (attempt < _maxRetries &&
              e.response?.statusCode == 408 &&
              cancelToken?.isCancelled != true) {
            debugPrint(
              '[Anthropic] HTTP 408 on attempt ${attempt + 1}/$_maxRetries — retrying',
            );
            await Future<void>.delayed(const Duration(seconds: 1));
            continue;
          }
          final reportable = firstError ?? e;
          firstError = reportable;
          final status = e.response?.statusCode;
          if (i < urls.length - 1 &&
              (status == 404 || status == 405) &&
              cancelToken?.isCancelled != true) {
            debugPrint('[Anthropic] $status on $url — trying ${urls[i + 1]}');
            break; // next candidate URL
          }
          onError?.call(await decodeStreamingError(reportable));
          return;
        } catch (e) {
          onError?.call(e);
          return;
        }
      }
    }
  }

  /// Builds the Anthropic request body, headers, and detected prefill from a
  /// neutral [ChatTransportRequest]. Exposed for unit testing — production
  /// code calls [stream] which uses this internally.
  static AnthropicBuiltRequest buildRequest(ChatTransportRequest request) {
    final useThinking = request.requestReasoning && !request.omitReasoning;
    final adaptive = isAdaptiveClaudeModel(request.model);

    // 1. Convert messages. Prefill is incompatible with extended thinking.
    final converted = convertClaudeMessages(
      request.messages,
      extractPrefill: !useThinking,
      useSystemInstruction: request.useSystemInstruction,
    );

    var messages = converted.messages;
    final systemParts = converted.system;
    final prefill = converted.prefill;

    // 2. Drop trailing assistant turn when thinking is on (Anthropic constraint).
    if (useThinking &&
        messages.isNotEmpty &&
        messages.last['role'] == 'assistant') {
      debugPrint(
        '[anthropic] thinking enabled — dropping trailing assistant turn',
      );
      messages = messages.sublist(0, messages.length - 1);
    }

    // 3. Cache control on system + at depth.
    final ttl = _resolveTtl(request.cacheControlTtl);
    if (ttl != null && systemParts.isNotEmpty) {
      final last = Map<String, dynamic>.from(systemParts.last);
      last['cache_control'] = {'type': 'ephemeral', 'ttl': ttl};
      systemParts[systemParts.length - 1] = last;
    }
    if (ttl != null &&
        request.cacheBreakpointMode == cacheBreakpointModeStablePrefix) {
      final previousConverted = request.previousMessages == null
          ? null
          : convertClaudeMessages(
              request.previousMessages!,
              extractPrefill: !useThinking,
              useSystemInstruction: request.useSystemInstruction,
            ).messages;
      messages = markStablePrefixCacheControl(
        messages,
        previousConverted,
        ttl: ttl,
      );
    } else if (ttl != null) {
      messages = _applyCacheAtDepth(messages, _defaultCacheDepth, ttl);
    }

    // 4. Body.
    final body = <String, dynamic>{
      'model': request.model,
      'messages': messages,
      'max_tokens': request.maxTokens > 0 ? request.maxTokens : 4096,
      'stream': request.stream,
    };
    if (systemParts.isNotEmpty) body['system'] = systemParts;
    if (request.sessionIdMode == 'always' &&
        request.sessionId != null &&
        request.sessionId!.isNotEmpty) {
      body['session_id'] = request.sessionId;
    }

    // Gated on the omit* flags only — see the note in
    // `OpenAiChatTransport.buildBody`. top_k keeps its `> 0` guard because
    // Anthropic rejects `top_k: 0`.
    if (!request.omitTemperature) {
      body['temperature'] = request.temperature;
    }
    if (!request.omitTopP) {
      body['top_p'] = request.topP;
    }
    if (!request.omitTopK && request.topK > 0) {
      body['top_k'] = request.topK;
    }

    final betaHeaders = <String>[];
    if (ttl != null) {
      betaHeaders
        ..add('prompt-caching-2024-07-31')
        ..add('extended-cache-ttl-2025-04-11');
    }

    // 5. Thinking config.
    if (useThinking) {
      final budget = calculateClaudeBudgetTokens(
        maxTokens: body['max_tokens'] as int,
        reasoningEffort: request.omitReasoningEffort
            ? 'auto'
            : request.reasoningEffort ?? 'auto',
        stream: request.stream,
        isAdaptiveModel: adaptive,
      );
      if (budget is int) {
        // Traditional thinking: max_tokens must leave room for response.
        final currentMax = body['max_tokens'] as int;
        if (currentMax <= _minThinkResponseTokens) {
          body['max_tokens'] = currentMax + _minThinkResponseTokens;
        }
        body['thinking'] = {'type': 'enabled', 'budget_tokens': budget};
        body.remove('temperature');
        body.remove('top_p');
        body.remove('top_k');
      } else if (budget is String) {
        body['thinking'] = {'type': 'adaptive'};
        body.putIfAbsent('output_config', () => <String, dynamic>{});
        (body['output_config'] as Map<String, dynamic>)['effort'] = budget;
        body.remove('top_k');
      }
      // budget == null → 'auto', omit thinking config entirely.
    }

    applyExtraRequestParameters(body, request.extraRequestParameters);

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'anthropic-version': _apiVersion,
      'x-api-key': request.apiKey,
      if (betaHeaders.isNotEmpty) 'anthropic-beta': betaHeaders.join(','),
    };

    return AnthropicBuiltRequest(
      body: body,
      headers: headers,
      prefill: prefill,
    );
  }

  /// Cache-at-depth marker injection, exposed for testing.
  @visibleForTesting
  static List<Map<String, dynamic>> applyCacheAtDepthForTest(
    List<Map<String, dynamic>> input,
    int depthTarget,
    String ttl,
  ) => _applyCacheAtDepth(input, depthTarget, ttl);

  Future<void> _streamResponse(
    String url,
    Map<String, String> headers,
    Map<String, dynamic> body, {
    required String? prefill,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    bool omitReasoning = false,
    int? receiveTimeoutMs,
  }) async {
    final response = await _dio.post<ResponseBody>(
      url,
      options: Options(
        headers: headers,
        responseType: ResponseType.stream,
        receiveTimeout: _receiveTimeout(receiveTimeoutMs),
      ),
      data: body,
      cancelToken: cancelToken,
    );

    final stream = response.data?.stream;
    if (stream == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        message: 'Empty stream response body',
      );
    }

    // Seed the aggregated text with the prefill so consumers see a
    // continuous reply. We do NOT replay it via onUpdate — UI already shows
    // the prefill from the preset.
    var fullText = prefill ?? '';
    var fullReasoning = '';
    final usage = <String, dynamic>{};
    var doneReceived = false;
    String? lastRawJsonPayload;

    final completer = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    var buffer = '';

    Future<void> finishAfterCancel([Object? error, StackTrace? stack]) async {
      await subscription?.cancel();
      if (completer.isCompleted) return;
      if (error == null) {
        completer.complete();
      } else {
        completer.completeError(error, stack);
      }
    }

    subscription = stream.listen(
      (chunk) {
        if (cancelToken?.isCancelled == true) {
          unawaited(finishAfterCancel());
          return;
        }
        buffer += utf8.decode(chunk, allowMalformed: true);
        final lines = buffer.split('\n');
        buffer = lines.removeLast();

        for (final line in lines) {
          final payload = _sseData(line);
          if (payload == null) continue;
          if (payload.isEmpty) continue;
          lastRawJsonPayload = payload;

          try {
            final json = jsonDecode(payload) as Map<String, dynamic>;
            final type = json['type'] as String?;

            if (type == 'content_block_delta') {
              final delta = json['delta'] as Map<String, dynamic>?;
              final deltaType = delta?['type'] as String?;
              if (deltaType == 'text_delta') {
                final text = delta?['text'] as String? ?? '';
                if (text.isNotEmpty) {
                  fullText += text;
                  onUpdate?.call(text, null);
                }
              } else if (deltaType == 'thinking_delta') {
                // When omitReasoning is set, skip native thinking deltas so
                // inline  parsing is not suppressed by _hasExternalReasoning.
                if (omitReasoning) continue;
                final reasoning = delta?['thinking'] as String? ?? '';
                if (reasoning.isNotEmpty) {
                  fullReasoning += reasoning;
                  onUpdate?.call('', reasoning);
                }
              }
            } else if (type == 'message_delta') {
              final u = json['usage'] as Map<String, dynamic>?;
              if (u != null) usage.addAll(u);
            } else if (type == 'message_stop') {
              if (cancelToken == null || !cancelToken.isCancelled) {
                onComplete?.call(
                  fullText,
                  fullReasoning.isNotEmpty ? fullReasoning : null,
                  rawResponseJson: _buildAggregatedRaw(
                    fullText: fullText,
                    fullReasoning: fullReasoning,
                    usage: usage,
                    fallbackPayload: lastRawJsonPayload,
                  ),
                );
                doneReceived = true;
              }
              unawaited(finishAfterCancel());
              return;
            } else if (type == 'error') {
              throw DioException(
                requestOptions: response.requestOptions,
                response: response,
                type: DioExceptionType.badResponse,
                message: 'Anthropic stream error: ${json['error']}',
              );
            }
          } catch (e) {
            if (e is DioException) rethrow;
            // Swallow JSON parse errors on individual chunks — Anthropic
            // sometimes interleaves `event:` lines that aren't data.
          }
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
          await finishAfterCancel();
        }),
      );
    }

    await completer.future;

    if (cancelToken?.isCancelled == true) return;

    if (!doneReceived && (fullText.isNotEmpty || fullReasoning.isNotEmpty)) {
      onComplete?.call(
        fullText,
        fullReasoning.isNotEmpty ? fullReasoning : null,
        rawResponseJson: _buildAggregatedRaw(
          fullText: fullText,
          fullReasoning: fullReasoning,
          usage: usage,
          fallbackPayload: lastRawJsonPayload,
        ),
      );
    } else if (!doneReceived) {
      throw DioException(
        requestOptions: RequestOptions(path: url),
        message: 'Anthropic stream ended without message_stop',
        type: DioExceptionType.connectionError,
      );
    }
  }

  String? _sseData(String line) {
    final normalized = line.endsWith('\r')
        ? line.substring(0, line.length - 1)
        : line;
    if (!normalized.startsWith('data:')) return null;
    final value = normalized.substring(5);
    return value.startsWith(' ') ? value.substring(1) : value;
  }

  Future<void> _oneShotResponse(
    String url,
    Map<String, String> headers,
    Map<String, dynamic> body, {
    required String? prefill,
    CancelToken? cancelToken,
    ChatTransportOnComplete? onComplete,
    bool omitReasoning = false,
    int? receiveTimeoutMs,
  }) async {
    final response = await _dio.post<dynamic>(
      url,
      options: Options(
        headers: {...headers, 'Accept': 'application/json'},
        receiveTimeout: _receiveTimeout(receiveTimeoutMs),
      ),
      data: body,
      cancelToken: cancelToken,
    );

    final raw = response.data;
    Map<String, dynamic>? data;
    String? rawJson;
    if (raw is Map<String, dynamic>) {
      data = raw;
      try {
        rawJson = jsonEncode(raw);
      } catch (_) {}
    } else if (raw is String) {
      rawJson = raw.trim();
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) data = decoded;
      } catch (_) {}
    }

    if (data == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Unexpected Anthropic response body (${raw.runtimeType})',
        type: DioExceptionType.badResponse,
      );
    }

    final content = data['content'];
    final textBuf = StringBuffer(prefill ?? '');
    final reasoningBuf = StringBuffer();
    if (content is List) {
      for (final part in content) {
        if (part is! Map) continue;
        final type = part['type'];
        if (type == 'text') {
          final t = part['text'];
          if (t is String) textBuf.write(t);
        } else if (type == 'thinking') {
          if (omitReasoning) continue;
          final t = part['thinking'];
          if (t is String) reasoningBuf.write(t);
        }
      }
    }

    onComplete?.call(
      textBuf.toString(),
      reasoningBuf.isEmpty ? null : reasoningBuf.toString(),
      rawResponseJson: rawJson ?? jsonEncode(data),
    );
  }

  Duration? _receiveTimeout(int? timeoutMs) =>
      timeoutMs == null ? null : Duration(milliseconds: timeoutMs);

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async {
    if (apiKey.isEmpty || endpoint.trim().isEmpty) return const [];
    final urls = EndpointResolutionCache.order(
      endpoint,
      _modelsRoute,
      EndpointNormalizer.modelsCandidates(endpoint),
    );
    for (final url in urls) {
      try {
        final response = await _dio.get<Map<String, dynamic>>(
          url,
          options: Options(
            headers: {'x-api-key': apiKey, 'anthropic-version': _apiVersion},
          ),
        );
        final data = response.data?['data'] as List?;
        if (data == null) continue;
        EndpointResolutionCache.record(endpoint, _modelsRoute, url);
        return data.cast<Map<String, dynamic>>();
      } catch (_) {
        continue;
      }
    }
    return const [];
  }

  // ── helpers ───────────────────────────────────────────────────────────────

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

  /// Anthropic-flavoured cache_control marker injection at depth, mirroring
  /// SillyTavern's `cachingAtDepthForClaude`. Depth counts role flips back
  /// from the end (skipping a trailing assistant prefill).
  static List<Map<String, dynamic>> _applyCacheAtDepth(
    List<Map<String, dynamic>> input,
    int depthTarget,
    String ttl,
  ) {
    if (input.isEmpty) return input;
    final out = input
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: false);

    var passedPrefill = false;
    var depth = 0;
    String? previousRole;
    for (var i = out.length - 1; i >= 0; i--) {
      final role = out[i]['role'];
      if (!passedPrefill && role == 'assistant') continue;
      passedPrefill = true;
      if (role != previousRole) {
        if (depth == depthTarget || depth == depthTarget + 2) {
          final content = out[i]['content'];
          if (content is List && content.isNotEmpty) {
            final mutable = content.cast<dynamic>().toList();
            final last = mutable.last;
            if (last is Map) {
              final updated = Map<String, dynamic>.from(last);
              updated['cache_control'] = {'type': 'ephemeral', 'ttl': ttl};
              mutable[mutable.length - 1] = updated;
              out[i]['content'] = mutable;
            }
          }
        }
        if (depth == depthTarget + 2) break;
        depth += 1;
        previousRole = role as String?;
      }
    }
    return out;
  }

  String _buildAggregatedRaw({
    required String fullText,
    required String fullReasoning,
    required Map<String, dynamic> usage,
    String? fallbackPayload,
  }) {
    final content = <Map<String, dynamic>>[
      if (fullReasoning.isNotEmpty)
        {'type': 'thinking', 'thinking': fullReasoning},
      {'type': 'text', 'text': fullText},
    ];
    return jsonEncode({
      'type': 'message',
      'role': 'assistant',
      'content': content,
      if (usage.isNotEmpty) 'usage': usage,
      'last_event': ?fallbackPayload,
    });
  }
}
