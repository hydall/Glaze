import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../llm/studio/studio_context.dart';
import 'ledger_prompt_injection_mode.dart';

part 'studio_config.freezed.dart';
part 'studio_config.g.dart';

enum StudioBlockType { instruction, context, history, priorBriefs }

/// Legacy persisted selector retained for Studio preset JSON compatibility.
/// Runtime extraction always uses [currentReconciled].
enum StudioLedgerEngine { currentReconciled, legacyTurnOnly }

/// Per-preset runtime metadata that is NOT duplicated by global
/// [PipelineSettings]. Model overrides, sampling parameters, and cleaner /
/// ledger settings live exclusively in [PipelineSettings] so the UI and the
/// runtime read from the same source. [StudioRuntimeSettings] carries only
/// fields that are genuinely per-preset.
@freezed
abstract class StudioRuntimeSettings with _$StudioRuntimeSettings {
  const factory StudioRuntimeSettings({
    @Default(1) int version,
    @Default([]) List<String> broadcastBlocks,
    @JsonKey(unknownEnumValue: StudioLedgerEngine.currentReconciled)
    @Default(StudioLedgerEngine.currentReconciled)
    StudioLedgerEngine ledgerEngine,
    LedgerPromptInjectionMode? requestedLedgerPromptInjectionMode,
    String? requestedLedgerPromptInjectionAlgorithmVersion,
  }) = _StudioRuntimeSettings;

  factory StudioRuntimeSettings.fromJson(Map<String, dynamic> json) =>
      _$StudioRuntimeSettingsFromJson(json);
}

/// Reusable Studio configuration profile.
///
/// Created when the user clicks "Build Studio" in the MagicDrawer Studio menu.
/// Agents are built from [StudioControllerOntology.specs] directly — no LLM
/// decomposition. Prompt shards come from the DB-backed StudioPreset.
@freezed
abstract class StudioConfig with _$StudioConfig {
  const factory StudioConfig({
    required String sessionId,
    @Default(false) bool enabled,
    @Default(0) int createdAt,
    @Default(0) int updatedAt,
  }) = _StudioConfig;

  factory StudioConfig.fromJson(Map<String, dynamic> json) =>
      _$StudioConfigFromJson(json);
}

@freezed
abstract class StudioPresetBlock with _$StudioPresetBlock {
  const factory StudioPresetBlock({
    required String id,
    @Default('') String title,
    @Default(StudioBlockType.instruction) StudioBlockType type,
    StudioContextSlot? contextSlot,
    String? targetAgentId,
    @Default('system') String role,
    @Default('') String content,
    @Default(true) bool enabled,
    @Default(false) bool locked,
    @Default(0) int order,
    @Default('pregen') String section,
    @Default('direct') String mode,
    @Default(false) bool isStatic,
    @Default('pregen') String injectionPoint,
    @Default('') String sourceAgentId,
    @Default('none') String groupBoundary,
  }) = _StudioPresetBlock;

  factory StudioPresetBlock.fromJson(Map<String, dynamic> json) =>
      _$StudioPresetBlockFromJson(json);
}

