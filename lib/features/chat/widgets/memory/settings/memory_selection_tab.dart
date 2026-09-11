import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../core/llm/memory_budget.dart';
import '../../../../../shared/widgets/list_controls.dart';
import '../../../../../shared/widgets/menu_group.dart';
import 'memory_settings_draft.dart';

/// "Selection" — how many memories are chosen, how they are packed, and how
/// the retrieval query is built.
///
/// This is the section that used to hide behind an `ExpansionTile` which
/// defaulted to *open*, so the sheet's own "advanced" disclosure never
/// actually deferred anything. It is a tab now: the ordinary case never has to
/// scroll past it, and the sliders are `MenuRangeItem`s instead of bare
/// `Slider`s with a hand-built label row.
class MemorySelectionTab extends StatelessWidget {
  final MemorySettingsDraft draft;

  /// Called after any mutation of [draft] so the host can rebuild.
  final VoidCallback onChanged;

  /// Percent budget from the book being edited — one half of the effective
  /// injection budget, the other being the absolute cap set here.
  final double budgetPercent;

  final ScrollController? controller;

  const MemorySelectionTab({
    super.key,
    required this.draft,
    required this.onChanged,
    required this.budgetPercent,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: controller,
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top + 12,
        bottom: MediaQuery.paddingOf(context).bottom + 24,
      ),
      children: [
        MenuGroup(
          header: 'memory_budget'.tr(),
          items: [
            MenuRangeItem(
              label: 'memory_books_max_entries_prompt'.tr(),
              value: draft.maxInjected.toDouble(),
              min: 1,
              max: 20,
              divisions: 19,
              decimalPlaces: 0,
              editableValue: true,
              onChanged: (v) {
                draft.maxInjected = v.round();
                onChanged();
              },
            ),
            MenuSelectorItem(
              label: 'memory_budget'.tr(),
              currentValue: _budgetLabel(draft.memoryBudgetPreset),
              description: _effectiveBudgetHint(),
              onTap: () => _pickBudget(context),
            ),
            if (draft.memoryBudgetPreset == 'custom')
              MenuFieldItem(
                key: const Key('memory_custom_token_budget_field'),
                label: 'memory_max_tokens_label'.tr(),
                controller: draft.budgetController,
                placeholder: 'memory_max_tokens_hint'.tr(),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (value) {
                  final parsed = int.tryParse(value);
                  draft.maxInjectedTokens = parsed != null && parsed > 0
                      ? parsed
                      : null;
                  onChanged();
                },
              ),
          ],
        ),
        MenuGroup(
          header: 'memory_packing_mode'.tr(),
          items: [
            MenuSwitchItem(
              label: 'memory_excerpting_enabled'.tr(),
              description: 'memory_excerpting_auto_desc'.tr(),
              value: draft.memoryExcerptingEnabled,
              onChanged: (v) {
                draft.memoryExcerptingEnabled = v;
                onChanged();
              },
            ),
            if (draft.memoryExcerptingEnabled) ...[
              MenuSelectorItem(
                label: 'memory_packing_mode'.tr(),
                currentValue: _packingLabel(draft.memoryPackingMode),
                description: _packingDescription(draft.memoryPackingMode),
                onTap: () => _pickPacking(context),
              ),
              MenuRangeItem(
                label: 'memory_excerpt_tokens_per_chunk'.tr(),
                description: 'memory_excerpt_tokens_per_chunk_help'.tr(),
                value: draft.memoryExcerptTokensPerChunk.toDouble(),
                min: 100,
                max: 2000,
                divisions: 19,
                decimalPlaces: 0,
                editableValue: true,
                onChanged: (v) {
                  draft.memoryExcerptTokensPerChunk = v.round();
                  onChanged();
                },
              ),
              MenuRangeItem(
                label: 'memory_excerpt_chunks_per_entry'.tr(),
                description: 'memory_excerpt_chunks_per_entry_help'.tr(),
                value: draft.memoryExcerptChunksPerEntry.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                decimalPlaces: 0,
                editableValue: true,
                onChanged: (v) {
                  draft.memoryExcerptChunksPerEntry = v.round();
                  onChanged();
                },
              ),
              if (draft.memoryPackingMode == 'chunk_first') ...[
                MenuRangeItem(
                  label: 'memory_chunk_first_top_entries'.tr(),
                  description: 'memory_chunk_first_top_entries_help'.tr(),
                  value: draft.chunkFirstTopEntries.toDouble(),
                  min: 0,
                  max: 20,
                  divisions: 20,
                  decimalPlaces: 0,
                  editableValue: true,
                  onChanged: (v) {
                    draft.chunkFirstTopEntries = v.round();
                    onChanged();
                  },
                ),
                if (draft.chunkFirstTopEntries > 0)
                  MenuRangeItem(
                    label: 'memory_chunk_first_top_chunks'.tr(),
                    description: 'memory_chunk_first_top_chunks_help'.tr(),
                    value: draft.chunkFirstTopChunks.toDouble(),
                    min: 1,
                    max: 10,
                    divisions: 9,
                    decimalPlaces: 0,
                    editableValue: true,
                    onChanged: (v) {
                      draft.chunkFirstTopChunks = v.round();
                      onChanged();
                    },
                  ),
              ],
            ],
          ],
        ),
        MenuGroup(
          header: 'memory_selector_settings'.tr(),
          description: 'memory_selector_advanced_desc'.tr(),
          items: [
            MenuSwitchItem(
              label: 'memory_selector_diversity'.tr(),
              description: 'memory_selector_diversity_desc'.tr(),
              value: draft.diversityAware,
              onChanged: (v) {
                draft.diversityAware = v;
                onChanged();
              },
            ),
            if (draft.diversityAware)
              MenuRangeItem(
                label: 'memory_selector_diversity_penalty'.tr(),
                value: draft.diversityPenalty,
                min: 0,
                max: 1,
                divisions: 20,
                onChanged: (v) {
                  draft.diversityPenalty = v;
                  onChanged();
                },
              ),
            MenuSwitchItem(
              label: 'memory_selector_recency'.tr(),
              description: 'memory_selector_recency_desc'.tr(),
              value: draft.recencyBoost,
              onChanged: (v) {
                draft.recencyBoost = v;
                onChanged();
              },
            ),
            if (draft.recencyBoost)
              MenuRangeItem(
                label: 'memory_selector_recency_half_life'.tr(),
                description: 'memory_selector_recency_half_life_help'.tr(),
                value: draft.recencyHalfLifeDays,
                min: 10,
                max: 1000,
                divisions: 99,
                decimalPlaces: 1,
                onChanged: (v) {
                  draft.recencyHalfLifeDays = v;
                  onChanged();
                },
              ),
            MenuSwitchItem(
              label: 'memory_selector_importance'.tr(),
              description: 'memory_selector_importance_desc'.tr(),
              value: draft.importanceBoost,
              onChanged: (v) {
                draft.importanceBoost = v;
                onChanged();
              },
            ),
            if (draft.importanceBoost)
              MenuRangeItem(
                label: 'memory_selector_importance_weight'.tr(),
                value: draft.importanceWeight,
                min: 0,
                max: 2,
                divisions: 40,
                onChanged: (v) {
                  draft.importanceWeight = v;
                  onChanged();
                },
              ),
            MenuSwitchItem(
              label: 'memory_selector_exclude_visible'.tr(),
              description: 'memory_selector_exclude_visible_desc'.tr(),
              value: draft.sourceWindowExclusion,
              onChanged: (v) {
                draft.sourceWindowExclusion = v;
                onChanged();
              },
            ),
            MenuSwitchItem(
              label: 'memory_selector_continuity_guard'.tr(),
              description: 'memory_selector_continuity_guard_desc'.tr(),
              value: draft.factualContinuityGuardEnabled,
              onChanged: (v) {
                draft.factualContinuityGuardEnabled = v;
                onChanged();
              },
            ),
          ],
        ),
        MenuGroup(
          header: 'memory_selector_query_section'.tr(),
          items: [
            MenuSwitchItem(
              label: 'memory_selector_query_assistant'.tr(),
              description: 'memory_selector_query_assistant_desc'.tr(),
              value: draft.queryIncludeAssistant,
              onChanged: (v) {
                draft.queryIncludeAssistant = v;
                onChanged();
              },
            ),
            MenuRangeItem(
              label: 'memory_selector_query_recent_turns'.tr(),
              description: 'memory_selector_query_recent_turns_help'.tr(),
              value: draft.queryRecentTurns.toDouble(),
              min: 1,
              max: 20,
              divisions: 19,
              decimalPlaces: 0,
              editableValue: true,
              onChanged: (v) {
                draft.queryRecentTurns = v.round();
                onChanged();
              },
            ),
            MenuRangeItem(
              label: 'memory_selector_query_max_chars'.tr(),
              description: 'memory_selector_query_max_chars_help'.tr(),
              value: draft.queryMaxChars.toDouble(),
              min: 500,
              max: 5000,
              divisions: 18,
              decimalPlaces: 0,
              editableValue: true,
              onChanged: (v) {
                draft.queryMaxChars = v.round();
                onChanged();
              },
            ),
          ],
        ),
      ],
    );
  }

  // ── Budget ───────────────────────────────────────────────────────

  static String _budgetLabel(String preset) => switch (preset) {
    'small' => 'memory_size_small'.tr(),
    'medium' => 'memory_size_medium'.tr(),
    'large' => 'memory_size_large'.tr(),
    'custom' => 'memory_size_custom'.tr(),
    _ => 'memory_size_auto'.tr(),
  };

  void _pickBudget(BuildContext context) {
    showGlazePickerSheet(
      context,
      title: 'memory_budget'.tr(),
      items: [
        for (final preset in const ['auto', 'small', 'medium', 'large', 'custom'])
          GlazePickerItem(
            label: _budgetLabel(preset),
            isActive: draft.memoryBudgetPreset == preset,
            value: preset,
          ),
      ],
      onSelect: (value) {
        draft.setBudgetPreset(value as String);
        onChanged();
      },
    );
  }

  /// What the two halves of the budget resolve to at a reference context size.
  ///
  /// Was an English sentence built inline in the widget — the one string in
  /// this form that no locale could reach.
  String _effectiveBudgetHint() {
    final breakdown = MemoryInjectionBudget.describeBudget(
      contextBudgetTokens: _referenceContextTokens,
      percent: budgetPercent,
      absoluteCap: draft.maxInjectedTokens,
    );
    final absolute = breakdown.absoluteTokens;
    if (absolute == null) {
      return 'memory_budget_hint_percent'.tr(
        namedArgs: {'percent': _formatTokens(breakdown.percentTokens)},
      );
    }
    return 'memory_budget_hint_min'.tr(
      namedArgs: {
        'percent': _formatTokens(breakdown.percentTokens),
        'absolute': _formatTokens(absolute),
        'effective': _formatTokens(breakdown.effectiveTokens),
        'entries': '${draft.maxInjected}',
      },
    );
  }

  /// The context size the hint is quoted against — a fixed reference, not the
  /// active connection's, so the number does not move while tuning.
  static const int _referenceContextTokens = 32000;

  static String _formatTokens(int? tokens) {
    if (tokens == null) return 'memory_unlimited'.tr();
    return 'memory_tokens_n'.plural(tokens);
  }

  // ── Packing ──────────────────────────────────────────────────────

  static String _packingLabel(String mode) => switch (mode) {
    'full' => 'memory_packing_full'.tr(),
    'chunk_first' => 'memory_packing_chunk_first'.tr(),
    _ => 'memory_packing_hybrid'.tr(),
  };

  static String _packingDescription(String mode) => switch (mode) {
    'full' => 'memory_packing_full_desc'.tr(),
    'chunk_first' => 'memory_packing_chunk_first_desc'.tr(),
    _ => 'memory_packing_hybrid_desc'.tr(),
  };

  void _pickPacking(BuildContext context) {
    showGlazePickerSheet(
      context,
      title: 'memory_packing_mode'.tr(),
      items: [
        for (final mode in const ['full', 'hybrid', 'chunk_first'])
          GlazePickerItem(
            label: _packingLabel(mode),
            hint: _packingDescription(mode),
            isActive: draft.memoryPackingMode == mode,
            value: mode,
          ),
      ],
      onSelect: (value) {
        draft.memoryPackingMode = value as String;
        onChanged();
      },
    );
  }
}
