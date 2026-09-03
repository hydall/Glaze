import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../shared/widgets/glaze_tab_bar.dart';
import 'coverage_sub_tab.dart';
import 'request_timeline_view.dart';

/// The inspector's Requests tab: two views of the same traffic.
///
/// **Timeline** is what was sent — turns with their stages, background jobs in
/// their place in time. **Coverage** is what went *into* those requests — the
/// next one as a live prediction, the past ones from what was recorded when
/// they ran. Coverage used to be a top-level tab, which put a prediction next
/// to a log and let them be mistaken for each other; nested here, the tense of
/// each is obvious.
class RequestsTab extends StatefulWidget {
  const RequestsTab({
    super.key,
    required this.charId,
    required this.onDetailChanged,
    this.initialSubTab = RequestsSubTab.timeline,
  });

  final String charId;

  /// Fires whenever either view enters or leaves a drill-down, so the inspector
  /// can hide its own tab strip for it.
  final ValueChanged<bool> onDetailChanged;

  final RequestsSubTab initialSubTab;

  @override
  State<RequestsTab> createState() => _RequestsTabState();
}

enum RequestsSubTab { timeline, coverage }

class _RequestsTabState extends State<RequestsTab> {
  late RequestsSubTab _sub = widget.initialSubTab;
  late final Set<RequestsSubTab> _visited = {_sub};

  /// Which view owns the open drill-down, so switching sub-tabs restores the
  /// strip instead of leaving it hidden.
  RequestsSubTab? _detailOwner;

  void _reportDetail(RequestsSubTab owner, bool open) {
    final next = open ? owner : (_detailOwner == owner ? null : _detailOwner);
    if (next == _detailOwner) return;
    setState(() => _detailOwner = next);
    widget.onDetailChanged(next != null);
  }

  @override
  Widget build(BuildContext context) {
    final inDetail = _detailOwner != null;
    final order = RequestsSubTab.values;

    // The inspector hands its floating-header height down as the body's top
    // inset; consume it once here so nothing below adds the gap again.
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: Column(
          children: [
            // Underline, not pills: this strip heads a surface the sheet's own
            // pill strip already owns (see docs/UI_KIT.md). It steps aside
            // entirely while a drill-down is open.
            if (!inDetail)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: GlazeTabBar(
                  style: GlazeTabBarStyle.underline,
                  tabs: [
                    GlazeTabItem(
                      label: 'requests_sub_timeline'.tr(),
                      icon: Icons.swap_vert_rounded,
                    ),
                    GlazeTabItem(
                      label: 'requests_sub_coverage'.tr(),
                      icon: Icons.search,
                    ),
                  ],
                  activeIndex: order.indexOf(_sub),
                  onChanged: (i) => setState(() {
                    _sub = order[i];
                    _visited.add(_sub);
                  }),
                ),
              ),
            Expanded(
              child: IndexedStack(
                index: order.indexOf(_sub),
                children: [
                  _visited.contains(RequestsSubTab.timeline)
                      ? RequestTimelineView(
                          charId: widget.charId,
                          onDetailChanged: (open) =>
                              _reportDetail(RequestsSubTab.timeline, open),
                        )
                      : const SizedBox.shrink(),
                  _visited.contains(RequestsSubTab.coverage)
                      ? CoverageSubTab(
                          charId: widget.charId,
                          onDetailChanged: (open) =>
                              _reportDetail(RequestsSubTab.coverage, open),
                        )
                      : const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
