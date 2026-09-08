import '../../models/extra_request_parameter.dart';
import '../../models/api_config.dart';

/// Provider-neutral input for [ChatTransport.stream].
///
/// Mirrors the shape of OpenAI Chat Completions request body — that's also
/// the format current consumers build, so this is a near-identity carrier.
/// Non-OpenAI transports re-shape it via converters in `lib/core/llm/converters/`.
///
/// Multimodal: `messages[i].content` may be a `String` or a `List` of OpenAI-shape
/// content parts (`{type: "text", text}`, `{type: "image_url", image_url: {url}}`).
/// Anthropic/Gemini transports convert these parts to their native shape.
class ChatTransportRequest {
  /// API endpoint base URL (e.g. `https://api.openai.com`). Ignored by
  /// `OpenRouterChatTransport` (URL is hardcoded).
  final String endpoint;
  final String apiKey;
  final String model;

  /// OpenAI-shape messages — see class docstring.
  final List<Map<String, dynamic>> messages;

  final int maxTokens;
  final double temperature;
  final double topP;
  final int topK;
  final double frequencyPenalty;
  final double presencePenalty;
  final bool stream;
  final bool requestReasoning;
  final bool useResponsesApi;
  final String? reasoningEffort;
  final bool omitTemperature;
  final bool omitTopP;
  final bool omitTopK;
  final bool omitFrequencyPenalty;
  final bool omitPresencePenalty;
  final bool omitReasoning;
  final bool omitReasoningEffort;
  final bool? showNativeReasoning;

  /// Optional per-call HTTP receive timeout. `0` disables the transport-level
  /// timeout so a caller such as Studio can own first-chunk timeout semantics.
  final int? receiveTimeoutMs;

  /// Optional session ID — forwarded as `session_id` in body when prompt
  /// caching is enabled (OpenRouter / Anthropic-via-OR scenarios).
  final String? sessionId;

  /// Previous request body messages for hash-based cache breakpoint placement.
  final List<Map<String, dynamic>>? previousMessages;

  /// Anthropic prompt cache TTL: `'off' | '5min' | '1h'`.
  final String cacheControlTtl;

  /// Prompt cache breakpoint placement: `'depth' | 'stable_prefix'`.
  final String cacheBreakpointMode;

  /// Controls when `session_id` is sent: `'openrouter' | 'always' | 'off'`.
  final String sessionIdMode;

  /// Optional tool definitions for native tool-call support (OpenAI format).
  /// When non-null, the request includes `tools` and `tool_choice` in the body.
  /// Transports that don't support tools will ignore this field.
  final List<Map<String, dynamic>>? tools;

  /// Controls tool choice: `'none' | 'auto' | 'required'` or a specific tool.
  /// Only sent when [tools] is non-null.
  final String? toolChoice;

  final List<ExtraRequestParameter> extraRequestParameters;

  const ChatTransportRequest({
    required this.endpoint,
    required this.apiKey,
    required this.model,
    required this.messages,
    required this.maxTokens,
    required this.temperature,
    required this.topP,
    this.topK = 0,
    this.frequencyPenalty = 0.0,
    this.presencePenalty = 0.0,
    this.stream = true,
    this.requestReasoning = false,
    this.useResponsesApi = false,
    this.reasoningEffort,
    this.omitTemperature = false,
    this.omitTopP = false,
    this.omitTopK = false,
    this.omitFrequencyPenalty = false,
    this.omitPresencePenalty = false,
    this.omitReasoning = false,
    this.omitReasoningEffort = false,
    this.showNativeReasoning,
    this.receiveTimeoutMs,
    this.sessionId,
    this.previousMessages,
    this.cacheControlTtl = 'off',
    this.cacheBreakpointMode = 'depth',
    this.sessionIdMode = 'openrouter',
    this.tools,
    this.toolChoice,
    this.extraRequestParameters = const [],
  });

  /// Maps the request-level options from [apiConfig] while allowing callers to
  /// supply data that belongs to one generation rather than the saved config.
  factory ChatTransportRequest.fromApiConfig(
    ApiConfig apiConfig, {
    required List<Map<String, dynamic>> messages,
    String? model,
    bool? stream,
    int? receiveTimeoutMs,
    String? sessionId,
    List<Map<String, dynamic>>? previousMessages,
    List<Map<String, dynamic>>? tools,
    String? toolChoice,
  }) => ChatTransportRequest(
    endpoint: apiConfig.endpoint,
    apiKey: apiConfig.apiKey,
    model: model ?? apiConfig.model,
    messages: messages,
    maxTokens: apiConfig.maxTokens,
    temperature: apiConfig.temperature,
    topP: apiConfig.topP,
    topK: apiConfig.topK,
    frequencyPenalty: apiConfig.frequencyPenalty,
    presencePenalty: apiConfig.presencePenalty,
    stream: stream ?? apiConfig.stream,
    requestReasoning: apiConfig.requestReasoning,
    useResponsesApi: apiConfig.useResponsesApi,
    reasoningEffort: apiConfig.reasoningEffort,
    omitTemperature: apiConfig.omitTemperature,
    omitTopP: apiConfig.omitTopP,
    omitTopK: apiConfig.omitTopK,
    omitFrequencyPenalty: apiConfig.omitFrequencyPenalty,
    omitPresencePenalty: apiConfig.omitPresencePenalty,
    omitReasoning: apiConfig.omitReasoning,
    omitReasoningEffort: apiConfig.omitReasoningEffort,
    showNativeReasoning: apiConfig.showNativeReasoning,
    receiveTimeoutMs: receiveTimeoutMs,
    sessionId: sessionId,
    previousMessages: previousMessages,
    cacheControlTtl: apiConfig.cacheControlTtl,
    cacheBreakpointMode: apiConfig.cacheBreakpointMode,
    sessionIdMode: apiConfig.sessionIdMode,
    tools: tools,
    toolChoice: toolChoice,
    extraRequestParameters: apiConfig.extraRequestParameters,
  );
}
