import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/anthropic_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';

import '_sse_adapter.dart';

ChatTransportRequest _req({
  required bool stream,
  bool omitReasoning = false,
  bool? showNativeReasoning,
}) => ChatTransportRequest(
  endpoint: 'https://api.anthropic.com',
  apiKey: 'sk-ant-test',
  model: 'claude-3-7-sonnet',
  messages: const [
    {'role': 'user', 'content': 'hi'},
  ],
  maxTokens: 1000,
  temperature: 0.7,
  topP: 0.9,
  stream: stream,
  omitReasoning: omitReasoning,
  showNativeReasoning: showNativeReasoning,
);

/// Anthropic SSE body interleaving thinking_delta with text_delta, ending with
/// message_stop.
final _anthropicSseWithThinking = [
  'data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"secret "}}',
  'data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"thoughts"}}',
  'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"answer"}}',
  'data: {"type":"message_delta","usage":{"output_tokens":5}}',
  'data: {"type":"message_stop"}',
  '',
].join('\n');

void main() {
  group('omitReasoning response gate (Anthropic streaming)', () {
    test('parses thinking_delta when omitReasoning is false', () async {
      final dio = Dio()
        ..httpClientAdapter = SseAdapter(_anthropicSseWithThinking);
      final transport = AnthropicChatTransport(dio: dio);

      final reasoningDeltas = <String>[];
      String? completeText;
      String? completeReasoning;

      await transport.stream(
        request: _req(stream: true, omitReasoning: false),
        onUpdate: (delta, reasoningDelta) {
          if (reasoningDelta != null && reasoningDelta.isNotEmpty) {
            reasoningDeltas.add(reasoningDelta);
          }
        },
        onComplete: (text, reasoning, {rawResponseJson}) {
          completeText = text;
          completeReasoning = reasoning;
        },
        onError: (e) => fail('unexpected error: $e'),
      );

      expect(reasoningDeltas.join(''), 'secret thoughts');
      expect(completeReasoning, 'secret thoughts');
      expect(completeText, 'answer');
    });

    test('discards thinking_delta when omitReasoning is true', () async {
      final dio = Dio()
        ..httpClientAdapter = SseAdapter(_anthropicSseWithThinking);
      final transport = AnthropicChatTransport(dio: dio);

      final reasoningDeltas = <String>[];
      String? completeText;
      String? completeReasoning;

      await transport.stream(
        request: _req(stream: true, omitReasoning: true),
        onUpdate: (delta, reasoningDelta) {
          if (reasoningDelta != null && reasoningDelta.isNotEmpty) {
            reasoningDeltas.add(reasoningDelta);
          }
        },
        onComplete: (text, reasoning, {rawResponseJson}) {
          completeText = text;
          completeReasoning = reasoning;
        },
        onError: (e) => fail('unexpected error: $e'),
      );

      expect(reasoningDeltas, isEmpty);
      expect(completeReasoning, isNull);
      expect(completeText, 'answer');
    });

    test('showNativeReasoning overrides the legacy request gate', () async {
      final dio = Dio()
        ..httpClientAdapter = SseAdapter(_anthropicSseWithThinking);
      final transport = AnthropicChatTransport(dio: dio);
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

      expect(completeReasoning, 'secret thoughts');
    });
  });
}
