import 'package:freezed_annotation/freezed_annotation.dart';

import '../llm/transport/llm_protocol.dart';
import 'extra_request_parameter.dart';

part 'api_config.freezed.dart';
part 'api_config.g.dart';

@freezed
abstract class ApiConfig with _$ApiConfig {
  const factory ApiConfig({
    required String id,
    @Default('') String name,
    @Default('openai') String providerId,
    @Default('openai') String protocol,
    @Default('') String endpoint,
    @Default('') String apiKey,
    @Default('') String model,
    @Default('chat') String mode,
    @Default(8000) int maxTokens,
    @Default(32000) int contextSize,

    /// How history is cut once it stops fitting — `sliding` or `stepped`.
    /// See [HistoryTrimMode]; it is a cache property of the connection, which
    /// is why it sits next to the window it is cut against.
    @Default('sliding') String historyTrimMode,

    /// Stepped mode only: how full the held window may get before the anchor
    /// moves, and how much of the budget a move gives back. See
    /// [kDefaultHistoryTrimTriggerPercent] / [kDefaultHistoryTrimStepPercent].
    @Default(85) int historyTrimTriggerPercent,
    @Default(30) int historyTrimStepPercent,
    @Default(0.7) double temperature,
    @Default(0.9) double topP,
    @Default(0) int topK,
    @Default(0.0) double frequencyPenalty,
    @Default(0.0) double presencePenalty,
    @Default(true) bool stream,
    @Default('medium') String reasoningEffort,
    @Default(false) bool requestReasoning,
    @Default(false) bool useResponsesApi,
    @Default(true) bool showNativeReasoning,
    @Default(0) int reasoningHistoryCount,
    @Default(false) bool excludeReasoningFromContextBudget,
    String? reasoningTagStart,
    String? reasoningTagEnd,
    @Default(false) bool omitTemperature,
    @Default(false) bool omitTopP,
    @Default(false) bool omitTopK,
    @Default(false) bool omitFrequencyPenalty,
    @Default(false) bool omitPresencePenalty,
    @Default(false) bool omitReasoning,
    @Default(false) bool omitReasoningEffort,
    @Default(true) bool embeddingUseSame,
    @Default(false) bool embeddingEnabled,
    @Default('') String embeddingEndpoint,
    @Default('') String embeddingApiKey,
    @Default('') String embeddingModel,
    @Default(512) int embeddingMaxChunkTokens,
    @Default(50) int embeddingRequestsPerMinute,

    /// Which LLM preset an embedding preset borrows its endpoint and key from
    /// while [embeddingUseSame] is on. Empty means "whichever connection the
    /// LLM tab is currently on", the behaviour before the row existed.
    @Default('') String embeddingLlmPresetId,
    @Default('off') String cacheControlTtl,
    @Default('depth') String cacheBreakpointMode,
    @Default('openrouter') String sessionIdMode,

    /// SillyTavern-style prompt post-processing applied to the finished
    /// message array before the protocol converter runs. See
    /// `lib/core/llm/converters/prompt_post_processing.dart` for the modes.
    @Default('none') String promptPostProcessing,
    @Default(60000) int firstChunkTimeoutMs,

    /// Send the leading run of system blocks in the provider's own field —
    /// Gemini's `system_instruction`, Anthropic's `system`. When off it stays
    /// inline and is delivered as user turns. Ignored by protocols that have
    /// no such field.
    @Default(true) bool useSystemInstruction,
    @Default(<ExtraRequestParameter>[])
    List<ExtraRequestParameter> extraRequestParameters,
  }) = _ApiConfig;

  factory ApiConfig.fromJson(Map<String, dynamic> json) =>
      _$ApiConfigFromJson(_normalizeApiConfigJson(json));
}

Map<String, dynamic> _normalizeApiConfigJson(Map<String, dynamic> json) {
  final normalized = Map<String, dynamic>.from(json)
    ..putIfAbsent('showNativeReasoning', () => json['omitReasoning'] != true)
    ..putIfAbsent(
      'reasoningHistoryCount',
      () => json['includeLastReasoning'] == true ? 1 : 0,
    );
  final sourceProtocol = normalized['protocol'];
  final sourceProvider = normalized['providerId'];
  if (sourceProtocol == 'openai_compatible' ||
      sourceProtocol == null ||
      (sourceProtocol == LlmProtocol.openai &&
          (sourceProvider == null || sourceProvider == 'openai_compatible')) ||
      (sourceProtocol == LlmProtocol.openaiResponses &&
          (sourceProvider == null || sourceProvider == 'openai_compatible'))) {
    // Historical custom presets used `openai` (or later
    // `openai_responses`) plus this provider id. Keep them custom and retain
    // useResponsesApi as the endpoint-mode toggle.
    normalized['protocol'] = LlmProtocol.customChatCompletion;
    normalized['providerId'] = 'custom_chat_completion';
  }
  return normalized;
}

extension ApiConfigContextX on ApiConfig {
  /// Every field that changes which messages survive into the prompt.
  ///
  /// Anything that reuses a cached [TokenBreakdown] — or shows a preview of the
  /// next request — has to notice when one of these moves, or it keeps showing
  /// a prompt the app would no longer send.
  String get contextBudgetSignature =>
      '$id|$contextSize|$maxTokens|$historyTrimMode|'
      '$historyTrimTriggerPercent|$historyTrimStepPercent|'
      '$reasoningHistoryCount|$excludeReasoningFromContextBudget';
}
