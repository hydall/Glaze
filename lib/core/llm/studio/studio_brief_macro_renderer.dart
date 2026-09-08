import '../studio_brief_deduper.dart';
import '../studio_stage_brief.dart';
import '../../models/studio_config.dart';

/// Renders `{{studio_*_brief}}` macros into expanded brief text. Extracted
/// from `StudioMessageBuilder` (plan Phase 5b).
///
/// Deps: [StudioBriefDeduper] for sanitizing + deduplicating prior briefs
/// before they're injected into macro positions.
class StudioBriefMacroRenderer {
  final StudioBriefDeduper _briefDeduper;

  static final studioBriefMacroRegex = RegExp(
    r'\{\{studio_(?:agent|tracker|continuity|agency|narrative|dialogue|guard|world|meta|beauty)_briefs?\}\}',
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
  /// corresponding expanded brief text from [priorBriefs].
  String replaceStudioBriefMacros(
    String content, {
    required List<StudioStageBrief> priorBriefs,
    StudioConfig? config,
  }) {
    if (!hasStudioBriefMacro(content)) return content;
    final briefs = finalBriefsForMacros(priorBriefs, config);
    final replacements = <String, String>{
      '{{studio_agent_briefs}}': renderBriefs(briefs),
      '{{studio_tracker_briefs}}': renderBriefs(briefs),
      '{{studio_continuity_brief}}': renderBriefs(
        briefsForController(briefs, 'continuity'),
      ),
      '{{studio_agency_brief}}': renderBriefs(
        briefsForController(briefs, 'agency'),
      ),
      '{{studio_narrative_brief}}': renderBriefs(
        briefsForController(briefs, 'narrative'),
      ),
      '{{studio_dialogue_brief}}': renderBriefs(
        briefsForController(briefs, 'dialogue'),
      ),
      '{{studio_guard_brief}}': renderBriefs(
        briefsForController(briefs, 'guard'),
      ),
      '{{studio_world_brief}}': renderBriefs(
        briefsForController(briefs, 'world'),
      ),
      '{{studio_meta_brief}}': renderBriefs(
        briefsForController(briefs, 'meta'),
      ),
      // Beauty brief is NOT injected into the final agent — the post-cleaner
      // owns beauty/styling application so the main model can focus on prose.
      '{{studio_beauty_brief}}': '',
    };
    var expanded = content;
    for (final entry in replacements.entries) {
      expanded = expanded.replaceAll(entry.key, entry.value);
    }
    return expanded;
  }

  List<StudioStageBrief> finalBriefsForMacros(
    List<StudioStageBrief> priorBriefs,
    StudioConfig? config,
  ) {
    final nonEmpty = priorBriefs
        .where((b) => b.brief.trim().isNotEmpty)
        .map(
          (b) => config == null
              ? b
              : _briefDeduper.sanitizePriorBriefForFinal(b, config),
        )
        .toList();
    return _briefDeduper
        .dedupePriorBriefs(nonEmpty)
        .where((b) => b.brief.trim().isNotEmpty)
        .toList();
  }

  List<StudioStageBrief> briefsForController(
    List<StudioStageBrief> briefs,
    String controller,
  ) {
    final aliases = const <String, List<String>>{
      'continuity': ['continuity'],
      'agency': ['agency', 'character'],
      'narrative': ['narrative', 'pacing', 'style'],
      'dialogue': ['dialogue'],
      'guard': ['guard', 'loop', 'prose'],
      'world': ['world', 'npc'],
      'meta': ['meta', 'ooc', 'lumia'],
      'beauty': ['beauty'],
    };
    final keys = aliases[controller] ?? const <String>[];
    return briefs.where((brief) {
      final text = '${brief.agentId}\n${brief.agentName}'.toLowerCase();
      return keys.any(text.contains);
    }).toList();
  }

  String renderBriefs(List<StudioStageBrief> briefs) {
    return briefs
        .map((b) => 'Studio agent brief: ${b.agentName}\n${b.brief.trim()}')
        .join('\n\n');
  }
}
