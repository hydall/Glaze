import '../../models/api_config.dart';
import 'anthropic_chat_transport.dart';
import 'chat_transport.dart';
import 'gemini_chat_transport.dart';
import 'llm_protocol.dart';
import 'llm_request_dump.dart';
import 'openai_chat_transport.dart';
import 'openai_responses_transport.dart';
import 'openrouter_chat_transport.dart';

/// Resolves a [ChatTransport] for the given protocol string.
///
/// Unknown / legacy values fall back to OpenAI for safety — that keeps
/// pre-v23 configs (no `protocol` field) working without any UI prompt.
///
/// Implementations are stateless and cheap to instantiate, so the factory
/// just `new`s on every call. If a transport ever needs shared HTTP-client
/// state, register it as a singleton here.
ChatTransport pickChatTransport(String protocol) {
  final ChatTransport inner;
  switch (protocol) {
    case LlmProtocol.openai:
      inner = OpenAiCompatibleTransport();
    case LlmProtocol.anthropic:
      inner = AnthropicChatTransport();
    case LlmProtocol.gemini:
      inner = GeminiChatTransport();
    case LlmProtocol.openrouter:
      inner = OpenRouterChatTransport();
    default:
      inner = OpenAiChatTransport();
  }
  // Diagnostics: dump every outgoing request payload (no-op when disabled).
  return LoggingChatTransport(inner, label: protocol);
}

ChatTransport pickChatTransportFor(ApiConfig config) =>
    pickChatTransport(config.protocol);
