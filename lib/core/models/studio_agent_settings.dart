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
/// - Final generator overrides ([studioFinal*]) — Main Writer.
/// - Controller overrides ([studioController*]) — 7 pre-gen controllers + batch.
/// - Post-processing context ([studioPostTrackerContextSize]).
///
/// ## `*Override` flags
///
/// Every sampling / reasoning parameter that the selected API preset also
/// carries is paired with a `<field>Override` boolean. `true` sends the value
/// stored here; `false` leaves the parameter unset in the resolved agent
/// config so the API preset's own value survives (`AgentConfigResolver` passes
/// `null` into `copyWithSampling` / `copyWithReasoning`, which fall back to
/// the preset). They default to `true` so an existing install keeps
/// applying exactly the values it applied before the flags existed.
///
/// Temperature, max tokens and the idle timeout have no flag: they already
/// encode "not overridden" as a sentinel (negative temperature, `0` tokens,
/// `0` ms) and fall back to the per-agent spec rather than to the preset.
@freezed
abstract class StudioAgentSettings with _$StudioAgentSettings {
  const factory StudioAgentSettings({
    // ── Global idle timeout ────────────────────────────────────────────────
    // Per-agent idle timeout (ms) before the model emits its first chunk.
    // Once any chunk (text or reasoning) arrives, the idle timer is
    // cancelled entirely so a long generation is never cut off. 0 = use the
    // per-agent fallback (final generator: 90s, trackers: 60s).
    @Default(0) int studioTimeoutMs,

    // ── Final generator (Main Writer) ──────────────────────────────────
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
    // Override flags for the sampling parameters above. false = leave the
    // parameter unset so the selected API preset's value is used.
    @Default(true) bool studioFinalTopPOverride,
    @Default(true) bool studioFinalTopKOverride,
    @Default(true) bool studioFinalFrequencyPenaltyOverride,
    @Default(true) bool studioFinalPresencePenaltyOverride,
    // Chat history messages override for the final generator. When > 0,
    // overrides StudioPreset.maxFinalHistoryMessages. 0 = use preset
    // StudioConfig default (30).
    @Default(0) int studioFinalContextSize,
    // Temperature for the final generator. When >= 0, overrides the per-agent
    // default (0.8). Negative = use the agent's own temperature.
    @Default(1.0) double studioFinalTemperature,
    @Default(false) bool studioFinalRequestReasoning,
    @Default(true) bool studioFinalShowNativeReasoning,
    @Default(false) bool studioFinalUseResponsesApi,
    @Default('auto') String studioFinalReasoningEffort,
    @Default(false) bool studioFinalOmitTemperature,
    @Default(false) bool studioFinalOmitTopP,
    @Default(true) bool studioFinalOmitReasoning,
    @Default(true) bool studioFinalOmitReasoningEffort,
    // Override flags for the reasoning parameters above. `RequestReasoning`
    // covers the paired `OmitReasoning` flag and `ReasoningEffort` covers
    // `OmitReasoningEffort` — each pair is one control in the UI.
    @Default(true) bool studioFinalRequestReasoningOverride,
    @Default(true) bool studioFinalShowNativeReasoningOverride,
    @Default(true) bool studioFinalUseResponsesApiOverride,
    @Default(true) bool studioFinalReasoningEffortOverride,
    // Include reasoning_content from the N most recent assistant messages in
    // final-generator history. -1 includes all retained history; 0 disables it.
    @Default(0) int studioFinalReasoningHistoryCount,
    // When true, reasoning tokens are still sent to the provider but are NOT
    // counted toward the history trim budget for the final generator. This
    // lets more chat history fit when reasoning blocks are large. Overrides
    // the API config flag when the Studio final slot is active.
    @Default(false) bool studioFinalExcludeReasoningFromContextBudget,
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
    @Default('') String studioControllerModelOverride,
    // Tracker idle timeout (ms). 0 = use agent/global fallback.
    @Default(0) int studioControllerTimeoutMs,
    // Max tokens for ALL non-final Studio agents. When > 0, overrides the
    // per-agent default (1600). 0 = use the agent's own maxTokens.
    @Default(0) int studioControllerMaxTokens,
    @Default(0.9) double studioControllerTopP,
    @Default(0) int studioControllerTopK,
    @Default(0.0) double studioControllerFrequencyPenalty,
    @Default(0.0) double studioControllerPresencePenalty,
    // Override flags for the sampling parameters above. false = leave the
    // parameter unset so the selected API preset's value is used.
    @Default(true) bool studioControllerTopPOverride,
    @Default(true) bool studioControllerTopKOverride,
    @Default(true) bool studioControllerFrequencyPenaltyOverride,
    @Default(true) bool studioControllerPresencePenaltyOverride,
    // Temperature for ALL non-final Studio agents. When >= 0, overrides the
    // per-agent default (0.3). Negative = use the agent's own temperature.
    @Default(0.5) double studioControllerTemperature,
    @Default(false) bool studioControllerRequestReasoning,
    @Default(true) bool studioControllerShowNativeReasoning,
    @Default(false) bool studioControllerUseResponsesApi,
    @Default('auto') String studioControllerReasoningEffort,
    @Default(false) bool studioControllerOmitTemperature,
    @Default(false) bool studioControllerOmitTopP,
    @Default(true) bool studioControllerOmitReasoning,
    @Default(true) bool studioControllerOmitReasoningEffort,
    // Override flags for the reasoning parameters above. `RequestReasoning`
    // covers the paired `OmitReasoning` flag and `ReasoningEffort` covers
    // `OmitReasoningEffort` — each pair is one control in the UI.
    @Default(true) bool studioControllerRequestReasoningOverride,
    @Default(true) bool studioControllerShowNativeReasoningOverride,
    @Default(true) bool studioControllerUseResponsesApiOverride,
    @Default(true) bool studioControllerReasoningEffortOverride,
    // When true, all non-final Studio agent requests force
    // requestReasoning=false and omitReasoning=true. Trackers emit compact
    // JSON briefs, so a hidden think-block wastes tokens. Gemini-only.
    @Default(false) bool studioControllerDisableReasoning,
    // Context size for ALL non-final Studio agents (batch + individual).
    // This is the single source of truth — per-agent contextSize is ignored.
    @Default(8) int studioControllerContextSize,
    @Default(<ExtraRequestParameter>[])
    List<ExtraRequestParameter> studioControllerExtraRequestParameters,

    // ── Post-processing trackers ──────────────────────────────────────────
    // Number of trailing chat messages forwarded to post-processing
    // (post-gen) trackers. Default 1 (only the response to edit).
    @Default(1) int studioPostControllerContextSize,
  }) = _StudioAgentSettings;

  factory StudioAgentSettings.fromJson(Map<String, dynamic> json) =>
      _$StudioAgentSettingsFromJson(_normalizeStudioAgentSettingsJson(json));
}

Map<String, dynamic> _normalizeStudioAgentSettingsJson(
  Map<String, dynamic> json,
) {
  final n = Map<String, dynamic>.from(json);
  for (final oldKey
      in n.keys.where((k) => k.startsWith('studioTracker')).toList()) {
    final newKey = oldKey.replaceFirst('studioTracker', 'studioController');
    if (!n.containsKey(newKey)) {
      n[newKey] = n[oldKey];
    }
  }
  n.putIfAbsent(
    'studioFinalReasoningHistoryCount',
    () => n['studioFinalIncludeLastReasoning'] == true ? 1 : 0,
  );
  return n;
}
