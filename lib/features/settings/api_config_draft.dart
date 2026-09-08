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

  static const _standardReasoningEfforts = [
    'auto',
    'low',
    'medium',
    'high',
    'max',
  ];
  static const _extendedReasoningEfforts = [
    'auto',
    'min',
    'low',
    'medium',
    'high',
    'max',
  ];

  static List<String> reasoningEffortOptions(String protocol) =>
      protocol == LlmProtocol.anthropic || protocol == LlmProtocol.gemini
      ? _extendedReasoningEfforts
      : _standardReasoningEfforts;

  static ApiConfig normalizeValues(ApiConfig values) {
    final protocol = LlmProtocol.isValid(values.protocol)
        ? values.protocol
        : LlmProtocol.openai;
    final efforts = reasoningEffortOptions(protocol);
    final reasoningEffort = efforts.contains(values.reasoningEffort)
        ? values.reasoningEffort
        : values.reasoningEffort == 'min'
        ? 'low'
        : 'medium';
    final supportsOpenAiOptions =
        protocol == LlmProtocol.openai || protocol == LlmProtocol.openrouter;
    final supportsPromptCache =
        protocol == LlmProtocol.anthropic || protocol == LlmProtocol.openai;

    return values.copyWith(
      protocol: protocol,
      reasoningEffort: reasoningEffort,
      omitTemperature: supportsOpenAiOptions ? values.omitTemperature : false,
      omitTopP: supportsOpenAiOptions ? values.omitTopP : false,
      omitReasoning: supportsOpenAiOptions ? values.omitReasoning : false,
      omitReasoningEffort: supportsOpenAiOptions
          ? values.omitReasoningEffort
          : false,
      frequencyPenalty: supportsOpenAiOptions ? values.frequencyPenalty : 0.0,
      presencePenalty: supportsOpenAiOptions ? values.presencePenalty : 0.0,
      cacheControlTtl: supportsPromptCache ? values.cacheControlTtl : 'off',
    );
  }

  ApiConfig toConfig(ApiConfig base) {
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
      embeddingEnabled: normalized.embeddingEnabled,
      embeddingUseSame: normalized.embeddingUseSame,
      cacheControlTtl: normalized.cacheControlTtl,
      cacheBreakpointMode: normalized.cacheBreakpointMode,
      sessionIdMode: normalized.sessionIdMode,
      protocol: normalized.protocol,
      embeddingEndpoint: embeddingEndpoint.trim(),
      embeddingApiKey: embeddingApiKey.trim(),
      embeddingModel: embeddingModel.trim(),
      embeddingMaxChunkTokens:
          int.tryParse(embeddingMaxChunkTokens) ?? base.embeddingMaxChunkTokens,
      extraRequestParameters: normalized.extraRequestParameters,
    );
  }
}
