import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../state/memory_activity_provider.dart';
import '../memory_activity_section.dart';
import 'inspector_surface.dart';

/// The memory half of a coverage view — the same section the card under the
/// chat header shows, so "which memories are in the prompt" is answered by one
/// widget wherever it is asked.
///
/// [caption] says which run the numbers belong to: the stored diagnostics of a
/// past turn, or the last run when the view is about the next request (memory
/// selection only happens during generation, so there is nothing newer to show).
class CoverageMemoryBlock extends StatefulWidget {
  const CoverageMemoryBlock({
    super.key,
    required this.activity,
    required this.caption,
    this.sessionId,
  });

  final MemoryActivityState? activity;
  final String caption;
  final String? sessionId;

  @override
  State<CoverageMemoryBlock> createState() => _CoverageMemoryBlockState();
}

class _CoverageMemoryBlockState extends State<CoverageMemoryBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final activity = widget.activity;
    final summary = activity == null
        ? null
        : MemoryActivitySummary.of(activity);

    return InspectorPlaque(
      radius: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: summary == null
                ? null
                : () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                Icon(
                  Icons.psychology_alt_outlined,
                  size: 16,
                  color: context.cs.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        summary == null
                            ? 'coverage_memory_none'.tr()
                            : 'coverage_memory_summary'.tr(
                                args: [
                                  '${summary.selectedCount}',
                                  '${summary.totalCandidates}',
                                  '${summary.selectedTokens}',
                                ],
                              ),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: context.cs.onSurface,
                        ),
                      ),
                      Text(
                        widget.caption,
                        style: TextStyle(
                          fontSize: 10,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (summary != null)
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: context.cs.onSurfaceVariant,
                  ),
              ],
            ),
          ),
          if (_expanded && activity != null) ...[
            const SizedBox(height: 10),
            MemoryActivitySection(
              activity: activity,
              sessionId: widget.sessionId,
            ),
          ],
        ],
      ),
    );
  }
}
