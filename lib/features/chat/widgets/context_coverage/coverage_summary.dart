import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../core/llm/lorebook_coverage.dart';
import '../../../../shared/theme/app_colors.dart';
import 'coverage_entry_tile.dart';
import 'coverage_tone.dart';

/// Which slice of the coverage the list is showing.
enum CoverageFilter { injected, cutOff, notTriggered, all }

String coverageFilterLabel(CoverageFilter filter) => switch (filter) {
  CoverageFilter.injected => 'filter_activated'.tr(),
  CoverageFilter.cutOff => 'filter_cut_off'.tr(),
  CoverageFilter.notTriggered => 'filter_not_triggered'.tr(),
  CoverageFilter.all => 'filter_all'.tr(),
};

List<CoverageEntry> filterCoverageEntries(
  List<CoverageEntry> entries,
  CoverageFilter filter,
) => switch (filter) {
  CoverageFilter.injected =>
    entries.where((e) => e.activated && e.cutOff == null).toList(),
  CoverageFilter.cutOff => entries.where((e) => e.cutOff != null).toList(),
  CoverageFilter.notTriggered => entries.where((e) => !e.activated).toList(),
  CoverageFilter.all => entries,
};

/// The four numbers that answer "what is in the prompt right now?".
///
/// Rendered as one connected strip rather than four free-floating chips: the
/// counts belong to a single sentence — injected, cut off, inactive, out of
/// total — and reading them as one row is the whole point of the bar.
class CoverageStatBar extends StatelessWidget {
  const CoverageStatBar({super.key, required this.result, this.dense = false});

  final CoverageResult result;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final tone = CoverageTone.of(context);
    return Row(
      children: [
        _Stat(
          value: result.injectedCount,
          label: 'label_active'.tr(),
          color: tone.injected,
          dense: dense,
        ),
        if (result.cutOffCount > 0)
          _Stat(
            value: result.cutOffCount,
            label: 'label_cut_off'.tr(),
            color: tone.cutOff,
            dense: dense,
          ),
        _Stat(
          value: result.inactiveCount,
          label: 'label_inactive'.tr(),
          color: tone.idle,
          dense: dense,
        ),
        _Stat(
          value: result.totalCandidates,
          label: 'label_total'.tr(),
          color: context.cs.onSurface.withValues(alpha: 0.7),
          dense: dense,
          last: true,
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.value,
    required this.label,
    required this.color,
    required this.dense,
    this.last = false,
  });

  final int value;
  final String label;
  final Color color;
  final bool dense;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(right: last ? 0 : (dense ? 10 : 14)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(right: 5),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          Text(
            '$value',
            style: TextStyle(
              fontSize: dense ? 12 : 13,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurface,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: dense ? 10 : 11,
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The scrolling list of entries, with the shared empty state.
class CoverageEntryList extends StatelessWidget {
  const CoverageEntryList({
    super.key,
    required this.entries,
    this.dense = false,
    this.padding = const EdgeInsets.fromLTRB(12, 4, 12, 24),
    this.shrinkWrap = false,
  });

  final List<CoverageEntry> entries;
  final bool dense;
  final EdgeInsets padding;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
        child: Text(
          'lorebook_no_entries_category'.tr(),
          style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 12),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap
          ? const ClampingScrollPhysics()
          : const AlwaysScrollableScrollPhysics(),
      padding: padding,
      itemCount: entries.length,
      itemBuilder: (_, i) => CoverageEntryTile(entry: entries[i], dense: dense),
    );
  }
}
