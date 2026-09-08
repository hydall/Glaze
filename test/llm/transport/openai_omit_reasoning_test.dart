import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/openai_chat_transport.dart';

import '_sse_adapter.dart';

ChatTransportRequest _req({
  required bool stream,
  bool omitReasoning = false,
  bool? showNativeReasoning,
}) => ChatTransportRequest(
  endpoint: 'https://api.openai.com',
  apiKey: 'sk-test',
  model: 'gpt-test',
  messages: const [
    {'role': 'user', 'content': 'hi'},
  ],
  maxTokens: 100,
  temperature: 0.7,
  topP: 0.9,
  stream: stream,
  omitReasoning: omitReasoning,
  showNativeReasoning: showNativeReasoning,
);

/// SSE body that interleaves native `reasoning_content` with normal `content`.
final _sseWithReasoning = [
  'data: {"choices":[{"delta":{"reasoning_content":"thinking "}}]}',
  'data: {"choices":[{"delta":{"reasoning_content":"more"}}]}',
  'data: {"choices":[{"delta":{"content":"answer"}}]}',
  'data: [DONE]',
  '',
].join('\n');

void main() {
  group('omitReasoning response gate (streaming)', () {
    test('parses reasoning_content when omitReasoning is false', () async {
      final dio = Dio()..httpClientAdapter = SseAdapter(_sseWithReasoning);
      final transport = OpenAiChatTransport(dio: dio);

      final updates = <(String, String?)>[];
      String? completeText;
      String? completeReasoning;

      await transport.stream(
        request: _req(stream: true, omitReasoning: false),
        onUpdate: (delta, reasoningDelta) =>
            updates.add((delta, reasoningDelta)),
        onComplete: (text, reasoning, {rawResponseJson}) {
          completeText = text;
          completeReasoning = reasoning;
        },
        onError: (e) => fail('unexpected error: $e'),
      );

      // Native reasoning should reach onUpdate as reasoningDelta and surface
      // in onComplete.
      final reasoningDeltas = updates
          .where((u) => u.$2 != null && u.$2!.isNotEmpty)
          .map((u) => u.$2!)
          .join('');
      expect(reasoningDeltas, 'thinking more');
      expect(completeReasoning, 'thinking more');
      expect(completeText, 'answer');
    });

    test('discards reasoning_content when omitReasoning is true', () async {
      final dio = Dio()..httpClientAdapter = SseAdapter(_sseWithReasoning);
      final transport = OpenAiChatTransport(dio: dio);

      final updates = <(String, String?)>[];
      String? completeText;
      String? completeReasoning;

      await transport.stream(
        request: _req(stream: true, omitReasoning: true),
        onUpdate: (delta, reasoningDelta) =>
            updates.add((delta, reasoningDelta)),
        onComplete: (text, reasoning, {rawResponseJson}) {
          completeText = text;
          completeReasoning = reasoning;
        },
        onError: (e) => fail('unexpected error: $e'),
      );

      // No reasoning delta should reach onUpdate; reasoning in onComplete
      // must be null. Normal content still flows.
      final reasoningDeltas = updates
          .where((u) => u.$2 != null && u.$2!.isNotEmpty)
          .map((u) => u.$2!)
          .join('');
      expect(reasoningDeltas, isEmpty);
      expect(completeReasoning, isNull);
      expect(completeText, 'answer');
    });

    test('showNativeReasoning overrides the legacy request gate', () async {
      final dio = Dio()..httpClientAdapter = SseAdapter(_sseWithReasoning);
      final transport = OpenAiChatTransport(dio: dio);
      String? completeReasoning;

      await transport.stream(
        request: _req(
          stream: true,
          omitReasoning: true,
          showNativeReasoning: true,
        ),
        onComplete: (text, reasoning, {rawResponseJson}) {
          completeReasoning = reasoning;
        },
        onError: (e) => fail('unexpected error: $e'),
      );

      expect(completeReasoning, 'thinking more');
    });
  });
}
