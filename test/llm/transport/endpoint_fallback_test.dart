import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/openai_chat_transport.dart';

/// Answers only for [servedUrl]; every other URL 404s the way a provider does
/// when the base path is wrong. Records what was tried, in order.
class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter({this.servedUrl});

  final String? servedUrl;
  final List<String> requested = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requested.add(url);
    if (url != servedUrl) {
      return ResponseBody.fromBytes(
        utf8.encode(jsonEncode({'error': 'no such route: $url'})),
        404,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromBytes(
      utf8.encode(
        jsonEncode({
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': 'pong'},
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

ChatTransportRequest _req(String endpoint) => ChatTransportRequest(
  endpoint: endpoint,
  apiKey: 'sk-test',
  model: 'gpt-test',
  messages: const [
    {'role': 'user', 'content': 'ping'},
  ],
  maxTokens: 16,
  temperature: 0.7,
  topP: 0.9,
  stream: false,
);

void main() {
  test('uses the persisted endpoint without appending a route', () async {
    final adapter = _RoutingAdapter(
      servedUrl: 'https://proxy.tld/chat/completions',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final transport = OpenAiChatTransport(dio: dio);

    String? completed;
    Object? failed;
    await transport.stream(
      request: _req('https://proxy.tld/chat/completions'),
      onComplete: (text, _, {rawResponseJson}) => completed = text,
      onError: (e) => failed = e,
    );

    expect(failed, isNull);
    expect(completed, 'pong');
    expect(adapter.requested, ['https://proxy.tld/chat/completions']);
  });

  test('does not probe alternative endpoints after a 404', () async {
    final adapter = _RoutingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final transport = OpenAiChatTransport(dio: dio);

    Object? failed;
    await transport.stream(
      request: _req('https://proxy.tld/chat/completions'),
      onError: (error) => failed = error,
    );

    expect(adapter.requested, ['https://proxy.tld/chat/completions']);
    expect(failed, isA<DioException>());
  });

  test('an unparseable endpoint fails without any request', () async {
    final adapter = _RoutingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final transport = OpenAiChatTransport(dio: dio);

    Object? failed;
    await transport.stream(
      request: _req('not a url'),
      onError: (e) => failed = e,
    );

    expect(adapter.requested, isEmpty);
    expect(failed, isNotNull);
  });
}
