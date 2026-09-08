import 'package:freezed_annotation/freezed_annotation.dart';

import 'extension_context_policy.dart';

part 'block_config.freezed.dart';
part 'block_config.g.dart';

enum BlockType { infoblock, imageGen, jsRunner, interactive }

enum BlockTrigger { afterUser, afterAssistant, periodic }

@freezed
abstract class BlockConfig with _$BlockConfig {
  const factory BlockConfig({
    required String id,
    required String name,
    @Default(BlockType.infoblock) BlockType type,
    @Default(true) bool enabled,
    @Default(BlockTrigger.afterAssistant) BlockTrigger trigger,
    @Default('') String prompt,
    @Default(0) int order,
    @Default(false) bool dependsOnPrevious,
    // Plan §User ExtBlocks: "User InfBlocks should be visible in panels by
    // default, but not injected into main generation unless the user explicitly
    // opts in." Default false = panel-only; the user must opt in to inject.
    @Default(false) bool inject,
    @Default(1) int injectLastN,

    /// Optional text inserted after `\\n\\n` and before the injected block body
    /// in main chat history (e.g. a note that the block is reference-only).
    @Default('') String injectPrefix,
    @Default('') String apiConfigId,
    @Default('') String model,

    /// When true, LLM output is pushed to the ext-blocks panel incrementally
    /// during generation (infoblock + image agent steps).
    @Default(false) bool streamToPanel,
    // Image-specific
    @Default('') String imagePromptInstruction,
    @Default(true) bool imageGenEnabled,
    // Context control (Phase 9)
    /// Number of recent messages to include as context for this block,
    /// counted backward from the message the block is attached to (inclusive).
    /// 0 = only character card + system prompt, -1 = entire history up to anchor.
    @Default(10) int contextMessageCount,

    /// Additional system text prepended before chat history.
    /// Supports macros: {{char}}, {{user}}, {{description}}, {{personality}}.
    @Default('') String contextSystemPrompt,

    /// Controls which parts of the main request are visible to this block.
    @Default(ExtensionContextPolicy()) ExtensionContextPolicy contextPolicy,

    /// Number of this block's own previous outputs (same [name], same session,
    /// from earlier messages) to feed into the generation prompt as reference,
    /// so a new run can continue/update the prior state instead of starting
    /// from scratch. 0 = disabled (default).
    @Default(0) int previousBlocksCount,
    // JS Runner (Phase 10)
    /// Legacy static script (used only when [prompt] is empty). Prefer LLM prompt.
    @Default('') String script,
    // Template (upstream parity)
    /// XML-like skeleton that defines the block's shape. Sent to the LLM as
    /// part of the system message so the model knows the exact tag layout to
    /// output. Supports `{{name}}` macro (substituted with [name] at runtime).
    /// When non-empty, the LLM response is also extracted by parsing this
    /// template's tag pair out of the raw reply.
    @Default('<{{name}}>\n\n</{{name}}>') String template,
    // Periodic trigger (Phase 11)
    /// Number of seconds between runs when [trigger] is
    /// [BlockTrigger.periodic]. The block's JS script is executed in the
    /// headless engine every `periodicIntervalSeconds` seconds while
    /// extensions are enabled. Ignored for other trigger types.
    @Default(60) int periodicIntervalSeconds,

    /// When true, the block is never triggered automatically (afterUser,
    /// afterAssistant, periodic). It only runs when the user presses
    /// "Run All" / "Rerun" manually from the ext-blocks panel.
    @Default(false) bool manualOnly,
  }) = _BlockConfig;

  factory BlockConfig.fromJson(Map<String, dynamic> json) =>
      _$BlockConfigFromJson(json);
}
