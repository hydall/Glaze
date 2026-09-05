import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/sheet_view.dart';
import 'tokenizer_sheet.dart';
import 'requests/request_timeline_view.dart';

/// Unified diagnostics surface: Context (the token budget) and Requests (what
/// the chat sent, and what went into it). Both answer the same question — "what
/// actually goes into the prompt?" — so they live behind a single Magic Drawer
/// entry instead of several separate cards.
///
/// Two things used to be top-level tabs and are not any more. Agent runs are
/// requests like any other, so they are steps of the turn they belong to in the
/// Requests timeline. Coverage is a property *of* a request, so it is a block
/// inside the opened request — including the next one, whose coverage lives in
/// its preview rather than in a row beside it.
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

  /// Ids other surfaces deep-link to (the context card under the chat header
  /// opens the inspector on the layer it is showing). [coverageTabId] is not a
  /// tab any more — it lands on Requests, opened on the next request with its
  /// coverage block unfolded.
  static const contextTabId = _tabContext;
  static const requestsTabId = _tabRequests;
  static const coverageTabId = 'coverage';

  @override
  ConsumerState<PromptInspectorSheet> createState() =>
      _PromptInspectorSheetState();
}

class _PromptInspectorSheetState extends ConsumerState<PromptInspectorSheet> {
  late String _activeTabId =
      widget.initialTabId == PromptInspectorSheet.coverageTabId
      ? PromptInspectorSheet._tabRequests
      : widget.initialTabId;
  late final Set<String> _visitedTabs = {_activeTabId};

  /// True while a tab is showing a drill-down of its own (a single request).
  /// The tab strip steps aside for it — two levels of navigation stacked on one
  /// sheet read as one broken level.
  bool _detailOpen = false;

  static const _order = [
    PromptInspectorSheet._tabContext,
    PromptInspectorSheet._tabRequests,
  ];

  /// A `coverage` deep link is the Requests tab opened on the next request's
  /// coverage.
  bool get _initialCoverage =>
      widget.initialTabId == PromptInspectorSheet.coverageTabId;

  @override
  Widget build(BuildContext context) {
    final activeId = _order.contains(_activeTabId)
        ? _activeTabId
        : _order.first;
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
      _ => RequestTimelineView(
        charId: widget.charId,
        initialCoverage: _initialCoverage,
        onDetailChanged: (open) {
          if (_detailOpen == open) return;
          setState(() => _detailOpen = open);
        },
      ),
    };
  }

  GlazeTabItem _tabItem(String id) => switch (id) {
    PromptInspectorSheet._tabContext => GlazeTabItem(
      label: 'tab_context'.tr(),
      icon: Icons.segment,
    ),
    _ => GlazeTabItem(
      label: 'tab_requests'.tr(),
      icon: Icons.swap_vert_rounded,
    ),
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
