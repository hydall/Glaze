import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/agent_operation_record.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../../shared/widgets/swipe_tab_switcher.dart';
import '../../card_rewrite/card_rewriter_studio_sheet.dart';
import 'agentic_collector_tab.dart';
import 'agentic_reconciler_tab.dart';
import 'agentic_snapshots_tab.dart';
import 'post_cleaner_diff_dialog.dart';

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
      body: body,
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

/// Shared operation tile used by [AgenticOperationsTab] and
/// [AgenticLastTurnTab].
class OperationTile extends StatelessWidget {
  final AgentOperationRecord record;

  const OperationTile({super.key, required this.record});

  bool get _canShowDiff =>
      record.kind == AgentOperationKind.postCleaner &&
      record.status.isOk &&
      record.sessionId != null &&
      record.messageId != null;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context, record.status);
    return ExpansionTile(
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(_kindIcon(record.kind), color: color, size: 20),
      title: Text(
        record.tileLabel,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.cs.onSurface,
        ),
      ),
      subtitle: record.summary == null
          ? null
          : Text(
              record.summary!,
              style: TextStyle(
                fontSize: 11,
                color: context.cs.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_canShowDiff)
            IconButton(
              onPressed: () => PostCleanerDiffDialog.show(
                context,
                sessionId: record.sessionId!,
                messageId: record.messageId!,
              ),
              icon: const Icon(Icons.compare_arrows, size: 18),
              tooltip: 'View diff',
              visualDensity: VisualDensity.compact,
            ),
          if (record.canRegenerate)
            IconButton(
              onPressed: () => _showRegenHint(context),
              icon: const Icon(Icons.refresh, size: 18),
              tooltip: 'Regenerate (next turn)',
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detailRow(context, 'Kind', record.kind.label),
              _detailRow(context, 'Status', record.status.label),
              _detailRow(
                context,
                'Attempts',
                '${record.attemptCount}${record.wasRetried ? " (retried)" : ""}',
              ),
              _detailRow(context, 'Total time', '${record.totalElapsedMs}ms'),
              if (record.model != null)
                _detailRow(context, 'Model', record.model!),
              if (record.messageId != null)
                _detailRow(context, 'Message', record.messageId!),
              if (record.attempts.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Attempts:',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                ...record.attempts.map(
                  (a) => Padding(
                    padding: const EdgeInsets.only(left: 8, bottom: 2),
                    child: Row(
                      children: [
                        Icon(
                          a.isSuccess ? Icons.check : Icons.error_outline,
                          size: 14,
                          color: a.isSuccess
                              ? context.cs.primary
                              : _attemptColor(context, a.status),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '#${a.attempt} · ${a.status}'
                          '${a.statusCode != 0 ? " · HTTP ${a.statusCode}" : ""}'
                          ' · ${a.elapsedMs}ms',
                          style: TextStyle(
                            fontSize: 11,
                            color: context.cs.onSurface,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _detailRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 11, color: context.cs.onSurface),
            ),
          ),
        ],
      ),
    );
  }

  Color _statusColor(BuildContext context, AgentOperationStatus status) {
    if (status.isOk) return context.cs.primary;
    if (status.isFailure) return context.cs.error;
    return context.cs.onSurfaceVariant;
  }

  Color _attemptColor(BuildContext context, String status) {
    if (status == 'http_5xx' || status == 'timeout') return context.cs.error;
    if (status == 'http_4xx') return Colors.orange;
    return context.cs.onSurfaceVariant;
  }

  IconData _kindIcon(AgentOperationKind kind) {
    return switch (kind) {
      AgentOperationKind.memorySidecar => Icons.memory,
      AgentOperationKind.postCleaner => Icons.cleaning_services_outlined,
      AgentOperationKind.agenticSearch => Icons.search,
      AgentOperationKind.classifier => Icons.category_outlined,
      AgentOperationKind.consolidation => Icons.merge_type_outlined,
      AgentOperationKind.studioController => Icons.auto_awesome_outlined,
      AgentOperationKind.studioFinal => Icons.edit_note,
      AgentOperationKind.factChecker => Icons.fact_check_outlined,
      AgentOperationKind.studioLedger => Icons.menu_book_outlined,
      AgentOperationKind.studioLedgerReconciliation =>
        Icons.fact_check_outlined,
    };
  }

  void _showRegenHint(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'This operation will be retried automatically on the next '
          'generation that triggers it.',
        ),
        duration: Duration(seconds: 3),
      ),
    );
  }
}