/// A complete Studio preset: a flat list of [StudioPresetBlock]s grouped by
/// `section` (`pregen`, `final`, `cleaner`, `ledger`, `build`,
/// `brief_parser`). Stored in `studio_preset_rows` as a JSON blob.
@freezed
abstract class StudioPreset with _$StudioPreset {
  const factory StudioPreset({
    required String id,
    @Default('') String name,
    @Default([]) List<StudioPresetBlock> blocks,
    @Default([]) List<StudioAgent> agents,
    @Default('') String expensiveApiConfigId,
    @Default('') String cheapApiConfigId,
    @Default('') String cleanerApiConfigId,
    @Default('') String ledgerApiConfigId,

    /// Maximum trailing messages sent to the final generator. Trackers use
    /// their own [StudioAgent.contextSize]. 0 disables the message-count cap.
    @Default(30) int maxFinalHistoryMessages,

    /// Per-agent on/off overrides keyed by controller spec id
    /// (e.g. `'continuity'`, `'narrative'`, `'final'`).
    /// An entry `false` disables the agent; `true` or absent = enabled.
    /// Travel with the preset on import/export so agent toggles are portable.
    @Default({}) Map<String, bool> agentEnabled,

    /// Agent states that were auto-disabled due to a cascade dependency
    /// (e.g. Continuity was turned off because Ledger was disabled).
    /// Restored when the required agent is re-enabled.
    @Default({}) Map<String, bool> agentEnabledBeforeDependencyOff,

    /// Per-agent restore state for the controller radio-folder feature.
    ///
    /// When a controller is enabled, the block IDs that were enabled and are
    /// listed as its alternatives are saved here so that disabling the
    /// controller can restore them. Keyed by controller spec id.
    @Default({}) Map<String, List<String>> agentBlockRestoreState,

    /// Per-controller mapping of specId → list of block IDs that the
    /// controller replaces. When the controller is toggled ON, these blocks
    /// are disabled (and saved for restore). When toggled OFF, they are
    /// restored. Blocks not in this list are left untouched (add-ons).
    @Default({}) Map<String, List<String>> controllerAlternativeBlockIds,

    @Default(StudioRuntimeSettings()) StudioRuntimeSettings runtime,
    @Default(0) int updatedAt,
  }) = _StudioPreset;

  factory StudioPreset.fromJson(Map<String, dynamic> json) =>
      _$StudioPresetFromJson(json);
}

/// A single agent in the Studio pipeline.
///
/// Each agent receives:
/// - Its instructions (resolved from the DB StudioPreset at runtime)
/// - Compact memory context (from Memory Book)
/// - Briefs from previous agents in the pipeline
///
/// The [order] field determines pipeline execution order.
///
/// Generation parameters (model, temperature, max tokens, timeout, context
/// size) and cadence (run interval, keyword activation, run-individually) are
/// deliberately NOT here: an agent's identity is pinned to its
/// [StudioControllerSpec] (§4), so those come from the spec, from the Studio
/// slot settings, or from the chat's own connection. A per-agent copy could
/// only drift from the spec it was built from.
@freezed
abstract class StudioAgent with _$StudioAgent {
  const factory StudioAgent({
    required String id,
    @Default('') String controllerId,
    @Default('') String name,
    @Default('') String role,
    @Default(0) int order,
    @Default(true) bool enabled,
    @Default('') String specId,

    /// Controls whether an intermediate agent should be refreshed every turn
    /// or can reuse a previous brief. Supported values: static, scene, turn.
    /// Final agents always run every turn.
    @Default('turn') String refreshPolicy,

    /// Maximum number of parallel jobs this agent can be split into inside a
    /// batch group (Marinara `AgentSettings.maxParallelJobs`, clamped to
    /// `[1, 16]` on use). For MVP this is effectively always 1 — one batch
    /// group = one LLM request — but the field is kept so the model can grow
    /// later without a migration.
    @Default(1) int maxParallelJobs,

    /// Which phase this agent runs in. `pre_generation` (default) = runs
    /// before the final generator, produces a brief that feeds into the
    /// generator's prompt. `post_processing` = runs after the generator
    /// produces its response, receives the response as `mainResponse`, and
    /// can produce an edited/rewritten version. The final generator (last
    /// enabled agent with `phase: 'pre_generation'`) always runs.
    @Default('pre_generation') String phase,
  }) = _StudioAgent;

  factory StudioAgent.fromJson(Map<String, dynamic> json) =>
      _$StudioAgentFromJson(json);

  /// Forces certain agent types to a specific phase regardless of user
  /// config. Currently a no-op stub: Glaze agents are arbitrary
  /// user-defined (no built-in typed controllers like Marinara's
  /// `prose-guardian` / `continuity`), so the user's configured
  /// [configuredPhase] is always respected.
  static String normalizeAgentPhaseForType(
    String agentId,
    String configuredPhase,
  ) {
    return configuredPhase;
  }
}
