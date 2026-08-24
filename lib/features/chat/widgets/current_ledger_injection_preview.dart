import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/ledger_prompt_injection_mode.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_filter_chip_bar.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../services/current_ledger_injection_preview_service.dart';

class CurrentLedgerInjectionPreviewCard extends ConsumerStatefulWidget {
  const CurrentLedgerInjectionPreviewCard({
    super.key,
    required this.sessionId,
    this.characterId,
  });

  final String sessionId;
  final String? characterId;

  @override
  ConsumerState<CurrentLedgerInjectionPreviewCard> createState() =>
      _CurrentLedgerInjectionPreviewCardState();
}

class _CurrentLedgerInjectionPreviewCardState
    extends ConsumerState<CurrentLedgerInjectionPreviewCard> {
  LedgerPromptInjectionMode _mode = LedgerPromptInjectionMode.legacy;

  CurrentLedgerInjectionPreviewKey get _key =>
      (sessionId: widget.sessionId, characterId: widget.characterId);

  @override
  Widget build(BuildContext context) {
    final preview = ref.watch(currentLedgerInjectionPreviewProvider(_key));
    return GlassSurface(
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'agent_ops_current_ledger_injection'.tr(),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'action_refresh'.tr(),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => ref.invalidate(
                    currentLedgerInjectionPreviewProvider(_key),
                  ),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            Text(
              'agent_ops_ledger_injection_description'.tr(),
              style: TextStyle(
                color: context.cs.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            preview.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: GlazeSpinner()),
              ),
              error: (error, _) => Text(
                'agent_ops_preview_unavailable'.tr(
                  namedArgs: {'error': '$error'},
                ),
                style: TextStyle(color: context.cs.error, fontSize: 12),
              ),
              data: _buildPreview,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(CurrentLedgerInjectionPreview preview) {
    final selected = _mode == LedgerPromptInjectionMode.legacy
        ? preview.legacy.value
        : preview.gapFiller.value;
    final selectedCount = selected.diagnostics
        .where((item) => item.selected)
        .length;
    final suppressedCount = selected.diagnostics.length - selectedCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlazeFilterChipBar<LedgerPromptInjectionMode>(
          current: _mode,
          options: const [
            LedgerPromptInjectionMode.legacy,
            LedgerPromptInjectionMode.gapFiller,
          ],
          labelBuilder: (mode) => switch (mode) {
            LedgerPromptInjectionMode.legacy =>
              'studio_ledger_prompt_injection_legacy'.tr(),
            LedgerPromptInjectionMode.gapFiller =>
              'studio_ledger_prompt_injection_gap_filler'.tr(),
            _ => mode.name,
          },
          onSelected: (mode) => setState(() => _mode = mode),
        ),
        Text(
          'agent_ops_injection_summary'.tr(
            namedArgs: {
              'mode': _injectionModeLabel(preview.configuredMode),
              'visible': '${preview.visibleMessageIds.length}',
              'selected': '$selectedCount',
              'suppressed': '$suppressedCount',
            },
          ),
          style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 11),
        ),
        const SizedBox(height: 8),
        _InjectionSection(
          title: 'agent_ops_character_knowledge'.tr(),
          content: selected.characterKnowledgeContent,
        ),
        _InjectionSection(
          title: 'agent_ops_studio_session_state'.tr(),
          content: selected.studioSessionStateContent,
        ),
        _InjectionSection(
          title: 'agent_ops_arc'.tr(),
          content: selected.arcContent,
        ),
        ExpansionTile(
          dense: true,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 4),
          title: Text('agent_ops_selection_diagnostics'.tr()),
          subtitle: Text(
            'agent_ops_revision'.tr(
              namedArgs: {
                'number': '${preview.revisionNumber}',
                'hash': preview.revisionHash,
              },
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
          children: [
            if (selected.diagnostics.isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Text('agent_ops_no_projection_groups'.tr()),
              )
            else
              for (final diagnostic in selected.diagnostics)
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    '${diagnostic.selected ? 'agent_ops_diagnostic_in'.tr() : 'agent_ops_diagnostic_out'.tr()} · '
                    '${diagnostic.groupId} · ${_tierLabel(diagnostic.tier.name)} · '
                    '${_reasonLabel(diagnostic.reason.name)}'
                    '${diagnostic.matchingSourceIds.isEmpty ? '' : ' · ${diagnostic.matchingSourceIds.join(', ')}'}',
                    style: TextStyle(
                      color: context.cs.onSurfaceVariant,
                      fontFamily: 'monospace',
                      fontSize: 10,
                    ),
                  ),
                ),
          ],
        ),
      ],
    );
  }
}

class _InjectionSection extends StatelessWidget {
  const _InjectionSection({required this.title, required this.content});

  final String title;
  final String? content;

  @override
  Widget build(BuildContext context) {
    final text = content?.trim();
    return ExpansionTile(
      dense: true,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Text(title),
      subtitle: Text(
        text == null || text.isEmpty
            ? 'agent_ops_empty'.tr()
            : 'agent_ops_character_count'.tr(
                namedArgs: {'count': '${text.length}'},
              ),
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(
            text == null || text.isEmpty
                ? 'agent_ops_nothing_injected'.tr()
                : text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
      ],
    );
  }
}

String _injectionModeLabel(LedgerPromptInjectionMode mode) => switch (mode) {
  LedgerPromptInjectionMode.legacy =>
    'studio_ledger_prompt_injection_legacy'.tr(),
  LedgerPromptInjectionMode.gapFiller =>
    'studio_ledger_prompt_injection_gap_filler'.tr(),
  _ => mode.name,
};

String _tierLabel(String tier) => switch (tier) {
  'critical' => 'agent_ops_tier_critical'.tr(),
  'gap' => 'agent_ops_tier_gap'.tr(),
  'volatile' => 'agent_ops_tier_volatile'.tr(),
  'excluded' => 'agent_ops_tier_excluded'.tr(),
  _ => tier,
};

String _reasonLabel(String reason) => switch (reason) {
  'selected' => 'agent_ops_reason_selected'.tr(),
  'disabledMode' => 'agent_ops_reason_disabled_mode'.tr(),
  'visibleSourceEvidence' => 'agent_ops_reason_visible_source'.tr(),
  'structuredContinuityCoverage' => 'agent_ops_reason_continuity_coverage'.tr(),
  'visibleEntityCoverage' => 'agent_ops_reason_entity_coverage'.tr(),
  'notRelevantToCausalWindow' => 'agent_ops_reason_not_relevant'.tr(),
  'tentativeOrInferred' => 'agent_ops_reason_tentative'.tr(),
  'transitionTargetSuppressed' => 'agent_ops_reason_transition_suppressed'.tr(),
  _ => reason,
};
