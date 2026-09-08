import 'package:freezed_annotation/freezed_annotation.dart';

import 'extra_request_parameter.dart';

part 'cleaner_settings.freezed.dart';
part 'cleaner_settings.g.dart';

/// POST-cleaner settings — anti-cliche rewrite, continuity/character audit,
/// and prose-guardian style overrides.
///
/// Nested inside [PipelineSettings] under the `cleaner` field. The cleaner is
/// always-on (Studio-only) — there is no enabled toggle. API config is
/// resolved by [StudioSlotResolver] from `StudioConfig.cleanerApiConfigId`;
/// `postCleanerModel` overrides the slot's model when non-empty.
@freezed
abstract class CleanerSettings with _$CleanerSettings {
  const factory CleanerSettings({
    @Default(0.7) double postCleanerTemperature,
    @Default(0) int postCleanerMaxTokens,
    @Default(0.9) double postCleanerTopP,
    @Default(0) int postCleanerTopK,
    @Default(0.0) double postCleanerFrequencyPenalty,
    @Default(0.0) double postCleanerPresencePenalty,
    // ── Model override + timeout ───────────────────────────────────────────
    // Model id override for the cleaner. When non-empty, replaces the Studio
    // cleaner slot's model. Empty = use the slot's configured model.
    @Default('') String postCleanerModel,
    @Default(0) int postCleanerTimeoutMs,
    // ── Cleaner context ───────────────────────────────────────────────────
    @Default(12) int postCleanerHistoryMessages,
    @Default(3000) int postCleanerMaxCharsPerMessage,
    // Optional model override for the character/world audit pass. When empty,
    // the audit inherits the cleaner's resolved model. Endpoint/key/source/
    // protocol are always inherited from the cleaner config — only the model
    // can differ.
    @Default('') String postCleanerAuditModel,
    // ── Prose-guardian style overrides ────────────────────────────────────
    // When non-empty, these flow into the cleaner prompt ALONGSIDE the
    // preset's broadcastBlocks. Empty = no override; the broadcast rules from
    // the preset remain authoritative.
    @Default('') String postCleanerBannedWords,
    @Default('') String postCleanerAvoidInstructions,
    @Default('') String postCleanerStyleInstructions,
    // ── Reasoning overrides ───────────────────────────────────────────────
    // When true, the cleaner request forces omitReasoning=true so Gemini
    // Flash thinking models cannot spend the rewrite budget on a think-block.
    @Default(false) bool postCleanerDisableReasoning,
    @Default(false) bool postCleanerRequestReasoning,
    @Default(false) bool postCleanerUseResponsesApi,
    @Default('auto') String postCleanerReasoningEffort,
    @Default(false) bool postCleanerOmitTemperature,
    @Default(false) bool postCleanerOmitTopP,
    @Default(true) bool postCleanerOmitReasoning,
    @Default(true) bool postCleanerOmitReasoningEffort,
    @Default(<ExtraRequestParameter>[])
    List<ExtraRequestParameter> postCleanerExtraRequestParameters,
    // ── Enable toggle ─────────────────────────────────────────────────────
    // Master toggle for the post-cleaner rewrite + fact-checker. When false,
    // both the cleaner LLM call and the audit pass are skipped on the auto
    // path — ExtBlocks and Ledger still run on the original (un-cleaned)
    // assistant text. Manual rerun always runs the cleaner regardless.
    @Default(true) bool postCleanerEnabled,
  }) = _CleanerSettings;

  factory CleanerSettings.fromJson(Map<String, dynamic> json) =>
      _$CleanerSettingsFromJson(json);
}
