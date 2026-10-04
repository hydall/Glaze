import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/converters/prompt_post_processing.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_dump.dart';
import 'package:glaze_flutter/core/llm/transport/openrouter_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/post_processing_chat_transport.dart';

class _RecordingSink implements LlmRequestCaptureSink {
  final events = <LlmRequestCaptureEvent>[];

  @override
  void record(LlmRequestCaptureEvent event) => events.add(event);
}

class _ThrowingSink implements LlmRequestCaptureSink {
  @override
  void record(LlmRequestCaptureEvent event) => throw StateError('broken sink');
}

class _CompletingTransport implements ChatTransport {
  ChatTransportRequest? request;

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    this.request = request;
    onComplete?.call('ok', null);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async => const [];
}

ChatTransportRequest _request({Object? content = 'hello'}) =>
    ChatTransportRequest(
      endpoint: 'https://example.test/v1?secret=query-value',
      apiKey: 'super-secret-key',
      model: 'model',
      messages: [
        {'role': 'user', 'content': content},
      ],
      maxTokens: 20,
      temperature: 0.2,
      topP: 1,
      captureContext: const LlmCaptureContext(
        stage: 'ledger.reconcile',
        sessionId: 'session-1',
        logicalCallId: 'call-1',
      ),
    );

void main() {
  tearDown(() {
    LlmRequestCapture.sink = null;
    LlmRequestDump.enabled = false;
  });

  test('captures one sanitized event and never includes credentials', () async {
    final sink = _RecordingSink();
    final inner = _CompletingTransport();
    LlmRequestCapture.sink = sink;

    await LoggingChatTransport(
      inner,
      label: 'openai',
    ).stream(request: _request());

    expect(sink.events, hasLength(1));
    final json = sink.events.single.toJson();
    expect(json['protocol'], 'openai');
    expect(json['protocolEndpoint'], 'https://example.test/v1');
    expect(json['context'], containsPair('stage', 'ledger.reconcile'));
    expect(json.toString(), isNot(contains('super-secret-key')));
    expect(json.toString(), isNot(contains('query-value')));
  });

  test('redacts large data URIs and marks the event truncated', () {
    final event = LlmRequestCapture.build(
      _request(content: 'data:image/png;base64,${'a' * 200}'),
    );

    expect(event.truncated, isTrue);
    expect(event.toJson().toString(), contains('redacted_data_uri'));
    expect(event.toJson().toString(), isNot(contains('a' * 100)));
  });

  test('pure sanitization never dispatches a capture event', () {
    final sink = _RecordingSink();
    LlmRequestCapture.sink = sink;

    final sanitized = LlmRequestCapture.sanitizeRequest(_request());

    expect(sanitized.request['protocolEndpoint'], 'https://example.test/v1');
    expect(sanitized.request.toString(), isNot(contains('super-secret-key')));
    expect(sink.events, isEmpty);
  });

  test('sink failure never prevents the provider call', () async {
    final inner = _CompletingTransport();
    LlmRequestCapture.sink = _ThrowingSink();

    await LoggingChatTransport(inner).stream(request: _request());

    expect(inner.request, isNotNull);
  });

  test('request rewrites preserve diagnostic context', () {
    final request = _request();

    expect(
      request.withMessages(const []).captureContext,
      request.captureContext,
    );
    expect(
      PostProcessingChatTransport.applyTo(request).captureContext,
      request.captureContext,
    );
    expect(
      OpenRouterChatTransport.buildRouterRequest(request).captureContext,
      request.captureContext,
    );
  });

  test('factory ordering captures post-processed messages', () async {
    final sink = _RecordingSink();
    final inner = _CompletingTransport();
    LlmRequestCapture.sink = sink;
    final transport = PostProcessingChatTransport(
      LoggingChatTransport(inner, label: 'openai'),
    );
    final request = ChatTransportRequest(
      endpoint: 'https://example.test',
      apiKey: 'key',
      model: 'model',
      messages: const [
        {'role': 'user', 'content': 'one'},
        {'role': 'user', 'content': 'two'},
      ],
      maxTokens: 20,
      temperature: 0.2,
      topP: 1,
      promptPostProcessing: PromptPostProcessing.merge,
    );

    await transport.stream(request: request);

    expect(sink.events.single.request['messageCount'], 1);
    expect(inner.request?.messages, hasLength(1));
  });
}
