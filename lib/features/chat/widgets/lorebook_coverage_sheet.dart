import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/lorebook_coverage.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_filter_chip_bar.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../state/lorebook_coverage_provider.dart';
import 'context_coverage/coverage_summary.dart';

/// The Prompt Inspector's coverage tab: the full-height read of which lorebook
/// entries the next prompt will carry.
///
/// The scan itself lives in [lorebookCoverageProvider] — the card under the
/// chat header shows the same result, and running it twice per turn would cost
/// a second vector query for an answer that must not differ.
class CoveragePanel extends ConsumerStatefulWidget {
  final String charId;

  /// When true, render only the body (no SheetView chrome) for embedding
  /// inside the Prompt Inspector's tabbed shell.
  final bool embedded;

  const CoveragePanel({super.key, required this.charId, this.embedded = false});

  @override
  ConsumerState<CoveragePanel> createState() => _CoveragePanelState();
}

class _CoveragePanelState extends ConsumerState<CoveragePanel> {
  CoverageFilter _filter = CoverageFilter.injected;

  void _refresh() => ref.invalidate(lorebookCoverageProvider(widget.charId));

  @override
  Widget build(BuildContext context) {
    final coverage = ref.watch(lorebookCoverageProvider(widget.charId));
    final body = coverage.when(
      loading: () => const Center(child: GlazeSpinner()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '${'title_error'.tr()}: $e',
            style: TextStyle(color: context.cs.onSurfaceVariant),
          ),
        ),
      ),
      data: _buildResult,
    );

    if (widget.embedded) {
      // The Prompt Inspector injects the floating-header height as the body's
      // top inset. Offset the whole embedded column (toolbar included) by it,
      // then strip the inset from descendants so [body] — which also reads
      // padding.top for its leading spacer — doesn't add the gap a second time.
      return Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Text(
                      'lorebook_coverage_title'.tr(),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.refresh, size: 20),
                      tooltip: 'action_refresh'.tr(),
                      onPressed: coverage.isLoading ? null : _refresh,
                    ),
                  ],
                ),
              ),
              Expanded(child: body),
            ],
          ),
        ),
      );
    }

    return SheetView(
      title: 'lorebook_coverage_title'.tr(),
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.refresh, size: 20),
          onPressed: _refresh,
          tooltip: 'action_refresh'.tr(),
        ),
      ],
      body: body,
    );
  }

  Widget _buildResult(CoverageResult result) {
    return Column(
      children: [
        Builder(
          builder: (context) =>
              SizedBox(height: MediaQuery.paddingOf(context).top),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: CoverageStatBar(result: result),
        ),
        GlazeFilterChipBar<CoverageFilter>(
          current: _filter,
          options: CoverageFilter.values.toList(),
          labelBuilder: coverageFilterLabel,
          onSelected: (f) => setState(() => _filter = f),
        ),
        Expanded(
          child: CoverageEntryList(
            entries: filterCoverageEntries(result.entries, _filter),
          ),
        ),
      ],
    );
  }
}
