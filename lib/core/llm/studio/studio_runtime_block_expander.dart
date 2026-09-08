import '../macro_engine.dart';
import '../prompt_builder.dart';
import '../studio_context_bucketizer.dart';
import '../studio_stage_brief.dart';
import '../../models/studio_config.dart';
import 'studio_brief_macro_renderer.dart';

/// Chat-time Studio block expansion + block filtering + role normalization.
/// Extracted from `StudioMessageBuilder` (plan Phase 5b).
///
/// This is distinct from build-time block expansion, which handles
/// `{{setvar}}`/`{{getvar}}`/`{{trim}}` at preset-routing time. This class
/// expands `{{char}}`, `{{user}}`, `{{studio_*_brief}}` and all other
/// chat-time macros inside block content at generation time.
///
/// Deps: [StudioBriefMacroRenderer] for `{{studio_*_brief}}` macros.
class StudioRuntimeBlockExpander {
  final StudioBriefMacroRenderer _briefMacroRenderer;

  StudioRuntimeBlockExpander(this._briefMacroRenderer);

  /// Expand all macros in [content]: first `{{studio_*_brief}}` macros, then
  /// the standard `MacroContext` macros (`{{char}}`, `{{user}}`, etc.).
  String expandStudioBlockContent(
    String content, {
    required PromptPayload promptPayload,
    required PromptResult promptResult,
    required StudioContextBuckets context,
    List<StudioStageBrief> priorBriefs = const [],
    StudioConfig? config,
  }) {
    if (!content.contains('{')) return content;
    final studioExpanded = _briefMacroRenderer.replaceStudioBriefMacros(
      content,
      priorBriefs: priorBriefs,
      config: config,
    );
    final macroCtx = MacroContext(
      charName: promptPayload.character.name,
      charDescription: promptPayload.character.description,
      charScenario: promptPayload.character.scenario,
      charPersonality: promptPayload.character.personality,
      charMesExample: promptPayload.character.mesExample,
      userName: promptPayload.persona?.name ?? 'User',
      personaPrompt: promptPayload.persona?.prompt,
      reasoningStart: promptPayload.preset?.reasoningStart,
      reasoningEnd: promptPayload.preset?.reasoningEnd,
      sessionVars: promptResult.sessionVars,
      globalVars: promptResult.globalVars,
      charId: promptPayload.character.id,
      sessionId: promptPayload.sessionId ?? '',
      summaryContent:
          promptPayload.summaryContent ?? context.joinKind('summary'),
      memoryContent:
          promptPayload.memoryMacroContent ??
          promptPayload.memoryContent ??
          context
              .joinKind('memory')
              .ifBlank(context.taggedDynamicContent('summary')),
      lorebooksContent:
          [
                context.joinKind('worldInfoBefore'),
                context.joinKind('worldInfoAfter'),
              ]
              .where((value) => value.trim().isNotEmpty)
              .join('\n\n')
              .ifBlank(context.taggedDynamicContent('lorebooks')),
      guidanceText: promptPayload.guidanceText,
      macroName: promptPayload.character.macroName,
      arcContent: promptPayload.arcContent,
      entitiesContent: promptPayload.entitiesContent,
      studioSessionState: promptPayload.studioSessionStateContent,
    );
    return replaceMacros(studioExpanded, macroCtx).text;
  }

  /// Returns the pipeline section for this run: `final` for the generator,
  /// `cleaner` for post-processing trackers, `pregen` for pre-gen trackers.
  String sectionForRun(StudioAgent agent, bool isFinalResponse) {
    if (isFinalResponse) return 'final';
    if (agent.phase == 'post_processing') return 'cleaner';
    return 'pregen';
  }

  /// True if [block] has a runtime-computed ID (its content is injected by
  /// the pipeline, not by the preset).
  bool isRuntimeComputedBlock(StudioPresetBlock block) {
    return const {
      'runtime_envelope',
      'brief_usage_note',
      'hard_style_contract',
      'beauty_shard_contract',
    }.contains(block.id);
  }

  /// True if [block] applies to [agent] in this run context. Only
  /// `tracker_instruction` blocks are filtered; other kinds always apply.
  bool blockAppliesToAgent(
    StudioPresetBlock block,
    StudioAgent agent,
    bool isFinalResponse,
  ) {
    if (block.kind != 'tracker_instruction') return true;
    if (isFinalResponse || agent.phase == 'post_processing') return false;
    return trackerInstructionAppliesToAgent(block, agent);
  }

  /// True if a `tracker_instruction` block's controller alias matches the
  /// agent's ID/name. Uses the same alias map as the brief-macro renderer.
  bool trackerInstructionAppliesToAgent(
    StudioPresetBlock block,
    StudioAgent agent,
  ) {
    final agentText = '${agent.id}\n${agent.name}'.toLowerCase();
    final blockText = '${block.id}\n${block.title}'.toLowerCase();
    const aliases = <String, List<String>>{
      'continuity': ['continuity'],
      'agency': ['agency', 'character'],
      'narrative': ['narrative', 'pacing', 'style'],
      'dialogue': ['dialogue'],
      'guard': ['guard', 'loop', 'prose'],
      'world': ['world', 'npc'],
      'meta': ['meta', 'ooc', 'lumia'],
      'beauty': ['beauty'],
    };
    for (final entry in aliases.entries) {
      if (!entry.value.any(agentText.contains)) continue;
      return entry.value.any(blockText.contains);
    }
    return false;
  }

  /// Normalize the role of a preset/shard INSTRUCTION block (not a chat
  /// history message). Instruction blocks are always forced to `system` so
  /// the model treats them as authoritative directives, not user dialogue.
  String normalizeInstructionRole(String role) {
    return 'system';
  }
}

extension _BlankStringFallback on String {
  String ifBlank(String fallback) => trim().isEmpty ? fallback : this;
}
