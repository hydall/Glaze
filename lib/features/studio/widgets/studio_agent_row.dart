import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/studio_controller_ontology.dart';
import '../../../core/state/pipeline_settings_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_filter_chip_bar.dart';
import '../../../shared/widgets/glaze_switch.dart';

/// One agent inside the block list, rendered under the header of the stage it
/// runs in and above the blocks addressed to that stage. Same row geometry as
/// `StudioBlockRow` so a section reads as one list: leading gutter, glyph,
/// name + purpose, switch. Tapping opens the agent's (read-only) spec card.
class StudioAgentRow extends StatelessWidget {
  final StudioControllerSpec spec;

  /// Whether the agent runs for the preset being edited.
  final bool enabled;
  final ValueChanged<bool> onToggle;

  /// Last row of its section — drops the bottom rule.
  final bool isLast;

  const StudioAgentRow({
    super.key,
    required this.spec,
    required this.enabled,
    required this.onToggle,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: const Color(0x33808080),
            width: isLast ? 0 : 1,
          ),
        ),
      ),
      child: Opacity(
        opacity: enabled ? 1.0 : 0.5,
        child: InkWell(
          onTap: () => showStudioAgentCard(context, spec),
          child: Row(
            children: [
              const SizedBox(width: 30, height: 44),
              Icon(
                spec.isFinal ? Icons.star_outline : Icons.smart_toy_outlined,
                size: 16,
                color: spec.isFinal
                    ? context.cs.primary
                    : context.cs.onSurface.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        spec.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: context.cs.onSurface,
                        ),
                      ),
                      Text(
                        spec.purpose,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                // An always-on agent gets a padlock, not a dead switch: a
                // greyed-out toggle reads as "you turned this off".
                child: spec.lockedOn
                    ? Tooltip(
                        message: 'studio_agent_always_on'.tr(),
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: Icon(
                            Icons.lock_outline,
                            size: 18,
                            color: context.cs.onSurfaceVariant,
                          ),
                        ),
                      )
                    : Transform.scale(
                        scale: 0.8,
                        alignment: Alignment.centerRight,
                        child: GlazeSwitch(value: enabled, onChanged: onToggle),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── StudioPostContextSetting ─────────────────────────────────────────────────

/// How many trailing chat messages a post-processing agent is handed (the last
/// turn plus the response it has to edit).
///
/// One global setting — `StudioAgentSettings.studioPostControllerContextSize`
/// applies to the Post Clean agent. It is therefore rendered under it. The
/// Ledger does not use this setting; it always pulls its own fixed window of
/// recent history at runtime.
class StudioPostContextSetting extends ConsumerWidget {
  /// Last row of its section — drops the bottom rule.
  final bool isLast;

  const StudioPostContextSetting({super.key, this.isLast = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(
      pipelineSettingsProvider.select(
        (p) => p.studioAgent.studioPostControllerContextSize,
      ),
    );
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: const Color(0x33808080),
            width: isLast ? 0 : 1,
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(54, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'studio_post_context_label'.tr(),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'studio_post_context_desc'.tr(),
            style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          GlazeFilterChipBar<int>(
            current: current,
            options: const [1, 2, 3, 5],
            labelBuilder: (value) => '$value',
            onSelected: (value) => unawaited(_save(ref, value)),
          ),
        ],
      ),
    );
  }

  Future<void> _save(WidgetRef ref, int value) {
    final pipeline = ref.read(pipelineSettingsProvider);
    return ref
        .read(pipelineSettingsProvider.notifier)
        .save(
          pipeline.copyWith(
            studioAgent: pipeline.studioAgent.copyWith(
              studioPostControllerContextSize: value,
            ),
          ),
        );
  }
}

// ─── agent spec card ──────────────────────────────────────────────────────────

/// Read-only card describing a controller slot. The instructions are fixed by
/// [StudioControllerOntology] (§4 — agent identity is pinned to its spec), so
/// this sheet only explains what the agent does.
void showStudioAgentCard(BuildContext context, StudioControllerSpec spec) {
  GlazeBottomSheet.show<void>(
    context,
    title: spec.name,
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.55,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cardRow(
              context,
              Icons.badge_outlined,
              'studio_agent_purpose'.tr(),
              spec.purpose,
            ),
            const SizedBox(height: 16),
            _cardRow(
              context,
              Icons.arrow_forward_rounded,
              'studio_agent_lane_owns'.tr(),
              spec.laneOwns,
            ),
            const SizedBox(height: 16),
            _cardRow(
              context,
              Icons.block_rounded,
              'studio_agent_lane_skip'.tr(),
              spec.laneSkip,
            ),
            const SizedBox(height: 16),
            _cardRow(
              context,
              Icons.terminal_rounded,
              'studio_agent_output_contract'.tr(),
              spec.outputContract,
            ),
            const SizedBox(height: 20),
            Text(
              'studio_agent_fixed_hint'.tr(),
              style: TextStyle(
                fontSize: 12,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _cardRow(
  BuildContext context,
  IconData icon,
  String label,
  String body,
) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, size: 16, color: context.cs.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: context.cs.primary,
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Text(body, style: const TextStyle(fontSize: 13, height: 1.4)),
    ],
  );
}
