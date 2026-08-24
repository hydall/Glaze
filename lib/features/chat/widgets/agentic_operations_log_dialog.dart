import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../../shared/widgets/swipe_tab_switcher.dart';
import '../../card_rewrite/card_rewriter_studio_sheet.dart';
import 'agentic_collector_tab.dart';
import 'agentic_reconciler_tab.dart';
import 'agentic_snapshots_tab.dart';

class AgenticOperationsLogDialog extends ConsumerStatefulWidget {
  final String? sessionId;
  final String? characterId;

  const AgenticOperationsLogDialog({
    super.key,
    this.sessionId,
    this.characterId,
  });

  /// Opens the dialog as an overlay. Caller passes the current [sessionId]
  /// so the dialog can scope the list, or null to show operations across all
  /// sessions.
  static Future<String?> show(
    BuildContext context, {
    String? sessionId,
    String? characterId,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AgenticOperationsLogDialog(
        sessionId: sessionId,
        characterId: characterId,
      ),
    );
  }

  @override
  ConsumerState<AgenticOperationsLogDialog> createState() =>
      _AgenticOperationsLogDialogState();
}

class _AgenticOperationsLogDialogState
    extends ConsumerState<AgenticOperationsLogDialog> {
  int _activeIndex = 0;
  final Set<int> _visited = {0};

  void _selectTab(int index) => setState(() {
    _activeIndex = index;
    _visited.add(index);
  });

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    final children = sessionId == null || sessionId.isEmpty
        ? const <Widget>[
            Center(child: Text('Open Agent Ops from a chat session.')),
          ]
        : <Widget>[
            _visited.contains(0)
                ? AgenticReconcilerTab(
                    sessionId: sessionId,
                    characterId: widget.characterId,
                  )
                : const SizedBox.shrink(),
            _visited.contains(1)
                ? AgenticCollectorTab(sessionId: sessionId)
                : const SizedBox.shrink(),
            _visited.contains(2)
                ? widget.characterId == null || widget.characterId!.isEmpty
                      ? const Center(
                          child: Text(
                            'Card Rewriter is available when Agent Ops is opened from the chat drawer.',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : CardRewriterStudioSheet(
                          charId: widget.characterId!,
                          sessionId: sessionId,
                        )
                : const SizedBox.shrink(),
            _visited.contains(3)
                ? const AgenticSnapshotsTab()
                : const SizedBox.shrink(),
          ];

    final body = sessionId == null || sessionId.isEmpty
        ? children.single
        : SwipeTabSwitcher(
            index: _activeIndex,
            length: 4,
            onChanged: _selectTab,
            child: AgenticSessionScope(
              sessionId: sessionId,
              child: IndexedStack(index: _activeIndex, children: children),
            ),
          );
    return SheetView(
      title: 'Agent Ops',
      showBack: true,
      startExpanded: true,
      onBack: () => Navigator.of(context).maybePop(),
      headerBottom: sessionId == null || sessionId.isEmpty
          ? null
          : GlazeTabBar(
              tabs: const [
                GlazeTabItem(
                  label: 'Reconciler',
                  icon: Icons.rule_folder_outlined,
                ),
                GlazeTabItem(
                  label: 'Collector',
                  icon: Icons.filter_alt_outlined,
                ),
                GlazeTabItem(
                  label: 'Card Rewriter',
                  icon: Icons.auto_fix_high_outlined,
                ),
                GlazeTabItem(
                  label: 'Snapshots',
                  icon: Icons.history_edu_outlined,
                ),
              ],
              activeIndex: _activeIndex,
              onChanged: _selectTab,
            ),
      body: Builder(
        builder: (context) => Padding(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
          child: body,
        ),
      ),
    );
  }
}

/// Small inherited widget that exposes the dialog's `sessionId` to the
/// tabs without having to plumb it through constructors (the tabs are
/// built inside a `TabBarView` whose `DefaultTabController` is stateless).
class AgenticSessionScope extends InheritedWidget {
  final String? sessionId;
  const AgenticSessionScope({super.key, this.sessionId, required super.child});

  @override
  bool updateShouldNotify(AgenticSessionScope oldWidget) =>
      oldWidget.sessionId != sessionId;
}
