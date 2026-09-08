import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/agent_runner.dart';
import 'package:glaze_flutter/core/llm/agent_stream_runner.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

class _FakeTransport implements ChatTransport {
  _FakeTransport({this.delay, this.waitForCancellation = false});

  final Duration? delay;
  final bool waitForCancellation;
  ChatTransportRequest? request;
  bool cancelled = false;

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    this.request = request;
    if (waitForCancellation) {
      await cancelToken!.whenCancel;
      cancelled = true;
      return;
    }
    await Future<void>.delayed(delay!);
    onComplete?.call('complete response', null);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async => const [];
}

const _agent = StudioAgent(id: 'final', name: 'Final');
const _resolved = ResolvedAgentConfig(
  endpoint: 'https://example.com',
  apiKey: 'key',
  model: 'model',
  protocol: 'openai',
  stream: false,
);

void main() {
  test(
    'non-streaming response can complete within configured timeout',
    () async {
      final transport = _FakeTransport(delay: const Duration(milliseconds: 30));
      final runner = AgentStreamRunner((_) => transport);

      final result = await runner.run(
        agent: _agent,
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        resolved: _resolved,
        sessionId: 'session',
        isFinalResponse: true,
        cancelToken: CancelToken(),
        timeoutMs: 100,
      );

      expect(result.text, 'complete response');
      expect(transport.request?.receiveTimeoutMs, 0);
    },
  );

  test('timeout cancels the in-flight transport request', () async {
    final transport = _FakeTransport(waitForCancellation: true);
    final runner = AgentStreamRunner((_) => transport);

    await expectLater(
      runner.run(
        agent: _agent,
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        resolved: _resolved,
        sessionId: 'session',
        isFinalResponse: true,
        cancelToken: CancelToken(),
        timeoutMs: 20,
      ),
      throwsA(isA<TimeoutException>()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(transport.cancelled, isTrue);
  });
}
