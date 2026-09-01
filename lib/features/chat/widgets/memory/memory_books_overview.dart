import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glass_surface.dart';
import '../../../../shared/widgets/menu_group.dart';
import 'memory_books_controls.dart';

/// Hero card + retrieval settings + counters shown above the tabs of the
/// memory-books sheet.
///
/// Presentation only — every value is passed in already resolved by
/// [MemoryBookController], so this widget never touches providers.
class MemoryBooksOverview extends StatelessWidget {
  final String sessionId;
  final String modelLabel;
  final String settingsSummary;
  final String searchTypeLabel;
  final VoidCallback onCycleSearchType;

  /// False when the active API preset has vector search switched off — the
  /// retrieval-mode row only cycles between vector modes, so it is dropped
  /// rather than offering a switch that cannot take effect.
  final bool showSearchType;
  final int activeCount;
  final int needsRebuildCount;
  final int draftCount;

  const MemoryBooksOverview({
    super.key,
    required this.sessionId,
    required this.modelLabel,
    required this.settingsSummary,
    required this.searchTypeLabel,
    required this.onCycleSearchType,
    required this.showSearchType,
    required this.activeCount,
    required this.needsRebuildCount,
    required this.draftCount,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: _buildHero(context),
        ),
        if (showSearchType)
          MenuGroup(
            items: [
              MenuSelectorItem(
                label: 'label_search_type'.tr(),
                currentValue: searchTypeLabel,
                onTap: onCycleSearchType,
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: _buildCounters(context),
        ),
      ],
    );
  }

  Widget _buildHero(BuildContext context) {
    // The session id is a uuid; show only the leading block so the subtitle
    // stays a glanceable identifier instead of wrapping onto two lines.
    final shortId = sessionId.length > 8
        ? sessionId.substring(0, 8)
        : sessionId;
    return GlassSurface(
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: context.cs.outlineVariant),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'magic_memory_books'.tr(),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: context.cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${'memory_books_session'.tr()} $shortId…',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: MemoryPill(
                    label: modelLabel,
                    color: context.cs.primary,
                    fontSize: 12,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              settingsSummary,
              style: TextStyle(
                fontSize: 12,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCounters(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: MemoryStatTile(
            value: '$activeCount',
            label: 'memory_books_status_active'.tr(),
            color: const Color(0xFF4CAF50),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: MemoryStatTile(
            value: '$needsRebuildCount',
            label: 'memory_books_entry_needs_rebuild'.tr(),
            color: const Color(0xFFFF9800),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: MemoryStatTile(
            value: '$draftCount',
            label: 'memory_books_status_drafts'.tr(),
            color: const Color(0xFFFFC107),
          ),
        ),
      ],
    );
  }
}
