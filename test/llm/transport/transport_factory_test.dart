import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/anthropic_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/gemini_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_dump.dart';
import 'package:glaze_flutter/core/llm/transport/openai_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/openai_responses_transport.dart';
import 'package:glaze_flutter/core/llm/transport/openrouter_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/post_processing_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/transport_factory.dart';

/// The factory wraps every transport twice — prompt post-processing on the
/// outside, request dumping under it — so assertions unwrap both layers to
/// reach the protocol implementation.
Object _inner(String protocol) {
  final postProcessing =
      pickChatTransport(protocol) as PostProcessingChatTransport;
  return (postProcessing.inner as LoggingChatTransport).inner;
}

void main() {
  test('each protocol resolves to its transport', () {
    expect(_inner(LlmProtocol.openai), isA<OpenAiChatTransport>());
    expect(
      _inner(LlmProtocol.customChatCompletion),
      isA<CustomChatCompletionTransport>(),
    );
    expect(
      _inner(LlmProtocol.openaiResponses),
      isA<OpenAiResponsesTransport>(),
    );
    expect(_inner(LlmProtocol.anthropic), isA<AnthropicChatTransport>());
    expect(_inner(LlmProtocol.gemini), isA<GeminiChatTransport>());
    expect(_inner(LlmProtocol.openrouter), isA<OpenRouterChatTransport>());
  });

  test('unknown protocols still fall back to Chat Completions', () {
    expect(_inner('legacy-value'), isA<CustomChatCompletionTransport>());
  });

  test('every listed protocol has a label', () {
    for (final protocol in LlmProtocol.all) {
      expect(LlmProtocol.labels[protocol], isNotNull, reason: protocol);
      expect(LlmProtocol.isValid(protocol), isTrue);
    }
  });
}
