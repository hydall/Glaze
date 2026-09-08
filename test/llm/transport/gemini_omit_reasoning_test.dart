import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/gemini_chat_transport.dart';

import '_sse_adapter.dart';

ChatTransportRequest _req({
  required bool stream,
  bool omitReasoning = false,
  bool? showNativeReasoning,
}) => ChatTransportRequest(
  endpoint: 'https://generativelanguage.googleapis.com',
  apiKey: 'AIza-test',
  model: 'gemini-2.5-flash',
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

/// Gemini SSE body interleaving thought parts with normal text parts.
final _geminiSseWithThoughts = [
  'data: {"candidates":[{"content":{"parts":[{"text":"thinking ","thought":true}]}}]}',
  'data: {"candidates":[{"content":{"parts":[{"text":"more","thought":true}]}}]}',
  'data: {"candidates":[{"content":{"parts":[{"text":"answer"}]}}]}',
  '',
].join('\n');

void main() {
  group('omitReasoning response gate (Gemini streaming)', () {
    test('parses thought parts when omitReasoning is false', () async {
      final dio = Dio()..httpClientAdapter = SseAdapter(_geminiSseWithThoughts);
      final transport = GeminiChatTransport(dio: dio);

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

      expect(reasoningDeltas.join(''), 'thinking more');
      expect(completeReasoning, 'thinking more');
      expect(completeText, 'answer');
    });

    test('discards thought parts when omitReasoning is true', () async {
      final dio = Dio()..httpClientAdapter = SseAdapter(_geminiSseWithThoughts);
      final transport = GeminiChatTransport(dio: dio);

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
      final dio = Dio()..httpClientAdapter = SseAdapter(_geminiSseWithThoughts);
      final transport = GeminiChatTransport(dio: dio);
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
