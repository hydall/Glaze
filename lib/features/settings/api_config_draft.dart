import '../../core/llm/converters/prompt_post_processing.dart';
import '../../core/llm/converters/reasoning_effort.dart';
import '../../core/llm/transport/llm_protocol.dart';
import '../../core/models/api_config.dart';

/// Editable API settings values, kept independent from widget controllers.
class ApiConfigDraft {
  const ApiConfigDraft({
    required this.values,
    required this.name,
    required this.endpoint,
    required this.apiKey,
    required this.model,
    required this.maxTokens,
    required this.contextSize,
    required this.firstChunkTimeoutSeconds,
    required this.reasoningHistoryCount,
    required this.embeddingEndpoint,
    required this.embeddingApiKey,
    required this.embeddingModel,
    required this.embeddingMaxChunkTokens,
    required this.embeddingRequestsPerMinute,
  });

  factory ApiConfigDraft.fromConfig(ApiConfig config) {
    final values = normalizeValues(
      config.copyWith(
        requestReasoning: config.requestReasoning && !config.omitReasoning,
      ),
    );
    return ApiConfigDraft(
      values: values,
      name: values.name,
      endpoint: values.endpoint,
      apiKey: values.apiKey,
      model: values.model,
      maxTokens: values.maxTokens.toString(),
      contextSize: values.contextSize.toString(),
      firstChunkTimeoutSeconds: (values.firstChunkTimeoutMs ~/ 1000).toString(),
      reasoningHistoryCount: values.reasoningHistoryCount.toString(),
      embeddingEndpoint: values.embeddingEndpoint,
      embeddingApiKey: values.embeddingApiKey,
      embeddingModel: values.embeddingModel,
      embeddingMaxChunkTokens: values.embeddingMaxChunkTokens.toString(),
      embeddingRequestsPerMinute: values.embeddingRequestsPerMinute.toString(),
    );
  }

  final ApiConfig values;
  final String name;
  final String endpoint;
  final String apiKey;
  final String model;
  final String maxTokens;
  final String contextSize;
  final String firstChunkTimeoutSeconds;
  final String reasoningHistoryCount;
  final String embeddingEndpoint;
  final String embeddingApiKey;
  final String embeddingModel;
  final String embeddingMaxChunkTokens;
  final String embeddingRequestsPerMinute;

  static ApiConfig normalizeValues(ApiConfig values) {
    final protocol = LlmProtocol.isValid(values.protocol)
        ? values.protocol
        : LlmProtocol.customChatCompletion;
    final reasoningEffort = isValidReasoningEffort(values.reasoningEffort)
        ? values.reasoningEffort
        : 'medium';
    // Sampling and reasoning omit-toggles are NOT protocol-bound: every
    // protocol accepts temperature/top_p, and the Anthropic and Gemini
    // transports have always honored the flags. Clearing them here was the
    // only thing stopping those two from using the toggles at all.
    // The Responses API has no penalties and no body-level cache_control.
    final supportsPenalties =
        protocol == LlmProtocol.openai ||
        protocol == LlmProtocol.customChatCompletion ||
        protocol == LlmProtocol.openrouter;
    // Official OpenAI and the Responses API have no `top_k`, and their editors
    // hide the slider. Clear the stored value too — otherwise a top_k carried
    // over from another protocol keeps going on the wire from a control the
    // user can no longer see, and the endpoint rejects the request.
    final supportsTopK =
        protocol == LlmProtocol.customChatCompletion ||
        protocol == LlmProtocol.openrouter ||
        protocol == LlmProtocol.anthropic ||
        protocol == LlmProtocol.gemini;
    // OpenRouter kept a live TTL out of reach: the UI hid the control and this
    // forced it to 'off', so `buildRouterRequest` never placed cache markers
    // for Claude-through-OR.
    final supportsPromptCache =
        protocol == LlmProtocol.anthropic ||
        protocol == LlmProtocol.customChatCompletion ||
        protocol == LlmProtocol.openrouter;

    return values.copyWith(
      protocol: protocol,
      providerId: protocol == LlmProtocol.customChatCompletion
          ? 'custom_chat_completion'
          : values.providerId,
      sessionIdMode: _resolveSessionIdMode(values, protocol),
      // The Responses API is a protocol now, so the legacy boolean is derived
      // from it rather than edited on its own.
      useResponsesApi:
          protocol == LlmProtocol.openaiResponses ||
          (protocol == LlmProtocol.customChatCompletion &&
              values.useResponsesApi),
      reasoningEffort: reasoningEffort,
      topK: supportsTopK ? values.topK : 0,
      frequencyPenalty: supportsPenalties ? values.frequencyPenalty : 0.0,
      presencePenalty: supportsPenalties ? values.presencePenalty : 0.0,
      cacheControlTtl: supportsPromptCache ? values.cacheControlTtl : 'off',
      // Every first-party protocol normalizes message shape inside its own
      // converter, so the control is offered for custom endpoints only. Clear
      // it elsewhere rather than let a hidden setting reshape the prompt.
      promptPostProcessing: protocol == LlmProtocol.customChatCompletion
          ? PromptPostProcessing.normalize(values.promptPostProcessing)
          : PromptPostProcessing.none,
    );
  }

