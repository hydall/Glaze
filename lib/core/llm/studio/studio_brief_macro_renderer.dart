import '../studio_brief_deduper.dart';
import '../studio_controller_ontology.dart';
import '../studio_stage_brief.dart';
import '../../models/studio_config.dart';

/// Renders `{{studio_*_brief}}` macros into expanded brief text. Extracted
/// from `StudioMessageBuilder` (plan Phase 5b).
///
/// Macro names derive from the controller ontology (`{{studio_<specId>_brief}}`)
/// plus the `agent`/`tracker` all-briefs aliases — no hardcoded controller list,
/// so removed agents' macros resolve to empty and a new agent gets a macro for
/// free (STUDIO_UX_ANALYSIS §4/§5).
///
/// Deps: [StudioBriefDeduper] for sanitizing + deduplicating prior briefs
/// before they're injected into macro positions.
class StudioBriefMacroRenderer {
  final StudioBriefDeduper _briefDeduper;

  /// Matches any `{{studio_<name>_brief}}` / `{{studio_<name>_briefs}}` macro.
  static final studioBriefMacroRegex = RegExp(
    r'\{\{studio_\w+_briefs?\}\}',
    caseSensitive: false,
  );

  StudioBriefMacroRenderer(this._briefDeduper);

  /// True if [content] contains any `{{studio_*_brief}}` macro.
  bool hasStudioBriefMacro(String content) {
    return hasAnyStudioBriefMacro(content);
  }

  static bool hasAnyStudioBriefMacro(String content) =>
      studioBriefMacroRegex.hasMatch(content);

  static String stripStudioBriefMacros(String content) =>
      content.replaceAll(studioBriefMacroRegex, '');

  /// Replaces all `{{studio_*_brief}}` macros in [content] with the
  /// corresponding expanded brief text from [priorBriefs]. Macros for agents
  /// that no longer exist resolve to empty.
  String replaceStudioBriefMacros(
    String content, {
    required List<StudioStageBrief> priorBriefs,
    StudioPreset? preset,
  }) {
    if (!hasStudioBriefMacro(content)) return content;
    final briefs = finalBriefsForMacros(priorBriefs, preset);
    var expanded = content
        .replaceAll('{{studio_agent_briefs}}', renderBriefs(briefs))
        .replaceAll('{{studio_tracker_briefs}}', renderBriefs(briefs));
    for (final spec in StudioControllerOntology.specs) {
      final macro = '{{studio_${spec.id}_brief}}';
      if (expanded.contains(macro)) {
        expanded = expanded.replaceAll(
          macro,
          renderBriefs(briefsForController(briefs, spec.id)),
        );
      }
    }
    // Any macro left over targets a removed agent — resolve it to empty.
    return expanded.replaceAll(studioBriefMacroRegex, '');
  }

  List<StudioStageBrief> finalBriefsForMacros(
    List<StudioStageBrief> priorBriefs,
    StudioPreset? preset,
  ) {
    final nonEmpty = priorBriefs
        .where((b) => b.brief.trim().isNotEmpty)
        .map(
          (b) => preset == null
              ? b
              : _briefDeduper.sanitizePriorBriefForFinal(b, preset),
        )
        .toList();
    return _briefDeduper
        .dedupePriorBriefs(nonEmpty)
        .where((b) => b.brief.trim().isNotEmpty)
        .toList();
  }

  /// Briefs produced by the controller with [specId]. Matched on the runtime
  /// agent id (`agent_<session>_<specId>_<ts>`) or the spec's display name — the
  /// name-substring heuristics are gone (§4).
  List<StudioStageBrief> briefsForController(
    List<StudioStageBrief> briefs,
    String specId,
  ) {
    final spec = StudioControllerOntology.specs
        .where((s) => s.id == specId)
        .firstOrNull;
    final specName = spec?.name.toLowerCase() ?? '';
    return briefs.where((brief) {
      final id = brief.agentId.toLowerCase();
      return id.contains('_${specId}_') ||
          id.endsWith('_$specId') ||
          (specName.isNotEmpty && brief.agentName.toLowerCase() == specName);
    }).toList();
  }

  String renderBriefs(List<StudioStageBrief> briefs) {
    return briefs
        .map((b) => 'Studio agent brief: ${b.agentName}\n${b.brief.trim()}')
        .join('\n\n');
  }
}
