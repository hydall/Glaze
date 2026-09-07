/// Translated sentences for the raw diagnostic codes the two retrieval layers
/// record — why an entry did or did not reach the prompt, and how it got in.
///
/// The codes themselves (`chunk_rank_trimmed`, `worldInfoAfter`, `full_entry`…)
/// are storage identifiers, not copy: they used to be printed verbatim into the
/// coverage rows, which left the panel half-English and squeezed the entry's
/// own name out of the line. Everything here returns a full localized sentence
/// meant to be rendered in the *expanded* record, where it can wrap instead of
/// being clipped to a single line.
library;

import 'package:easy_localization/easy_localization.dart';

import '../../../../core/llm/lorebook_coverage.dart';

/// Why a memory candidate was or was not selected. Falls back to the raw code
/// so an unknown reason is still readable rather than silently dropped.
String memoryReasonLabel(String reason) => switch (reason) {
  'selected' => 'coverage_memory_reason_selected'.tr(),
  'source_visible_in_prompt' => 'coverage_memory_reason_source_visible'.tr(),
  'budget_trimmed' => 'coverage_memory_reason_budget'.tr(),
  'entry_cap' => 'coverage_memory_reason_entry_cap'.tr(),
  'chunk_budget_trimmed' => 'coverage_memory_reason_chunk_budget'.tr(),
  'chunk_rank_trimmed' => 'coverage_memory_reason_chunk_rank'.tr(),
  _ => 'coverage_memory_reason_other'.tr(args: [reason]),
};

/// How a selected memory reached the prompt: the whole entry, or the excerpt
/// chunks that fit. Null for a candidate that was never injected — its reason
/// line already says everything there is to say.
String? memoryInjectionLabel(String injectionType) => switch (injectionType) {
  'excerpt' => 'coverage_memory_injection_excerpt'.tr(),
  'full_entry' => 'coverage_memory_injection_full'.tr(),
  _ => null,
};

/// Which retrieval layers fired for a memory candidate, as one sentence.
String? memoryTriggerLabel({
  required bool keyword,
  required bool vector,
  required bool catalog,
}) {
  final parts = <String>[
    if (keyword) 'coverage_trigger_keyword'.tr(),
    if (vector) 'coverage_trigger_vector'.tr(),
    if (catalog) 'coverage_trigger_catalog'.tr(),
  ];
  if (parts.isEmpty) return null;
  return 'coverage_memory_triggers'.tr(args: [parts.join(', ')]);
}

/// Where an entry is inserted in the prompt. Covers both the lorebook coverage
/// positions and the classifications a past turn's manifest records.
String coveragePositionLabel(String position) => switch (position) {
  'worldInfoBefore' => 'position_before'.tr(),
  'worldInfoAfter' => 'position_after'.tr(),
  'lorebooksMacro' => 'position_macro'.tr(),
  'charDescription' => 'position_char_description'.tr(),
  'charPersonality' => 'position_char_personality'.tr(),
  'charScenario' => 'position_char_scenario'.tr(),
  'matchGlobal' => 'position_match_global'.tr(),
  _ => position,
};

/// What activated an entry in a past turn's manifest.
String manifestSourceLabel(String source) => switch (source) {
  'constant' => 'coverage_source_constant'.tr(),
  'keyword' => 'coverage_source_keyword'.tr(),
  'vector' => 'coverage_source_vector'.tr(),
  _ => source,
};

/// Every sentence a lorebook coverage entry has earned, in reading order: the
/// verdict first (in or out, and which cap cut it), then what qualifies it.
List<String> lorebookCoverageReasons(CoverageEntry entry) => [
  if (!entry.activated)
    entry.onCooldown
        ? 'coverage_lore_status_cooldown'.tr()
        : 'coverage_lore_status_inactive'.tr()
  else
    switch (entry.cutOff) {
      CoverageCutOff.budget => 'coverage_lore_status_cut_budget'.tr(),
      CoverageCutOff.bookLimit => 'coverage_lore_status_cut_book_limit'.tr(),
      null => 'coverage_lore_status_injected'.tr(),
    },
  if (entry.constant) 'coverage_lore_status_constant'.tr(),
  if (entry.matchedKeys.length == 1 && entry.matchedKeys.first == '[vector]')
    'coverage_lore_status_vector'.tr(),
  if (entry.viaRecursion)
    'coverage_lore_status_recursion'.tr(args: ['${entry.recursionPass}']),
  if (entry.stickyHeld) 'coverage_lore_status_sticky'.tr(),
  'coverage_lore_position'.tr(args: [coveragePositionLabel(entry.position)]),
];