  /// `session_id` used to be a three-way selector whose default,
  /// `'openrouter'`, meant "send only to openrouter.ai". It is a plain toggle
  /// now, so that legacy value resolves once, to whatever it used to do for
  /// this preset — on for OpenRouter, off everywhere else.
  static String _resolveSessionIdMode(ApiConfig values, String protocol) {
    switch (values.sessionIdMode) {
      case 'always':
      case 'off':
        return values.sessionIdMode;
      default:
        return protocol == LlmProtocol.openrouter ||
                values.endpoint.contains('openrouter.ai')
            ? 'always'
            : 'off';
    }
  }

  /// Everything the editor holds, written onto one preset.
  ///
  /// Used while the LLM and the embedding side run on the same preset; when
  /// they are two different presets each half goes to its own through
  /// [applyLlmTo] and [applyEmbeddingTo].
  ApiConfig toConfig(ApiConfig base) => applyEmbeddingTo(applyLlmTo(base));

  /// The LLM half of the editor — connection, sampling, reasoning, cache. The
  /// preset's embedding fields are left exactly as they are.
  ApiConfig applyLlmTo(ApiConfig base) {
    final normalized = normalizeValues(values);
    final parsedReasoningHistoryCount =
        int.tryParse(reasoningHistoryCount) ?? 0;
    return base.copyWith(
      name: name.trim(),
      endpoint: endpoint.trim(),
      apiKey: apiKey.trim(),
      model: model.trim(),
      maxTokens: int.tryParse(maxTokens) ?? base.maxTokens,
      contextSize: int.tryParse(contextSize) ?? base.contextSize,
      firstChunkTimeoutMs:
          (int.tryParse(firstChunkTimeoutSeconds) ?? 60) * 1000,
      temperature: normalized.temperature,
      topP: normalized.topP,
      topK: normalized.topK,
      frequencyPenalty: normalized.frequencyPenalty,
      presencePenalty: normalized.presencePenalty,
      stream: normalized.stream,
      requestReasoning: normalized.requestReasoning,
      useResponsesApi: normalized.useResponsesApi,
      useSystemInstruction: normalized.useSystemInstruction,
      showNativeReasoning: normalized.showNativeReasoning,
      reasoningHistoryCount: parsedReasoningHistoryCount < -1
          ? 0
          : parsedReasoningHistoryCount,
      reasoningEffort: normalized.reasoningEffort,
      omitTemperature: normalized.omitTemperature,
      omitTopP: normalized.omitTopP,
      omitTopK: normalized.omitTopK,
      omitFrequencyPenalty: normalized.omitFrequencyPenalty,
      omitPresencePenalty: normalized.omitPresencePenalty,
      omitReasoning: normalized.omitReasoning,
      omitReasoningEffort: normalized.omitReasoningEffort,
      cacheControlTtl: normalized.cacheControlTtl,
      cacheBreakpointMode: normalized.cacheBreakpointMode,
      sessionIdMode: normalized.sessionIdMode,
      promptPostProcessing: normalized.promptPostProcessing,
      protocol: normalized.protocol,
      extraRequestParameters: normalized.extraRequestParameters,
    );
  }

  /// The embedding half of the editor, written onto the preset the Embeddings
  /// tab is pointed at — a preset of its own, from a list the chat side never
  /// shows. The preset's name is set by the caller, which is the only field
  /// the two halves of the editor spell the same way.
  ApiConfig applyEmbeddingTo(ApiConfig base) {
    final normalized = normalizeValues(values);
    final parsedEmbeddingRequestsPerMinute = int.tryParse(
      embeddingRequestsPerMinute,
    );
    return base.copyWith(
      embeddingEnabled: normalized.embeddingEnabled,
      embeddingUseSame: normalized.embeddingUseSame,
      embeddingLlmPresetId: normalized.embeddingLlmPresetId,
      embeddingEndpoint: embeddingEndpoint.trim(),
      embeddingApiKey: embeddingApiKey.trim(),
      embeddingModel: embeddingModel.trim(),
      embeddingMaxChunkTokens:
          int.tryParse(embeddingMaxChunkTokens) ?? base.embeddingMaxChunkTokens,
      embeddingRequestsPerMinute:
          parsedEmbeddingRequestsPerMinute != null &&
              parsedEmbeddingRequestsPerMinute > 0
          ? parsedEmbeddingRequestsPerMinute
          : base.embeddingRequestsPerMinute,
    );
  }
}
