import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../utils/error_format.dart';
import '../converters/gemini_messages.dart';
import '../converters/thinking_budget.dart';
import 'chat_transport.dart';
import 'chat_transport_request.dart';
import 'endpoint_normalizer.dart';
import 'extra_request_parameters.dart';

/// Result of [GeminiChatTransport.buildRequest] — URL/body/headers ready to
/// POST. Exposed for unit testing.
class GeminiBuiltRequest {
  final String url;
  final Map<String, dynamic> body;
  final Map<String, String> headers;

  const GeminiBuiltRequest({
    required this.url,
    required this.body,
    required this.headers,
  });
}

/// Google Gemini AI Studio transport (no Vertex AI).
///
/// Wire format:
/// - URL: `{endpoint}/v1beta/models/{model}:streamGenerateContent?alt=sse&key=…`
///   for streaming; `:generateContent` for one-shot. `key` query param holds
///   the API key (no auth header).
/// - Body: `contents` + `systemInstruction` (from `convertGoogleMessages`) +
///   `generationConfig` (incl. `thinkingConfig`) + `safetySettings`.
///
/// Behaviours:
/// - Message shaping matches SillyTavern's `convertGooglePrompt`: only the
///   leading run of genuine `system` messages is lifted into
///   `systemInstruction` (one part each), everything else keeps its place and
///   consecutive same-role turns are squashed inside `contents`.
/// - Safety settings: all five HARM_* categories set to `OFF`.
/// - Extended thinking: `generationConfig.thinkingConfig.thinkingBudget`
///   (int) or `.thinkingLevel` (string for Gemini 3) per
///   `calculateGoogleBudgetTokens`. `includeThoughts: true` so the response
///   stream interleaves thinking parts.
class GeminiChatTransport implements ChatTransport {
  static const String _apiVersion = 'v1beta';

  static const List<Map<String, String>> _safetyAllOff = [
    {'category': 'HARM_CATEGORY_HARASSMENT', 'threshold': 'OFF'},
    {'category': 'HARM_CATEGORY_HATE_SPEECH', 'threshold': 'OFF'},
    {'category': 'HARM_CATEGORY_SEXUALLY_EXPLICIT', 'threshold': 'OFF'},
    {'category': 'HARM_CATEGORY_DANGEROUS_CONTENT', 'threshold': 'OFF'},
    {'category': 'HARM_CATEGORY_CIVIC_INTEGRITY', 'threshold': 'OFF'},
  ];

  final Dio _dio;

  /// Number of automatic retries on HTTP 408 (Request Timeout) — common on
  /// mobile networks where the upload is too slow for the provider.
  static const int _maxRetries = 1;

