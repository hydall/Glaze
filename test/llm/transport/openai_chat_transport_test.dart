import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/openai_chat_transport.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';

ChatTransportRequest _req({
  String endpoint = 'https://api.openai.com',
  String sessionIdMode = 'openrouter',
  int? receiveTimeoutMs,
  int topK = 0,
  double frequencyPenalty = 0,
  double presencePenalty = 0,
  bool omitTopK = false,
  bool omitFrequencyPenalty = false,
  bool omitPresencePenalty = false,
  List<Map<String, dynamic>> messages = const [
    {'role': 'user', 'content': 'hi'},
  ],
  List<ExtraRequestParameter> extraRequestParameters = const [],
}) {
  return ChatTransportRequest(
    endpoint: endpoint,
    apiKey: 'sk-test',
    model: 'gpt-test',
    messages: messages,
    maxTokens: 100,
    temperature: 0.7,
    topP: 0.9,
    topK: topK,
    frequencyPenalty: frequencyPenalty,
    presencePenalty: presencePenalty,
    omitTopK: omitTopK,
    omitFrequencyPenalty: omitFrequencyPenalty,
    omitPresencePenalty: omitPresencePenalty,
    sessionId: 'sess-1',
    sessionIdMode: sessionIdMode,
    receiveTimeoutMs: receiveTimeoutMs,
    extraRequestParameters: extraRequestParameters,
  );
}

class _RecordingAdapter implements HttpClientAdapter {
  RequestOptions? options;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    this.options = options;
    return ResponseBody.fromBytes(
      utf8.encode('{"choices":[{"message":{"content":"ok"}}]}'),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('per-request zero disables the default receive timeout', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio(BaseOptions(receiveTimeout: const Duration(seconds: 120)))
      ..httpClientAdapter = adapter;
    final transport = OpenAiChatTransport(dio: dio);

    await transport.stream(
      request: _req(receiveTimeoutMs: 0),
      onComplete: (_, _, {rawResponseJson}) {},
    );

    expect(adapter.options?.receiveTimeout, Duration.zero);
  });

  group('session_id', () {
    test('openrouter mode only sends session_id to OpenRouter', () {
      final openRouter = OpenAiChatTransport.buildBody(
        _req(endpoint: 'https://openrouter.ai/api/v1'),
      );
      final openAi = OpenAiChatTransport.buildBody(_req());

      expect(openRouter['session_id'], 'sess-1');
      expect(openAi.containsKey('session_id'), isFalse);
    });

    test('always mode sends session_id to any endpoint', () {
      final body = OpenAiChatTransport.buildBody(_req(sessionIdMode: 'always'));

      expect(body['session_id'], 'sess-1');
    });

    test('off mode never sends session_id', () {
      final body = OpenAiChatTransport.buildBody(
        _req(endpoint: 'https://openrouter.ai/api/v1', sessionIdMode: 'off'),
      );

      expect(body.containsKey('session_id'), isFalse);
    });
  });

  test('sampling omit flags remove top K and penalties', () {
    final included = OpenAiChatTransport.buildBody(
      _req(topK: 40, frequencyPenalty: 0.5, presencePenalty: -0.5),
    );
    final omitted = OpenAiChatTransport.buildBody(
      _req(
        topK: 40,
        frequencyPenalty: 0.5,
        presencePenalty: -0.5,
        omitTopK: true,
        omitFrequencyPenalty: true,
        omitPresencePenalty: true,
      ),
    );

    expect(included, containsPair('top_k', 40));
    expect(included, containsPair('frequency_penalty', 0.5));
    expect(included, containsPair('presence_penalty', -0.5));
    expect(omitted, isNot(contains('top_k')));
    expect(omitted, isNot(contains('frequency_penalty')));
    expect(omitted, isNot(contains('presence_penalty')));
  });

  test('preserves reasoning content in historical assistant messages', () {
    final body = OpenAiChatTransport.buildBody(
      _req(
        messages: const [
          {'role': 'user', 'content': 'first'},
          {
            'role': 'assistant',
            'reasoning_content': 'private plan',
            'content': 'answer',
          },
          {'role': 'user', 'content': 'follow-up'},
        ],
      ),
    );

    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    expect(messages[1]['reasoning_content'], 'private plan');
    expect(messages[1]['content'], 'answer');
  });

  group('extra request parameters', () {
    test('adds enabled values and parses valid JSON', () {
      final body = OpenAiChatTransport.buildBody(
        _req(
          extraRequestParameters: const [
            ExtraRequestParameter(key: 'reasoning_effort', value: 'xhigh'),
            ExtraRequestParameter(key: 'seed', value: '42'),
            ExtraRequestParameter(key: 'metadata', value: '{"source":"test"}'),
            ExtraRequestParameter(
              key: 'disabled',
              value: 'true',
              enabled: false,
            ),
          ],
        ),
      );

      expect(body['reasoning_effort'], 'xhigh');
      expect(body['seed'], 42);
      expect(body['metadata'], {'source': 'test'});
      expect(body, isNot(contains('disabled')));
    });

    test('does not override structural request fields', () {
      final body = OpenAiChatTransport.buildBody(
        _req(
          extraRequestParameters: const [
            ExtraRequestParameter(key: 'model', value: 'hijacked'),
            ExtraRequestParameter(key: 'stream', value: 'false'),
            ExtraRequestParameter(key: 'messages', value: '[]'),
          ],
        ),
      );

      expect(body['model'], 'gpt-test');
      expect(body['stream'], isTrue);
      expect(body['messages'], isNotEmpty);
    });
  });
}
