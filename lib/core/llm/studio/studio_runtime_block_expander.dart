import '../macro_engine.dart';
import '../studio_stage_brief.dart';
import '../studio_controller_ontology.dart';
import '../../models/studio_config.dart';
import 'studio_brief_macro_renderer.dart';
import 'studio_context.dart';

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

  String expandStudioBlockContent(
    String content, {
    required StudioContext context,
    List<StudioStageBrief> priorBriefs = const [],
    StudioPreset? preset,
  }) {
    if (!content.contains('{')) return content;
    final studioExpanded = _briefMacroRenderer.replaceStudioBriefMacros(
      content,
      priorBriefs: priorBriefs,
      preset: preset,
    );
    return replaceMacros(studioExpanded, context.macroContext).text;
  }

  /// Returns the injection point for this run: `final` for the generator,
  /// `cleaner` for Post Clean, `ledger` for Трекер, `pregen` for the
  /// pre-gen controllers. Matches [StudioPresetBlock.injectionPoint].
  String injectionPointForRun(StudioAgent agent, bool isFinalResponse) {
    if (isFinalResponse) return 'final';
    final specId = StudioControllerOntology.specForAgent(agent)?.id;
    if (specId == 'post_clean') return 'cleaner';
    if (specId == 'ledger') return 'ledger';
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


  /// Normalize the role of a preset/shard INSTRUCTION block (not a chat
  /// history message).
  ///
  /// Historically this forced every instruction block to `system` so a
  /// preset could not smuggle a `user`/`assistant` turn into the middle of
  /// the conversation (see git history: `a22353c4`, `05fa1bb3`, `5f5a23d5`).
  /// That protected against *legacy* presets that carried `role: 'user'` on
  /// every block by accident (e.g. Shino). Author-controlled `user`/
  /// `assistant` roles are now passed through unchanged so a preset can
  /// place a deliberate fake prior turn (e.g. a pre-agreed assistant
  /// response followed by a user confirmation) via block `order`, matching
  /// what SillyTavern-style presets already do. Only an empty/unsupported
  /// role falls back to `system`.
  String normalizeInstructionRole(String role) {
    switch (role) {
      case 'user':
      case 'assistant':
        return role;
      default:
        return 'system';
    }
  }
}
