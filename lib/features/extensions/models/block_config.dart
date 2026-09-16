import 'package:freezed_annotation/freezed_annotation.dart';

import 'block_context_item.dart';
import 'block_injection.dart';
import 'block_modes.dart';
import 'connection_profiles.dart';
import 'extension_context_policy.dart';

part 'block_config.freezed.dart';
part 'block_config.g.dart';

enum BlockType {
  infoblock,
  imageGen,
  jsRunner,
  interactive,

  /// Rewrites the character's own reply instead of adding a panel.
  rewrite,

  /// Carries a state document updated by an "updater" block rather than
  /// being regenerated from scratch each time.
  accumulation,
}

/// Whether the runtime can execute a block of this type.
///
/// Rewrite and accumulation blocks come in from the original extension's
/// exports and are fully editable here, but nothing runs them yet. Keeping
/// them out of the automatic chain is what stops an imported preset from
/// stamping an error card onto every message.
extension BlockTypeRunnable on BlockType {
  bool get isRunnable => switch (this) {
    BlockType.infoblock ||
    BlockType.imageGen ||
    BlockType.jsRunner ||
    BlockType.interactive => true,
    BlockType.rewrite || BlockType.accumulation => false,
  };
}

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

    // ── Upstream parity ────────────────────────────────────────────────────
    // Fields below mirror the original ExtBlocks extension one-for-one so its
    // exported blocks survive a round trip. [BlockTrigger] stays for the
    // existing Glaze block types; the two booleans are the original's own
    // trigger model, where a block may answer to both sides at once.
    /// Run after a user message.
    @Default(false) bool triggerOnUser,

    /// Run after a character message.
    @Default(true) bool triggerOnChar,

    /// Run after a swipe. Script blocks only.
    @Default(false) bool triggerOnSwipe,

    /// Pause the main reply when [keyword] shows up, run this block, resume.
    @Default(false) bool generationPause,

    /// Run once every this many messages. Ignored while [keyword] is set,
    /// which switches the block to keyword triggering.
    @Default(2) int period,

    /// Run whenever this string shows up in the triggering message.
    @Default('') String keyword,

    /// Treat [keyword] as a regular expression.
    @Default(false) bool keywordIsRegex,

    /// Keep the result out of the panel, leaving it visible only to the model.
    @Default(false) bool hideDisplay,

    /// Run without holding up the rest of the chain.
    @Default(false) bool background,

    /// Put the result through the user's own text replacements.
    @Default(false) bool applyRegex,

    /// Role the injected result is attributed to.
    @Default(InjectionRole.system) InjectionRole injectionRole,

    /// Where the injected result goes relative to the main prompt.
    @Default(InjectionPosition.afterMainPrompt)
    InjectionPosition injectionPosition,

    /// Depth for [InjectionPosition.inChat]. Negative counts from the start of
    /// the chat instead of the end.
    @Default(4) int injectionDepth,

    /// Ordered context sources for this block's request.
    @Default(<BlockContextItem>[]) List<BlockContextItem> context,

    /// Which of the three connection presets this block generates on.
    @Default(ConnectionProfile.big) ConnectionProfile apiPreset,

    /// Rewrite blocks: run before or after the generated blocks.
    @Default(BlockRunOrder.before) BlockRunOrder generationOrder,

    /// Script blocks: run before or after the generated blocks.
    @Default(BlockRunOrder.before) BlockRunOrder executionOrder,

    /// Rewrite blocks: whole text, or only the changed fragments.
    @Default(RewriteMode.full) RewriteMode rewriteMode,

    /// Script blocks: which language [script] is written in.
    @Default(ScriptType.js) ScriptType scriptType,

    /// Script blocks: run after the host's own commands have been handled.
    @Default(false) bool generationAfterCommands,

    /// Accumulation blocks: name of the block that carries the update
    /// operations. Must differ from [name].
    @Default('') String updaterName,
  }) = _BlockConfig;

  factory BlockConfig.fromJson(Map<String, dynamic> json) =>
      _$BlockConfigFromJson(json);
}