  GeminiChatTransport({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 60),
              receiveTimeout: const Duration(seconds: 180),
            ),
          );

  /// Gemini builds `{base}/v1beta/models/{model}:{action}` itself, so the base
  /// must not carry a version segment — `EndpointNormalizer.geminiBase` strips
  /// one the user may have pasted along with the URL.
  static String _normaliseBase(String endpoint) =>
      EndpointNormalizer.geminiBase(endpoint);

  static String buildGenerateUrl({
    required String endpoint,
    required String model,
    required String apiKey,
    required bool stream,
  }) {
    final base = _normaliseBase(endpoint);
    final responseType = stream ? 'streamGenerateContent' : 'generateContent';
    final params = <String>[
      'key=${Uri.encodeQueryComponent(apiKey)}',
      if (stream) 'alt=sse',
    ];
    return '$base/$_apiVersion/models/$model:$responseType?${params.join('&')}';
  }

  /// Pure: build URL + body + headers from a [ChatTransportRequest]. Exposed
  /// for unit tests.
  static GeminiBuiltRequest buildRequest(ChatTransportRequest request) {
    final converted = convertGoogleMessages(
      request.messages,
      useSystemInstruction: request.useSystemInstruction,
    );

    final generationConfig = <String, dynamic>{'candidateCount': 1};
    if (request.maxTokens > 0) {
      generationConfig['maxOutputTokens'] = request.maxTokens;
    }
    // Gated on the omit* flags only — see the note in
    // `OpenAiChatTransport.buildBody`. topK keeps its `> 0` guard because
    // Gemini rejects `topK: 0`.
    if (!request.omitTemperature) {
      generationConfig['temperature'] = request.temperature;
    }
    if (!request.omitTopP) {
      generationConfig['topP'] = request.topP;
    }
    if (!request.omitTopK && request.topK > 0) {
      generationConfig['topK'] = request.topK;
    }

    // Thinking config: only emit for known 2.5+ / 3.x thinking models.
    final useThinking = request.requestReasoning && !request.omitReasoning;
    if (useThinking && _isThinkingModel(request.model)) {
      final budget = calculateGoogleBudgetTokens(
        maxTokens: request.maxTokens > 0 ? request.maxTokens : 4096,
        reasoningEffort: request.omitReasoningEffort
            ? 'auto'
            : request.reasoningEffort ?? 'auto',
        model: request.model,
      );
      final thinkingConfig = <String, dynamic>{'includeThoughts': true};
      if (budget is int) {
        thinkingConfig['thinkingBudget'] = budget;
      } else if (budget is String && budget.isNotEmpty) {
        thinkingConfig['thinkingLevel'] = budget;
      }
      generationConfig['thinkingConfig'] = thinkingConfig;
    }

    final body = <String, dynamic>{
      'contents': converted.contents,
      'safetySettings': _safetyAllOff,
      'generationConfig': generationConfig,
    };
    if (converted.hasSystemInstruction) {
      body['systemInstruction'] = converted.systemInstruction;
    }
    if (request.sessionIdMode == 'always' &&
        request.sessionId != null &&
        request.sessionId!.isNotEmpty) {
      body['session_id'] = request.sessionId;
    }
    applyExtraRequestParameters(body, request.extraRequestParameters);

    final url = buildGenerateUrl(
      endpoint: request.endpoint,
      model: request.model,
      apiKey: request.apiKey,
      stream: request.stream,
    );

    return GeminiBuiltRequest(
      url: url,
      body: body,
      headers: const {'Content-Type': 'application/json'},
    );
  }

  static bool _isThinkingModel(String model) {
    return RegExp(r'^gemini-2\.5-(flash|pro)').hasMatch(model) ||
        RegExp(r'^gemini-3[\.\d]*-(flash|pro)').hasMatch(model);
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
      onError?.call(Exception('Gemini API key is empty'));
      return;
    }

    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        final built = buildRequest(request);
        if (request.stream) {
          await _streamResponse(
            built.url,
            built.headers,
            built.body,
            cancelToken: cancelToken,
            onUpdate: onUpdate,
            onComplete: onComplete,
            omitReasoning:
                !(request.showNativeReasoning ?? !request.omitReasoning),
            receiveTimeoutMs: request.receiveTimeoutMs,
          );
        } else {
          await _oneShotResponse(
            built.url,
            built.headers,
            built.body,
            cancelToken: cancelToken,
            onComplete: onComplete,
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
            '[Gemini] HTTP 408 on attempt ${attempt + 1}/$_maxRetries — retrying',
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

  Future<void> _streamResponse(
    String url,
    Map<String, String> headers,
    Map<String, dynamic> body, {
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

    var fullText = '';
    var fullReasoning = '';
    Map<String, dynamic>? lastUsage;
    String? lastRawPayload;
    var anyDelta = false;

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
          lastRawPayload = payload;

          try {
            final json = jsonDecode(payload) as Map<String, dynamic>;
            final candidates = json['candidates'];
            if (candidates is List && candidates.isNotEmpty) {
              final content = candidates[0]['content'];
              final parts = content is Map ? content['parts'] : null;
              if (parts is List) {
                for (final p in parts) {
                  if (p is! Map) continue;
                  final text = p['text'];
                  if (text is! String || text.isEmpty) continue;
                  final isThought = p['thought'] == true;
                  // When omitReasoning is set, discard thought parts entirely
                  // so StreamAccumulator's _hasExternalReasoning stays false
                  // and inline  parsing is not suppressed.
                  if (isThought && omitReasoning) continue;
                  if (isThought) {
                    fullReasoning += text;
                    onUpdate?.call('', text);
                  } else {
                    fullText += text;
                    onUpdate?.call(text, null);
                  }
                  anyDelta = true;
                }
              }
            }
            final usage = json['usageMetadata'];
            if (usage is Map<String, dynamic>) lastUsage = usage;
          } catch (_) {
            // Skip malformed chunk.
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

    if (!anyDelta && fullText.isEmpty && fullReasoning.isEmpty) {
      throw DioException(
        requestOptions: RequestOptions(path: url),
        message: 'Gemini stream produced no content',
        type: DioExceptionType.connectionError,
      );
    }

    onComplete?.call(
      fullText,
      fullReasoning.isEmpty ? null : fullReasoning,
      rawResponseJson: _buildAggregatedRaw(
        fullText: fullText,
        fullReasoning: fullReasoning,
        usage: lastUsage,
        lastPayload: lastRawPayload,
      ),
    );
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
        type: DioExceptionType.badResponse,
        message: 'Unexpected Gemini response body (${raw.runtimeType})',
      );
    }

    final candidates = data['candidates'];
    final textBuf = StringBuffer();
    final reasoningBuf = StringBuffer();
    if (candidates is List && candidates.isNotEmpty) {
      final content = candidates[0]['content'];
      final parts = content is Map ? content['parts'] : null;
      if (parts is List) {
        for (final p in parts) {
          if (p is! Map) continue;
          final text = p['text'];
          if (text is! String) continue;
          if (p['thought'] == true) {
            if (omitReasoning) continue;
            reasoningBuf.write(text);
          } else {
            textBuf.write(text);
          }
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
    final base = _normaliseBase(endpoint);
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$base/$_apiVersion/models'
        '?key=${Uri.encodeQueryComponent(apiKey)}',
      );
      final models = response.data?['models'] as List?;
      if (models == null) return const [];
      // Normalize to OpenAI-compatible shape `{id: ...}` so the UI picker
      // can render without per-protocol branches.
      return models.map<Map<String, dynamic>>((m) {
        final map = m is Map<String, dynamic> ? m : <String, dynamic>{};
        final name = map['name'];
        // Anthropic-style id stripping: "models/gemini-…" → "gemini-…".
        final id = name is String && name.startsWith('models/')
            ? name.substring('models/'.length)
            : name;
        return <String, dynamic>{'id': id, ...map};
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  String _buildAggregatedRaw({
    required String fullText,
    required String fullReasoning,
    Map<String, dynamic>? usage,
    String? lastPayload,
  }) {
    final parts = <Map<String, dynamic>>[
      if (fullReasoning.isNotEmpty) {'text': fullReasoning, 'thought': true},
      {'text': fullText},
    ];
    return jsonEncode({
      'candidates': [
        {
          'content': {'role': 'model', 'parts': parts},
          'finishReason': 'STOP',
        },
      ],
      'usageMetadata': ?usage,
      'last_event': ?lastPayload,
    });
  }
}
