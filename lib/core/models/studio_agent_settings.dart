import 'package:freezed_annotation/freezed_annotation.dart';

import 'extra_request_parameter.dart';

part 'studio_agent_settings.freezed.dart';
part 'studio_agent_settings.g.dart';

/// Studio agent generation settings — pre-gen trackers, final generator, and
/// post-processing tracker context.
///
/// Nested inside [PipelineSettings] under the `studioAgent` field. All fields
/// are global (singleton SharedPreferences), applied uniformly across all
/// chat sessions.
///
/// Field groups:
/// - Global idle timeout ([studioTimeoutMs]) — applies to all Studio agents.
/// - Final generator overrides ([studioFinal*]) — Main Responder.
/// - Tracker overrides ([studioTracker*]) — 7 pre-gen controllers + batch.
/// - Post-processing context ([studioPostTrackerContextSize]).
@freezed
abstract class StudioAgentSettings with _$StudioAgentSettings {
  const factory StudioAgentSettings({
    // ── Global idle timeout ────────────────────────────────────────────────
    // Per-agent idle timeout (ms) before the model emits its first chunk.
    // Once any chunk (text or reasoning) arrives, the idle timer is
    // cancelled entirely so a long generation is never cut off. 0 = use the
    // per-agent fallback (final generator: 90s, trackers: 60s).
    @Default(0) int studioTimeoutMs,

    // ── Final generator (Main Responder) ──────────────────────────────────
    // Final-generator idle timeout (ms). 0 = use agent/global fallback.
    @Default(0) int studioFinalTimeoutMs,
    // Max tokens for the Studio final generator. When > 0, overrides the
    // per-agent default (8000). Useful for reasoning models (e.g. Gemini)
    // that spend most of the budget on thinking. 0 = use agent's maxTokens.
    @Default(0) int studioFinalMaxTokens,
    @Default(0.9) double studioFinalTopP,
    @Default(0) int studioFinalTopK,
    @Default(0.0) double studioFinalFrequencyPenalty,
    @Default(0.0) double studioFinalPresencePenalty,
    // Chat history messages override for the final generator. When > 0,
    // overrides StudioConfig.maxFinalHistoryMessages. 0 = use per-session
    // StudioConfig default (30).
    @Default(0) int studioFinalContextSize,
    // Temperature for the final generator. When >= 0, overrides the per-agent
    // default (0.8). Negative = use the agent's own temperature.
    @Default(1.0) double studioFinalTemperature,
    @Default(false) bool studioFinalRequestReasoning,
    @Default(false) bool studioFinalUseResponsesApi,
    @Default('auto') String studioFinalReasoningEffort,
    @Default(false) bool studioFinalOmitTemperature,
    @Default(false) bool studioFinalOmitTopP,
    @Default(true) bool studioFinalOmitReasoning,
    @Default(true) bool studioFinalOmitReasoningEffort,
    // Include reasoning_content from the N most recent assistant messages in
    // final-generator history. -1 includes all retained history; 0 disables it.
    @Default(0) int studioFinalReasoningHistoryCount,
    // When true, the final generator's request forces requestReasoning=false
    // and omitReasoning=true regardless of the ApiConfig. Targeted at Gemini
    // Flash thinking models that spend most of the token budget on a
    // think-block. Only effective for Gemini-protocol endpoints.
    @Default(false) bool studioFinalDisableReasoning,
    // Model id override for the final generator. Empty = use the selected
    // Studio final API config model, or the active chat model when no final
    // API config is selected.
    @Default('') String studioFinalModelOverride,
    @Default(<ExtraRequestParameter>[])
    List<ExtraRequestParameter> studioFinalExtraRequestParameters,

    // ── Studio trackers (intermediate agents) ─────────────────────────────
    // The 7 pre-gen controllers share one logical batch. Model id override
    // applied to ALL non-final Studio agents when non-empty. Empty = use each
    // agent's own `modelOverride` or the chat's run model.
    @Default('') String studioTrackerModelOverride,
    // Tracker idle timeout (ms). 0 = use agent/global fallback.
    @Default(0) int studioTrackerTimeoutMs,
    // Max tokens for ALL non-final Studio agents. When > 0, overrides the
    // per-agent default (1600). 0 = use the agent's own maxTokens.
    @Default(0) int studioTrackerMaxTokens,
    @Default(0.9) double studioTrackerTopP,
    @Default(0) int studioTrackerTopK,
    @Default(0.0) double studioTrackerFrequencyPenalty,
    @Default(0.0) double studioTrackerPresencePenalty,
    // Temperature for ALL non-final Studio agents. When >= 0, overrides the
    // per-agent default (0.3). Negative = use the agent's own temperature.
    @Default(0.5) double studioTrackerTemperature,
    @Default(false) bool studioTrackerRequestReasoning,
    @Default(false) bool studioTrackerUseResponsesApi,
    @Default('auto') String studioTrackerReasoningEffort,
    @Default(false) bool studioTrackerOmitTemperature,
    @Default(false) bool studioTrackerOmitTopP,
    @Default(true) bool studioTrackerOmitReasoning,
    @Default(true) bool studioTrackerOmitReasoningEffort,
    // When true, all non-final Studio agent requests force
    // requestReasoning=false and omitReasoning=true. Trackers emit compact
    // JSON briefs, so a hidden think-block wastes tokens. Gemini-only.
    @Default(false) bool studioTrackerDisableReasoning,
    // Context size for ALL non-final Studio agents (batch + individual).
    // This is the single source of truth — per-agent contextSize is ignored.
    @Default(8) int studioTrackerContextSize,
    @Default(<ExtraRequestParameter>[])
    List<ExtraRequestParameter> studioTrackerExtraRequestParameters,

    // ── Post-processing trackers ──────────────────────────────────────────
    // Number of trailing chat messages forwarded to post-processing
    // (post-gen) trackers. Default 1 (only the response to edit).
    @Default(1) int studioPostTrackerContextSize,
  }) = _StudioAgentSettings;

  factory StudioAgentSettings.fromJson(Map<String, dynamic> json) =>
      _$StudioAgentSettingsFromJson(_normalizeStudioAgentSettingsJson(json));
}

Map<String, dynamic> _normalizeStudioAgentSettingsJson(
  Map<String, dynamic> json,
) => Map<String, dynamic>.from(json)
  ..putIfAbsent(
    'studioFinalReasoningHistoryCount',
    () => json['studioFinalIncludeLastReasoning'] == true ? 1 : 0,
  );
