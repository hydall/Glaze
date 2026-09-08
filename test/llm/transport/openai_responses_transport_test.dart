import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/openai_responses_transport.dart';

import '_sse_adapter.dart';

ChatTransportRequest _request({bool stream = true}) => ChatTransportRequest(
  endpoint: 'https://api.rout.my/v1/chat/completions',
  apiKey: 'test-key',
  model: 'openai/gpt-5.6-sol',
  messages: const [
    {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'Describe this'},
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/png;base64,AA=='},
        },
      ],
    },
  ],
  maxTokens: 500,
  temperature: 0.7,
  topP: 0.9,
  stream: stream,
  requestReasoning: true,
  reasoningEffort: 'high',
  showNativeReasoning: true,
  useResponsesApi: true,
);

class _JsonAdapter implements HttpClientAdapter {
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromBytes(
      utf8.encode(
        jsonEncode({
          'output': [
            {
              'type': 'reasoning',
              'summary': [
                {'type': 'summary_text', 'text': 'Checked the image.'},
              ],
            },
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'A city at night.'},
              ],
            },
          ],
        }),
      ),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeTransport implements ChatTransport {
  var calls = 0;

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    calls++;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async => [];
}

void main() {
  test('builds Responses URL and converts multimodal input', () {
    final body = OpenAiResponsesTransport.buildBody(_request());

    expect(
      OpenAiResponsesTransport.buildResponsesUrl(
        'https://api.rout.my/v1/chat/completions',
      ),
      'https://api.rout.my/v1/responses',
    );
    expect(body['max_output_tokens'], 500);
    expect(body['reasoning'], {'summary': 'auto', 'effort': 'high'});
    expect(body['input'], [
      {
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': 'Describe this'},
          {'type': 'input_image', 'image_url': 'data:image/png;base64,AA=='},
        ],
      },
    ]);
  });

  test('parses streamed output text and reasoning summary', () async {
    const sse = '''
data: {"type":"response.reasoning_summary_text.delta","delta":"Checked "}

data: {"type":"response.reasoning_summary_text.delta","delta":"carefully."}

data: {"type":"response.output_text.delta","delta":"Answer"}

data: {"type":"response.completed","response":{"id":"resp_1"}}

''';
    final dio = Dio()..httpClientAdapter = SseAdapter(sse);
    final transport = OpenAiResponsesTransport(dio: dio);
    String? text;
    String? reasoning;

    await transport.stream(
      request: _request(),
      onComplete: (value, reason, {rawResponseJson}) {
        text = value;
        reasoning = reason;
      },
    );

    expect(text, 'Answer');
    expect(reasoning, 'Checked carefully.');
  });

  test('parses one-shot output and sends request to /responses', () async {
    final adapter = _JsonAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final transport = OpenAiResponsesTransport(dio: dio);
    String? text;
    String? reasoning;

    await transport.stream(
      request: _request(stream: false),
      onComplete: (value, reason, {rawResponseJson}) {
        text = value;
        reasoning = reason;
      },
    );

    expect(adapter.request?.uri.path, '/v1/responses');
    expect(text, 'A city at night.');
    expect(reasoning, 'Checked the image.');
  });

  test('router keeps Chat Completions as the default', () async {
    final chat = _FakeTransport();
    final responses = _FakeTransport();
    final transport = OpenAiCompatibleTransport(
      chatCompletions: chat,
      responses: responses,
    );

    await transport.stream(
      request: ChatTransportRequest(
        endpoint: 'https://example.com/v1',
        apiKey: 'key',
        model: 'model',
        messages: const [],
        maxTokens: 1,
        temperature: 0,
        topP: 1,
      ),
    );
    await transport.stream(request: _request());

    expect(chat.calls, 1);
    expect(responses.calls, 1);
  });
}
