import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../../shared/widgets/swipe_tab_switcher.dart';
import '../../card_rewrite/card_rewriter_studio_sheet.dart';
import '../chat_provider.dart';
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

  /// Opens the dialog as an overlay. When [characterId] is available, the
  /// dialog follows that chat's active session instead of retaining a stale
  /// session captured when the sheet was opened.
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
    final characterId = widget.characterId;
    final liveSessionId = characterId == null || characterId.isEmpty
        ? null
        : ref.watch(chatProvider(characterId)).value?.session?.id;
    final sessionId = characterId == null || characterId.isEmpty
        ? widget.sessionId
        : liveSessionId;
    final children = sessionId == null || sessionId.isEmpty
        ? <Widget>[Center(child: Text('agent_ops_open_from_chat'.tr()))]
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
                      ? Center(
                          child: Text(
                            'agent_ops_card_rewriter_chat_only'.tr(),
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
            child: KeyedSubtree(
              key: ValueKey(sessionId),
              child: AgenticSessionScope(
                sessionId: sessionId,
                child: IndexedStack(index: _activeIndex, children: children),
              ),
            ),
          );
    return SheetView(
      title: 'agent_ops_title'.tr(),
      showBack: true,
      startExpanded: true,
      onBack: () => Navigator.of(context).maybePop(),
      headerBottom: sessionId == null || sessionId.isEmpty
          ? null
          : GlazeTabBar(
              tabs: [
                GlazeTabItem(
                  label: 'agent_ops_tab_reconciler'.tr(),
                  icon: Icons.rule_folder_outlined,
                ),
                GlazeTabItem(
                  label: 'agent_ops_tab_collector'.tr(),
                  icon: Icons.filter_alt_outlined,
                ),
                GlazeTabItem(
                  label: 'agent_ops_tab_card_rewriter'.tr(),
                  icon: Icons.auto_fix_high_outlined,
                ),
                GlazeTabItem(
                  label: 'agent_ops_tab_snapshots'.tr(),
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
