import 'package:easy_localization/easy_localization.dart';

import '../../core/llm/studio_controller_ontology.dart';

/// The injection points a block can be addressed to, in pipeline order (§5).
/// Shared by the editor's section list and the block editor's dropdown so the
/// two can never drift apart.
const studioInjectionPoints = <String>[
  'pregen',
  'specificAgent',
  'final',
  'cleaner',
  'ledger',
];

/// Localized label for an injection point. `final` reads as "Main Writer" — the
/// stage that writes the visible reply — rather than as the stored id. An
/// unknown point (a legacy row that escaped the §5 migration) falls back to the
/// raw value instead of being mislabelled.
String studioInjectionPointLabel(String point) => switch (point) {
  'pregen' => 'studio_point_pregen'.tr(),
  'specificAgent' => 'studio_point_specific_agent'.tr(),
  'final' => 'studio_point_final'.tr(),
  'output' => 'studio_point_output'.tr(),
  'cleaner' => 'studio_point_cleaner'.tr(),
  'ledger' => 'studio_point_ledger'.tr(),
  _ => point,
};

/// The agents that consume the blocks addressed to [point] — i.e. the ones the
/// section belongs to, listed above its blocks.
///
/// `specificAgent` has none: those blocks are routed per block through
/// `targetAgentId`, not to one fixed stage. The two post-processing agents each
/// own their own point (`cleaner` → Post Clean, `ledger` → Studio Ledger) even
/// though they share a phase.
List<StudioControllerSpec> studioAgentsForInjectionPoint(String point) {
  return switch (point) {
    'pregen' => [
      for (final spec in StudioControllerOntology.specs)
        if (!spec.isFinal && spec.phase != 'post_processing') spec,
    ],
    'final' => _specsWithIds(const ['final']),
    'cleaner' => _specsWithIds(const ['post_clean']),
    'ledger' => _specsWithIds(const ['ledger']),
    _ => const [],
  };
}

/// Exact-id lookup. [StudioControllerOntology.byId] falls back to the last spec
/// for an unknown id, which would silently put the Ledger in a stranger's
/// section.
List<StudioControllerSpec> _specsWithIds(List<String> ids) => [
  for (final spec in StudioControllerOntology.specs)
    if (ids.contains(spec.id)) spec,
];

/// Localized label for a block's mode (§5 "Режим") — what the block emits.
String studioBlockModeLabel(String mode) => switch (mode) {
  'pregenBrief' => 'studio_mode_pregen_brief'.tr(),
  'agentResponse' => 'studio_mode_agent_response'.tr(),
  'functionPrefill' => 'studio_mode_function_prefill'.tr(),
  _ => 'studio_mode_direct'.tr(),
};
