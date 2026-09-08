import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'studio_config.freezed.dart';
part 'studio_config.g.dart';

enum StudioExecutionMode {
  legacy,
  direct,
  assisted;

  String get wireName => name;

  static StudioExecutionMode fromWireName(String value) {
    return StudioExecutionMode.values.firstWhere(
      (mode) => mode.wireName == value,
      orElse: () => StudioExecutionMode.legacy,
    );
  }
}

/// Reusable Studio configuration profile.
///
/// Created when the user clicks "Build Studio" in the MagicDrawer Studio menu.
/// Agents are built from [StudioControllerOntology.specs] directly — no LLM
/// decomposition. Prompt shards come from the DB-backed StudioPreset.
@freezed
abstract class StudioConfig with _$StudioConfig {
  const factory StudioConfig({
    /// Storage id. Older rows used the chat session id; profile rows use a
    /// stable Studio profile id and can be reused by many sessions.
    required String sessionId,
    @Default('') String profileId,
    @Default('') String profileName,
    @Default(false) bool enabled,
    @Default([]) List<StudioAgent> agents,
    @Default('') String finalPresetId,
    @Default('') String runApiConfigId,
    @Default('') String expensiveApiConfigId,
    @Default('') String cheapApiConfigId,
    @Default('') String cleanerApiConfigId,
    @Default('') String runModelOverride,

    /// Maximum number of trailing user/assistant chat messages forwarded to the
    /// FINAL Studio agent (the generator). Trackers (intermediate agents) are
    /// trimmed per their own [StudioAgent.contextSize]. The final writer leans
    /// on the tracker briefs instead of re-reading the whole transcript.
    /// 0 = no message-count limit (a 60K token budget still applies).
    /// See [StudioHistoryLimiter.finalHistoryTokenBudget].
    @Default(30) int maxFinalHistoryMessages,

    /// Verbatim content of "broadcast" preset blocks — cross-cutting rules
    /// (output language + prose-quality guards: anti-loop/echo/cliché/slop,
    /// banlists) that must govern not only their primary agent but also the
    /// POST-cleaner rewrite. Captured at build time so the POST-cleaner can
    /// apply the user's own rules verbatim without re-running any LLM. Each
    /// entry is one block's `[Block: name]\n<content>` text.
    @Default([]) List<String> broadcastBlocks,
    @Default(0) int createdAt,
    @Default(0) int updatedAt,
  }) = _StudioConfig;

  factory StudioConfig.fromJson(Map<String, dynamic> json) =>
      _$StudioConfigFromJson(json);
}

@freezed
abstract class PromptShardBlock with _$PromptShardBlock {
  const factory PromptShardBlock({
    @Default('system') String role,
    @Default('') String content,
    @Default('') String blockName,
    @Default('') String blockId,
  }) = _PromptShardBlock;

  factory PromptShardBlock.fromJson(Map<String, dynamic> json) =>
      _$PromptShardBlockFromJson(json);
}

@freezed
abstract class StudioPresetBlock with _$StudioPresetBlock {
  const factory StudioPresetBlock({
    required String id,
    @Default('') String title,
    @Default('custom_text') String kind,
    @Default('system') String role,
    @Default('') String content,
    @Default(true) bool enabled,
    @Default(false) bool locked,
    @Default(0) int order,
    @Default('pregen') String section,
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

    /// Per-agent on/off overrides keyed by controller spec id
    /// (e.g. `'continuity'`, `'narrative'`, `'final'`).
    /// An entry `false` disables the agent; `true` or absent = enabled.
    /// Travel with the preset on import/export so agent toggles are portable.
    @Default({}) Map<String, bool> agentEnabled,

    /// Explicit topology prevents stale stored agents from reviving pregen
    /// calls when a Direct/Assisted preset is selected.
    @Default(StudioExecutionMode.legacy) StudioExecutionMode executionMode,
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
@freezed
abstract class StudioAgent with _$StudioAgent {
  const factory StudioAgent({
    required String id,
    @Default('') String name,
    @Default('') String role,
    @Default(0) int order,
    @Default(true) bool enabled,
    @Default('') String endpoint,
    @Default(4000) int timeoutMs,
    @Default(0.3) double temperature,
    @Default(8000) int maxTokens,
    @Default('') String sourceBlockNames,

    /// Controls whether an intermediate agent should be refreshed every turn
    /// or can reuse a previous brief. Supported values: static, scene, turn.
    /// Final agents always run every turn.
    @Default('turn') String refreshPolicy,
    @Default([]) List<String> invalidationSignals,

    /// Number of trailing chat messages forwarded to this tracker (intermediate
    /// agent). Default 5 to keep trackers focused on local turn state; the
    /// final agent ignores this and uses [StudioConfig.maxFinalHistoryMessages]
    /// instead. 0 = no limit (not recommended for trackers).
    @Default(5) int contextSize,

    /// How often this tracker runs, in assistant turns. 1 = every turn
    /// (default), 3 = every 3rd turn, etc. Useful for "director"-style
    /// trackers whose guidance changes slowly. The final agent (generator)
    /// always runs every turn regardless of this field.
    @Default(1) int runInterval,

    /// Maximum number of parallel jobs this agent can be split into inside a
    /// batch group (Marinara `AgentSettings.maxParallelJobs`, clamped to
    /// `[1, 16]` on use). For MVP this is effectively always 1 — one batch
    /// group = one LLM request — but the field is kept so the model can grow
    /// later without a migration.
    @Default(1) int maxParallelJobs,

    /// Force this tracker to run as its own individual LLM request, never
    /// batched with others. Set heuristically for "heavy" trackers whose large
    /// private extras must not leak into other trackers' batch prompt
    /// (Marinara `shouldRunAgentIndividually`). Default false.
    @Default(false) bool runIndividually,

    /// Optional keyword-activation gate for this tracker. When non-empty,
    /// the tracker activates ONLY on turns where at least one of these
    /// keywords appears in the last [activationScanDepth] chat messages
    /// (case-insensitive, whole-word-optional substring match). When empty
    /// (the default), the tracker always activates (subject to
    /// [runInterval] and [enabled]).
    @Default([]) List<String> activationKeywords,

    /// Number of trailing chat messages scanned for [activationKeywords].
    /// Default 5 (matches `DEFAULT_AGENT_CONTEXT_SIZE`). 0 = scan the
    /// entire available history (not recommended — expensive and stale).
    @Default(5) int activationScanDepth,

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
