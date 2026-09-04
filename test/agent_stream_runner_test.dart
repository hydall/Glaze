import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/agent_runner.dart';
import 'package:glaze_flutter/core/llm/agent_stream_runner.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

class _FakeTransport implements ChatTransport {
  _FakeTransport({
    this.delay,
    this.waitForCancellation = false,
    this.completedText = 'complete response',
    this.completedReasoning,
  });

  final Duration? delay;
  final bool waitForCancellation;
  final String completedText;
  final String? completedReasoning;
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
    onComplete?.call(completedText, completedReasoning);
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
  test('pure request builder matches the request sent by run', () async {
    final transport = _FakeTransport(delay: Duration.zero);
    final runner = AgentStreamRunner((_) => transport);
    const agent = StudioAgent(id: 'agent', controllerId: 'agency');
    const resolved = ResolvedAgentConfig(
      endpoint: 'https://example.test',
      apiKey: 'key',
      model: 'model',
      protocol: 'openai',
      stream: false,
    );
    const messages = [
      {'role': 'user', 'content': 'hello'},
    ];
    final expected = AgentStreamRunner.buildRequest(
      agent: agent,
      messages: messages,
      resolved: resolved,
      sessionId: 'session',
      isFinalResponse: false,
      maxTokensOverride: 321,
      temperatureOverride: 0.4,
    );

    await runner.run(
      agent: agent,
      messages: messages,
      resolved: resolved,
      sessionId: 'session',
      isFinalResponse: false,
      cancelToken: CancelToken(),
      timeoutMs: 1000,
      maxTokensOverride: 321,
      temperatureOverride: 0.4,
    );

    expect(transport.request?.messages, expected.messages);
    expect(transport.request?.maxTokens, expected.maxTokens);
    expect(transport.request?.temperature, expected.temperature);
    expect(
      transport.request?.captureContext?.toJson(),
      expected.captureContext?.toJson(),
    );
  });

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
        charName: 'Character',
        userName: 'User',
      );

      expect(result.text, 'complete response');
      expect(transport.request?.receiveTimeoutMs, 0);
      expect(transport.request?.charName, 'Character');
      expect(transport.request?.userName, 'User');
      expect(transport.request?.captureContext?.stage, 'studio.final');
      expect(transport.request?.captureContext?.sessionId, 'session');
      expect(transport.request?.captureContext?.agentId, 'final');
    },
  );

  test('final request preserves configured inline reasoning tags', () {
    const messages = [
      {
        'role': 'system',
        'content': 'Use <think>reasoning</think> before the response.',
      },
    ];

    final request = AgentStreamRunner.buildRequest(
      agent: _agent,
      messages: messages,
      resolved: const ResolvedAgentConfig(
        endpoint: 'https://example.com',
        apiKey: 'key',
        model: 'model',
        protocol: 'custom_chat_completion',
        requestReasoning: false,
        omitReasoning: true,
        reasoningTagStart: '<think>',
        reasoningTagEnd: '</think>',
      ),
      sessionId: 'session',
      isFinalResponse: true,
    );

    expect(request.messages, messages);
    expect(request.messages.single['content'], contains('<think>'));
    expect(request.messages.single['content'], isNot(contains('hidden reasoning')));
  });

  test('final request still neutralizes think tags without a configured pair', () {
    final request = AgentStreamRunner.buildRequest(
      agent: _agent,
      messages: const [
        {
          'role': 'system',
          'content': 'Use <think>reasoning</think> before the response.',
        },
      ],
      resolved: _resolved,
      sessionId: 'session',
      isFinalResponse: true,
    );

    expect(request.messages.single['content'], contains('hidden reasoning'));
    expect(request.messages.single['content'], isNot(contains('<think>')));
  });

  test(
    'non-streaming inline reasoning tags are split out of the reply',
    () async {
      final transport = _FakeTransport(
        delay: Duration.zero,
        completedText: '<audit>step analysis</audit>actual reply',
        completedReasoning: null,
      );
      final runner = AgentStreamRunner((_) => transport);

      final result = await runner.run(
        agent: _agent,
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        resolved: const ResolvedAgentConfig(
          endpoint: 'https://example.com',
          apiKey: 'key',
          model: 'model',
          protocol: 'custom_chat_completion',
          stream: false,
          reasoningTagStart: '<audit>',
          reasoningTagEnd: '</audit>',
        ),
        sessionId: 'session',
        isFinalResponse: true,
        cancelToken: CancelToken(),
        timeoutMs: 100,
        tagStart: '<audit>',
        tagEnd: '</audit>',
      );

      expect(result.text, 'actual reply');
      expect(result.reasoning, 'step analysis');
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
