import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../utils/error_format.dart';
import 'chat_transport.dart';
import 'chat_transport_request.dart';
import 'extra_request_parameters.dart';
import 'openai_chat_transport.dart';

/// Opt-in OpenAI Responses API transport. Existing OpenAI-compatible presets
/// continue to use Chat Completions unless [ChatTransportRequest.useResponsesApi]
/// is enabled.
class OpenAiResponsesTransport implements ChatTransport {
  final Dio _dio;

  OpenAiResponsesTransport({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 60),
              receiveTimeout: const Duration(seconds: 120),
            ),
          );

  static String buildResponsesUrl(String endpoint) {
    var base = OpenAiChatTransport.normalizeEndpoint(endpoint);
    final lower = base.toLowerCase();
    if (lower.endsWith('/chat/completions')) {
      base = base.substring(0, base.length - '/chat/completions'.length);
    } else if (lower.endsWith('/responses')) {
      return base;
    }
    return base.isEmpty ? '' : '$base/responses';
  }

  static Map<String, dynamic> buildBody(ChatTransportRequest request) {
    final body = <String, dynamic>{
      'model': request.model,
      'input': request.messages.map(_convertMessage).toList(growable: false),
      'stream': request.stream,
    };
    if (request.maxTokens > 0) {
      body['max_output_tokens'] = request.maxTokens;
    }

    final showReasoning =
        request.requestReasoning &&
        !request.omitReasoning &&
        (request.showNativeReasoning ?? true);
    if (showReasoning) {
      body['reasoning'] = <String, dynamic>{
        'summary': 'auto',
        if (!request.omitReasoningEffort &&
            request.reasoningEffort != null &&
            request.reasoningEffort != 'auto')
          'effort': request.reasoningEffort,
      };
    }

    final tools = request.tools?.map(_convertTool).toList(growable: false);
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
      body['tool_choice'] = request.toolChoice ?? 'auto';
    }
    applyExtraRequestParameters(body, request.extraRequestParameters);
    return body;
  }

  static Map<String, dynamic> _convertMessage(Map<String, dynamic> message) {
    final content = message['content'];
    return <String, dynamic>{
      'role': message['role'],
      'content': content is List
          ? content.map(_convertContentPart).toList(growable: false)
          : content,
    };
  }

  static dynamic _convertContentPart(dynamic part) {
    if (part is! Map) return part;
    final value = Map<String, dynamic>.from(part);
    if (value['type'] == 'text') {
      return <String, dynamic>{'type': 'input_text', 'text': value['text']};
    }
    if (value['type'] == 'image_url') {
      final imageUrl = value['image_url'];
      final url = imageUrl is Map ? imageUrl['url'] : imageUrl;
      return <String, dynamic>{'type': 'input_image', 'image_url': url};
    }
    return value;
  }

  static Map<String, dynamic> _convertTool(Map<String, dynamic> tool) {
    final function = tool['function'];
    if (tool['type'] != 'function' || function is! Map) return tool;
    return <String, dynamic>{
      'type': 'function',
      'name': function['name'],
      if (function['description'] != null)
        'description': function['description'],
      if (function['parameters'] != null) 'parameters': function['parameters'],
      if (function['strict'] != null) 'strict': function['strict'],
    };
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
    try {
      if (request.stream) {
        await _streamResponse(
          buildResponsesUrl(request.endpoint),
          request,
          cancelToken,
          onUpdate,
          onComplete,
        );
      } else {
        await _oneShotResponse(
          buildResponsesUrl(request.endpoint),
          request,
          cancelToken,
          onComplete,
        );
      }
    } on DioException catch (error) {
      onError?.call(await decodeStreamingError(error));
    } catch (error) {
      onError?.call(error);
    }
  }

  Future<void> _streamResponse(
    String url,
    ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
  ) async {
    final response = await _dio.post<ResponseBody>(
      url,
      data: buildBody(request),
      cancelToken: cancelToken,
      options: Options(
        headers: {
          'Authorization': 'Bearer ${request.apiKey}',
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.stream,
        receiveTimeout: _receiveTimeout(request.receiveTimeoutMs),
      ),
    );
    final responseBody = response.data;
    if (responseBody == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        message: 'Empty Responses stream body',
      );
    }

    var buffer = '';
    var text = '';
    var reasoning = '';
    String? rawResponseJson;
    await for (final chunk in responseBody.stream) {
      if (cancelToken?.isCancelled == true) return;
      buffer += utf8.decode(chunk, allowMalformed: true);
      final lines = buffer.split('\n');
      buffer = lines.removeLast();
      for (final line in lines) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) continue;
        final payload = trimmed.substring(5).trim();
        if (payload.isEmpty || payload == '[DONE]') continue;
        try {
          final event = jsonDecode(payload) as Map<String, dynamic>;
          final type = event['type'];
          if (type == 'response.output_text.delta') {
            final delta = event['delta'];
            if (delta is String && delta.isNotEmpty) {
              text += delta;
              onUpdate?.call(delta, null);
            }
          } else if (type == 'response.reasoning_summary_text.delta') {
            final delta = event['delta'];
            if (delta is String && delta.isNotEmpty) {
              reasoning += delta;
              onUpdate?.call('', delta);
            }
          } else if (type == 'response.completed') {
            final completed = event['response'];
            rawResponseJson = jsonEncode(completed ?? event);
          }
        } catch (_) {}
      }
    }
    if (cancelToken?.isCancelled == true) return;
    if (text.isEmpty && reasoning.isEmpty) {
      throw DioException(
        requestOptions: response.requestOptions,
        type: DioExceptionType.connectionError,
        message: 'Responses stream ended without output',
      );
    }
    onComplete?.call(
      text,
      reasoning.isEmpty ? null : reasoning,
      rawResponseJson:
          rawResponseJson ?? jsonEncode(_aggregatedResponse(text, reasoning)),
    );
  }

  Future<void> _oneShotResponse(
    String url,
    ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnComplete? onComplete,
  ) async {
    final response = await _dio.post<dynamic>(
      url,
      data: buildBody(request),
      cancelToken: cancelToken,
      options: Options(
        headers: {
          'Authorization': 'Bearer ${request.apiKey}',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        receiveTimeout: _receiveTimeout(request.receiveTimeoutMs),
      ),
    );
    final raw = response.data;
    final data = raw is Map<String, dynamic>
        ? raw
        : jsonDecode(raw as String) as Map<String, dynamic>;
    final parsed = _parseOutput(data);
    onComplete?.call(
      parsed.$1,
      parsed.$2.isEmpty ? null : parsed.$2,
      rawResponseJson: jsonEncode(data),
    );
  }

  static (String, String) _parseOutput(Map<String, dynamic> response) {
    var text = '';
    var reasoning = '';
    for (final item in (response['output'] as List? ?? const [])) {
      if (item is! Map) continue;
      if (item['type'] == 'message') {
        for (final part in (item['content'] as List? ?? const [])) {
          if (part is Map && part['type'] == 'output_text') {
            final value = part['text'];
            if (value is String) text += value;
          }
        }
      } else if (item['type'] == 'reasoning') {
        for (final part in (item['summary'] as List? ?? const [])) {
          if (part is Map && part['type'] == 'summary_text') {
            final value = part['text'];
            if (value is String) reasoning += value;
          }
        }
      }
    }
    return (text, reasoning);
  }

  static Map<String, dynamic> _aggregatedResponse(
    String text,
    String reasoning,
  ) => <String, dynamic>{
    'object': 'response',
    'output': [
      if (reasoning.isNotEmpty)
        {
          'type': 'reasoning',
          'summary': [
            {'type': 'summary_text', 'text': reasoning},
          ],
        },
      {
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'output_text', 'text': text},
        ],
      },
    ],
  };

  Duration? _receiveTimeout(int? timeoutMs) =>
      timeoutMs == null ? null : Duration(milliseconds: timeoutMs);

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) => OpenAiChatTransport(
    dio: _dio,
  ).fetchModels(endpoint: endpoint, apiKey: apiKey);
}

/// Routes each OpenAI-compatible request without changing existing presets.
class OpenAiCompatibleTransport implements ChatTransport {
  final ChatTransport chatCompletions;
  final ChatTransport responses;

  OpenAiCompatibleTransport({
    ChatTransport? chatCompletions,
    ChatTransport? responses,
  }) : chatCompletions = chatCompletions ?? OpenAiChatTransport(),
       responses = responses ?? OpenAiResponsesTransport();

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) => (request.useResponsesApi ? responses : chatCompletions).stream(
    request: request,
    cancelToken: cancelToken,
    onUpdate: onUpdate,
    onComplete: onComplete,
    onError: onError,
  );

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) => chatCompletions.fetchModels(endpoint: endpoint, apiKey: apiKey);
}
