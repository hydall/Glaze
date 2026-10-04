import '../../models/api_config.dart';
import 'anthropic_chat_transport.dart';
import 'chat_transport.dart';
import 'gemini_chat_transport.dart';
import 'llm_protocol.dart';
import 'llm_request_dump.dart';
import 'openai_chat_transport.dart';
import 'openai_responses_transport.dart';
import 'openrouter_chat_transport.dart';
import 'post_processing_chat_transport.dart';

/// Resolves a [ChatTransport] for the given protocol string.
///
/// Unknown / legacy values fall back to Custom Chat Completion for safety —
/// that keeps old configs working without assigning official API semantics.
///
/// Implementations are stateless and cheap to instantiate, so the factory
/// just `new`s on every call. If a transport ever needs shared HTTP-client
/// state, register it as a singleton here.
ChatTransport pickChatTransport(String protocol) {
  final ChatTransport inner;
  switch (protocol) {
    case LlmProtocol.openai:
      inner = OpenAiChatTransport();
    case LlmProtocol.customChatCompletion:
      inner = CustomChatCompletionTransport();
    case LlmProtocol.openaiResponses:
      inner = OpenAiResponsesTransport();
    case LlmProtocol.anthropic:
      inner = AnthropicChatTransport();
    case LlmProtocol.gemini:
      inner = GeminiChatTransport();
    case LlmProtocol.openrouter:
      inner = OpenRouterChatTransport();
    default:
      inner = CustomChatCompletionTransport();
  }
  // Diagnostics: dump every outgoing request payload (no-op when disabled).
  // Post-processing wraps the dump rather than the other way round, so what
  // gets logged is the conversation that actually leaves the device.
  return PostProcessingChatTransport(
    LoggingChatTransport(inner, label: protocol),
  );
}

ChatTransport pickChatTransportFor(ApiConfig config) =>
    pickChatTransport(config.protocol);
