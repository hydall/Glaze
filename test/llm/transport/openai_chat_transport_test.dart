import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/openai_chat_transport.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';

import '_sse_adapter.dart';

ChatTransportRequest _req({
  String endpoint = 'https://api.openai.com',
  String sessionIdMode = 'openrouter',
  int? receiveTimeoutMs,
  int maxTokens = 100,
  int topK = 0,
  double frequencyPenalty = 0,
  double presencePenalty = 0,
  bool omitTopK = false,
  bool omitFrequencyPenalty = false,
  bool omitPresencePenalty = false,
  bool requestReasoning = false,
  String reasoningEffort = 'medium',
  List<Map<String, dynamic>> messages = const [
    {'role': 'user', 'content': 'hi'},
  ],
  List<ExtraRequestParameter> extraRequestParameters = const [],
  Map<String, dynamic>? responseJsonSchema,
}) {
  return ChatTransportRequest(
    endpoint: endpoint,
    apiKey: 'sk-test',
    model: 'gpt-test',
    messages: messages,
    maxTokens: maxTokens,
    temperature: 0.7,
    topP: 0.9,
    topK: topK,
    frequencyPenalty: frequencyPenalty,
    presencePenalty: presencePenalty,
    omitTopK: omitTopK,
    omitFrequencyPenalty: omitFrequencyPenalty,
    omitPresencePenalty: omitPresencePenalty,
    requestReasoning: requestReasoning,
    reasoningEffort: reasoningEffort,
    sessionId: 'sess-1',
    sessionIdMode: sessionIdMode,
    receiveTimeoutMs: receiveTimeoutMs,
    responseJsonSchema: responseJsonSchema,
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
  test('zero max tokens leaves only an explicit completion limit', () {
    final body = OpenAiChatTransport.buildBody(
      _req(
        maxTokens: 0,
        extraRequestParameters: const [
          ExtraRequestParameter(key: 'max_completion_tokens', value: '8000'),
        ],
      ),
    );

    expect(body.containsKey('max_tokens'), isFalse);
    expect(body['max_completion_tokens'], 8000);
  });

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

  test('official OpenAI caps maximum reasoning effort at high', () {
    final body = OpenAiChatTransport.buildBody(
      _req(requestReasoning: true, reasoningEffort: 'max'),
    );

    expect(body['reasoning_effort'], 'high');
  });

  test('Custom Chat Completion sends maximum reasoning effort as max', () {
    final body = OpenAiChatTransport.buildBody(
      _req(requestReasoning: true, reasoningEffort: 'max'),
      protocol: LlmProtocol.customChatCompletion,
    );

    expect(body['reasoning_effort'], 'max');
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

  test('preserves newlines split across SSE network chunks', () async {
    const body = '''data:{"choices":[{"delta":{"content":"first\\n"}}]}

data: {"choices":[{"delta":{"content":"\\nsecond"}}]}

data: [DONE]

''';
    final bodyBytes = utf8.encode(body);
    final firstNewline = bodyBytes.indexOf(0x0a);
    final dio = Dio()
      ..httpClientAdapter = SseAdapter(
        body,
        chunkSizes: [firstNewline + 1, 1, 2],
      );
    final updates = <String>[];
    String? completed;

    await OpenAiChatTransport(dio: dio).stream(
      request: _req(),
      onUpdate: (delta, _) => updates.add(delta),
      onComplete: (text, _, {rawResponseJson}) => completed = text,
    );

    expect(updates, ['first\n', '\nsecond']);
    expect(completed, 'first\n\nsecond');
  });

  test(
    'preserves UTF-8 text and newlines split across network chunks',
    () async {
      const body = '''data: {"choices":[{"delta":{"content":"Привет\\n"}}]}

data: {"choices":[{"delta":{"content":"\\nмир"}}]}

data: [DONE]

''';
      final bytes = utf8.encode(body);
      final splitInsideFirstRussianCharacter =
          bytes.indexOf(utf8.encode('П').first) + 1;
      final dio = Dio()
        ..httpClientAdapter = SseAdapter(
          body,
          chunkSizes: [splitInsideFirstRussianCharacter, 1, 2, 3],
        );
      String? completed;

      await OpenAiChatTransport(dio: dio).stream(
        request: _req(),
        onComplete: (text, _, {rawResponseJson}) => completed = text,
      );

      expect(completed, 'Привет\n\nмир');
    },
  );

  test('responseJsonSchema emits a strict json_schema response_format', () {
    final body = OpenAiChatTransport.buildBody(
      _req(
        responseJsonSchema: const {
          'type': 'object',
          'properties': {
            'prefix': {
              'type': 'string',
              'enum': ['<thinking>'],
            },
            'content': {'type': 'string'},
          },
          'required': ['prefix', 'content'],
          'additionalProperties': false,
        },
      ),
    );

    expect(body['response_format'], {
      'type': 'json_schema',
      'json_schema': {
        'name': 'glaze_prefill_response',
        'strict': true,
        'schema': {
          'type': 'object',
          'properties': {
            'prefix': {
              'type': 'string',
              'enum': ['<thinking>'],
            },
            'content': {'type': 'string'},
          },
          'required': ['prefix', 'content'],
          'additionalProperties': false,
        },
      },
    });
  });

  test('no response_format is emitted without responseJsonSchema', () {
    final body = OpenAiChatTransport.buildBody(_req());
    expect(body.containsKey('response_format'), isFalse);
  });
}
