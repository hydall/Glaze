import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/sheet_view.dart';
import 'tokenizer_sheet.dart';
import 'requests/requests_tab.dart';
import 'lorebook_coverage_sheet.dart';

/// Unified diagnostics surface: Context (tokenizer), Requests and Lorebook
/// Coverage in one sheet. All answer the same question — "what actually goes
/// into the prompt?" — so they live behind a single Magic Drawer entry instead
/// of several separate cards.
///
/// There is no Agents tab. Agent runs are requests like any other and appear in
/// the Requests timeline as the steps of the turn they belong to; the catalog
/// of what the agents *would* send next is the "next turn" row at the top of
/// that same list.
class PromptInspectorSheet extends ConsumerStatefulWidget {
  final String charId;
  final String initialTabId;

  const PromptInspectorSheet({
    super.key,
    required this.charId,
    this.initialTabId = _tabContext,
  });

  static const _tabContext = 'context';
  static const _tabRequests = 'requests';
  static const _tabCoverage = 'coverage';

  /// Tab ids other surfaces deep-link to (the context card under the chat
  /// header opens the inspector on the layer it is showing).
  static const contextTabId = _tabContext;
  static const requestsTabId = _tabRequests;
  static const coverageTabId = _tabCoverage;

  @override
  ConsumerState<PromptInspectorSheet> createState() =>
      _PromptInspectorSheetState();
}

class _PromptInspectorSheetState extends ConsumerState<PromptInspectorSheet> {
  late String _activeTabId = widget.initialTabId;
  late final Set<String> _visitedTabs = {_activeTabId};

  /// True while a tab is showing a drill-down of its own (a single request).
  /// The tab strip steps aside for it — two levels of navigation stacked on one
  /// sheet read as one broken level.
  bool _detailOpen = false;

  static const _order = [
    PromptInspectorSheet._tabContext,
    PromptInspectorSheet._tabRequests,
    PromptInspectorSheet._tabCoverage,
  ];

  @override
  Widget build(BuildContext context) {
    final activeId = _order.contains(_activeTabId) ? _activeTabId : _order.first;
    final activeIndex = _order.indexOf(activeId);

    // Preserve visited tabs without eagerly starting every expensive prompt
    // diagnostic when the inspector opens.
    final body = IndexedStack(
      index: activeIndex,
      children: [for (final id in _order) _tabBody(id)],
    );

    return SheetView(
      title: 'prompt_inspector_title'.tr(),
      showBack: true,
      startExpanded: true,
      onBack: () => Navigator.of(context).maybePop(),
      // Glaze's segmented control instead of SheetView's plain tab pills, so
      // the inspector matches the tab strip used by the rest of the app.
      headerBottom: _detailOpen
          ? null
          : GlazeTabBar(
              tabs: [for (final id in _order) _tabItem(id)],
              activeIndex: activeIndex,
              onChanged: (i) => setState(() {
                _activeTabId = _order[i];
                _visitedTabs.add(_activeTabId);
              }),
            ),
      body: body,
    );
  }

  Widget _tabBody(String id) {
    if (!_visitedTabs.contains(id)) return const SizedBox.shrink();
    return switch (id) {
      PromptInspectorSheet._tabContext => TokenizerSheet(
        charId: widget.charId,
        embedded: true,
      ),
      PromptInspectorSheet._tabRequests => RequestsTab(
        charId: widget.charId,
        onDetailChanged: (open) {
          if (_detailOpen == open) return;
          setState(() => _detailOpen = open);
        },
      ),
      _ => CoveragePanel(charId: widget.charId, embedded: true),
    };
  }

  GlazeTabItem _tabItem(String id) => switch (id) {
    PromptInspectorSheet._tabContext => GlazeTabItem(
      label: 'tab_context'.tr(),
      icon: Icons.segment,
    ),
    PromptInspectorSheet._tabRequests => GlazeTabItem(
      label: 'tab_requests'.tr(),
      icon: Icons.swap_vert_rounded,
    ),
    _ => GlazeTabItem(label: 'tab_coverage'.tr(), icon: Icons.search),
  };
}

Future<void> showPromptInspectorSheet(
  BuildContext context,
  String charId, {
  String initialTabId = PromptInspectorSheet._tabContext,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) =>
        PromptInspectorSheet(charId: charId, initialTabId: initialTabId),
  );
}
