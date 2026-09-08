import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/agent_operation_record.dart';
import '../../../shared/theme/app_colors.dart';
import 'agentic_operations_tab.dart';
import 'agentic_last_turn_tab.dart';
import 'agentic_snapshots_tab.dart';
import 'agentic_tracker_values_tab.dart';
import 'post_cleaner_diff_dialog.dart';

class AgenticOperationsLogDialog extends ConsumerStatefulWidget {
  final String? sessionId;

  const AgenticOperationsLogDialog({super.key, this.sessionId});

  /// Opens the dialog as an overlay. Caller passes the current [sessionId]
  /// so the dialog can scope the list, or null to show operations across all
  /// sessions.
  static Future<void> show(BuildContext context, {String? sessionId}) {
    return showDialog(
      context: context,
      builder: (_) => AgenticOperationsLogDialog(sessionId: sessionId),
    );
  }

  @override
  ConsumerState<AgenticOperationsLogDialog> createState() =>
      _AgenticOperationsLogDialogState();
}

class _AgenticOperationsLogDialogState
    extends ConsumerState<AgenticOperationsLogDialog> {
  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 720,
        height: 560,
        child: DefaultTabController(
          length: 4,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.smart_toy_outlined, color: context.cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Agentic Operations Log',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 20),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(
                    icon: Icon(Icons.history_outlined, size: 16),
                    text: 'Operations',
                  ),
                  Tab(
                    icon: Icon(Icons.track_changes_outlined, size: 16),
                    text: 'Tracker values',
                  ),
                  Tab(
                    icon: Icon(Icons.warning_amber_outlined, size: 16),
                    text: 'Last turn',
                  ),
                  Tab(
                    icon: Icon(Icons.history_edu_outlined, size: 16),
                    text: 'Snapshots',
                  ),
                ],
                tabAlignment: TabAlignment.fill,
              ),
              Expanded(
                child: AgenticSessionScope(
                  sessionId: widget.sessionId,
                  child: const TabBarView(
                    children: [
                      AgenticOperationsTab(),
                      AgenticTrackerValuesTab(),
                      AgenticLastTurnTab(),
                      AgenticSnapshotsTab(),
                    ],
                  ),
                ),
              ),
            ],
          ),
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
      AgentOperationKind.studioTracker => Icons.auto_awesome_outlined,
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
