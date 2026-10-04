import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_filter_chip_bar.dart';
import '../../../../shared/widgets/glaze_spinner.dart';
import '../../state/lorebook_coverage_provider.dart';
import 'coverage_entry_tile.dart';
import 'coverage_summary.dart';

/// The lorebook half of the context card under the chat header.
///
/// Reads the same [lorebookCoverageProvider] the Prompt Inspector's coverage
/// tab reads, so the two can never report different numbers for one turn; the
/// list is capped and scrolls inside the card rather than growing the card into
/// the message list.
class LorebookCoverageSection extends ConsumerStatefulWidget {
  const LorebookCoverageSection({super.key, required this.charId});

  final String charId;

  @override
  ConsumerState<LorebookCoverageSection> createState() =>
      _LorebookCoverageSectionState();
}

class _LorebookCoverageSectionState
    extends ConsumerState<LorebookCoverageSection> {
  CoverageFilter _filter = CoverageFilter.injected;
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coverage = ref.watch(lorebookCoverageProvider(widget.charId));

    return coverage.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(child: GlazeSpinner()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '${'title_error'.tr()}: $e',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: context.cs.error),
        ),
      ),
      data: (result) {
        if (result.totalCandidates == 0) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              'coverage_no_active_books'.tr(),
              style: TextStyle(
                fontSize: 11,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          );
        }
        final entries = filterCoverageEntries(result.entries, _filter);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CoverageStatBar(result: result, dense: true),
            const SizedBox(height: 4),
            GlazeFilterChipBar<CoverageFilter>(
              current: _filter,
              options: CoverageFilter.values.toList(),
              labelBuilder: coverageFilterLabel,
              onSelected: (f) => setState(() => _filter = f),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: Scrollbar(
                controller: _scrollController,
                child: ListView.builder(
                  controller: _scrollController,
                  shrinkWrap: true,
                  physics: const ClampingScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemCount: entries.isEmpty ? 1 : entries.length,
                  itemBuilder: (_, i) => entries.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            'lorebook_no_entries_category'.tr(),
                            style: TextStyle(
                              fontSize: 11,
                              color: context.cs.onSurfaceVariant,
                            ),
                          ),
                        )
                      : CoverageEntryTile(entry: entries[i], dense: true),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
