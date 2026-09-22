import 'package:freezed_annotation/freezed_annotation.dart';

import 'block_context_item.dart';
import 'block_injection.dart';
import 'block_modes.dart';
import 'connection_profiles.dart';
import 'extension_context_policy.dart';

part 'block_config.freezed.dart';
part 'block_config.g.dart';

/// What a block *is*, which after the type unification means only how its
/// content is produced.
///
/// What used to be four separate kinds — infoblock, image, JS runner and
/// interactive panel — differed in what happened to the result, not in how it
/// was made: every one of them called the same generation and then handled the
/// text differently. Those differences are fields now ([BlockConfig.render],
/// the image tags in the content itself), so the enum matches the original
/// extension's one-for-one and a preset survives a round trip through it.
enum BlockType {
  /// Content from the model, or [BlockConfig.staticContent] when the block
  /// carries its own. Displayed as [BlockConfig.render] asks, and any image
  /// tag in it is drawn by the same pipeline that draws a chat message's.
  generated,

  /// JavaScript, either written by the model from [BlockConfig.prompt] or
  /// stored on the block in [BlockConfig.script], executed in the sandbox.
  script,

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
    BlockType.generated || BlockType.script => true,
    BlockType.rewrite || BlockType.accumulation => false,
  };
}

/// The block types this app used to have, and what each one is now.
///
/// `imageGen` and `interactive` were generated blocks that differed only in
/// what was done with the reply, so both come back as [BlockType.generated];
/// `interactive` also carries [BlockRender.panel], which is the part of it
/// that was real.
const Map<String, String> _legacyBlockTypes = {
  'infoblock': 'generated',
  'imageGen': 'generated',
  'interactive': 'generated',
  'jsRunner': 'script',
};

/// What an image block asked its agent for when it had no prompt of its own.
///
/// The old runtime hard-coded this for the image type. With that type gone the
/// instruction has nowhere to live but the block's own prompt, so migration
/// writes it there rather than letting those blocks come back empty.
const String legacyImageAgentPrompt =
    'Write the roleplay response, then append the visual HTML card with '
    '[IMG:GEN] / data-iig-instruction as instructed.';

/// Rewrites a block stored under the old six-type model onto the new four.
///
/// Applied inside [BlockConfig.fromJson], so every reader — the preset
/// repository, cloud sync, and the import of a single block — gets the same
/// result without having to know the old shape.
Map<String, dynamic> migrateLegacyBlockJson(Map<String, dynamic> json) {
  final rawType = json['type'];
  if (rawType is! String) return json;
  final unified = _legacyBlockTypes[rawType];
  if (unified == null) return json;

  final next = {...json, 'type': unified};

  switch (rawType) {
    case 'interactive':
      // Its HTML shared the `script` field with the JS runner's code. Now that
      // those are different types, the panel's markup gets a field of its own.
      final markup = json['script'];
      final existing = json['staticContent'];
      if (markup is String &&
          markup.trim().isNotEmpty &&
          (existing is! String || existing.isEmpty)) {
        next['staticContent'] = markup;
        next['script'] = '';
      }
      next['render'] ??= 'panel';

    case 'imageGen':
      final prompt = json['prompt'];
      if (prompt is! String || prompt.trim().isEmpty) {
        final legacy = json['imagePromptInstruction'];
        next['prompt'] = legacy is String && legacy.trim().isNotEmpty
            ? legacy
            : legacyImageAgentPrompt;
      }
  }

  // An image or JS block never had its reply read out of a template — the
  // editor wrote an empty one and the runtime skipped extraction outright.
  // Any template left on such a block is a leftover from before that rule, and
  // honouring it now would start parsing a reply that was never tagged.
  if (rawType == 'imageGen' || rawType == 'jsRunner') {
    next['template'] = '';
  }

  return next;
}

enum BlockTrigger { afterUser, afterAssistant, periodic }

@freezed
abstract class BlockConfig with _$BlockConfig {
  const factory BlockConfig({
    required String id,
    required String name,
    @Default(BlockType.generated) BlockType type,
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
    /// during generation.
    @Default(false) bool streamToPanel,

    /// Where the finished content is shown. A card in the panel, or a
    /// sandboxed iframe under the message.
    @Default(BlockRender.card) BlockRender render,

    /// Initial height, in pixels, of a [BlockRender.panel] iframe. It grows
    /// past this as the panel resizes itself.
    @Default(120) int panelMinHeight,

    /// Content the block carries itself, used instead of a generation when
    /// [prompt] is empty. For a [BlockType.generated] block this is its markup
    /// or text; [script] is the equivalent for [BlockType.script].
    @Default('') String staticContent,
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
    /// Script blocks: the code the block carries itself, run when [prompt] is
    /// empty instead of asking the model to write one.
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
      _$BlockConfigFromJson(migrateLegacyBlockJson(json));
}
