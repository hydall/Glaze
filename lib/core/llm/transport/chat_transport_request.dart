import '../../models/extra_request_parameter.dart';
import '../../models/api_config.dart';
import 'llm_capture_context.dart';

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

  /// SillyTavern-style reshaping applied to [messages] before the protocol
  /// converter runs — see `converters/prompt_post_processing.dart`. Applied
  /// once, by the decorator `pickChatTransport` wraps every transport in, so
  /// transports themselves always see already-processed messages.
  final String promptPostProcessing;

  /// Effective chat speaker names used by SillyTavern `single` processing.
  /// Request metadata only: transports do not serialize these as message names.
  final String? charName;
  final String? userName;

  /// Optional tool definitions for native tool-call support (OpenAI format).
  /// When non-null, the request includes `tools` and `tool_choice` in the body.
  /// Transports that don't support tools will ignore this field.
  final List<Map<String, dynamic>>? tools;

  /// Optional JSON-Schema enforcing structured output instead of free text.
  /// When non-null, the OpenAI transport emits `response_format` (json_schema)
  /// and the Gemini transport emits `responseMimeType` + `responseSchema`, and
  /// both unwrap the returned object back into plain text. This is how a
  /// `functionPrefill` block with `prefillStyle: 'structured'` forces the start
  /// of a reply without emitting a synthetic tool call (which Gemini 3.8
  /// rejects for a missing `thought_signature`).
  final Map<String, dynamic>? responseJsonSchema;

  /// Controls tool choice: `'none' | 'auto' | 'required'` or a specific tool.
  /// Only sent when [tools] is non-null.
  final String? toolChoice;

  /// Whether the leading run of system messages may be lifted out of the
  /// conversation into the provider's native system field. When false it stays
  /// inline and is delivered as the first user turn. Only the Gemini transport
  /// consumes it today (`system_instruction`); other transports ignore it.
  final bool useSystemInstruction;

  final List<ExtraRequestParameter> extraRequestParameters;

  /// Diagnostic-only identity. It is never serialized into a provider body.
  final LlmCaptureContext? captureContext;

  /// Whether `session_id` belongs in the body for an OpenAI-shaped request.
  /// The setting is a toggle — `'always'` or `'off'`. `'openrouter'` is the
  /// retired default (send only to openrouter.ai, where it drives sticky
  /// routing so the prompt cache stays warm); it is still honoured here for
  /// presets that predate migration v111 or arrive from older JSON.
  /// Anthropic and Gemini apply the `'always'` half of this themselves.
  bool get shouldSendOpenAiSessionId =>
      sessionId != null &&
      sessionId!.isNotEmpty &&
      (sessionIdMode == 'always' ||
          (sessionIdMode == 'openrouter' &&
              endpoint.contains('openrouter.ai')));

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
    this.promptPostProcessing = 'none',
    this.charName,
    this.userName,
    this.tools,
    this.toolChoice,
    this.responseJsonSchema,
    this.useSystemInstruction = true,
    this.extraRequestParameters = const [],
    this.captureContext,
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
    String? charName,
    String? userName,
    LlmCaptureContext? captureContext,
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
    promptPostProcessing: apiConfig.promptPostProcessing,
    charName: charName,
    userName: userName,
    tools: tools,
    toolChoice: toolChoice,
    useSystemInstruction: apiConfig.useSystemInstruction,
    extraRequestParameters: apiConfig.extraRequestParameters,
    captureContext: captureContext,
  );

  /// Same request with a rewritten conversation. Every other option is carried
  /// over verbatim except [promptPostProcessing], which resets to `'none'`:
  /// the reshaping this method exists for has, by definition, already run.
  ChatTransportRequest withMessages(
    List<Map<String, dynamic>> messages, {
    List<Map<String, dynamic>>? previousMessages,
  }) => ChatTransportRequest(
    endpoint: endpoint,
    apiKey: apiKey,
    model: model,
    messages: messages,
    maxTokens: maxTokens,
    temperature: temperature,
    topP: topP,
    topK: topK,
    frequencyPenalty: frequencyPenalty,
    presencePenalty: presencePenalty,
    stream: stream,
    requestReasoning: requestReasoning,
    useResponsesApi: useResponsesApi,
    reasoningEffort: reasoningEffort,
    omitTemperature: omitTemperature,
    omitTopP: omitTopP,
    omitTopK: omitTopK,
    omitFrequencyPenalty: omitFrequencyPenalty,
    omitPresencePenalty: omitPresencePenalty,
    omitReasoning: omitReasoning,
    omitReasoningEffort: omitReasoningEffort,
    showNativeReasoning: showNativeReasoning,
    receiveTimeoutMs: receiveTimeoutMs,
    sessionId: sessionId,
    previousMessages: previousMessages ?? this.previousMessages,
    cacheControlTtl: cacheControlTtl,
    cacheBreakpointMode: cacheBreakpointMode,
    sessionIdMode: sessionIdMode,
    promptPostProcessing: 'none',
    charName: charName,
    userName: userName,
    tools: tools,
    toolChoice: toolChoice,
    responseJsonSchema: responseJsonSchema,
    useSystemInstruction: useSystemInstruction,
    extraRequestParameters: extraRequestParameters,
    captureContext: captureContext,
  );
}
