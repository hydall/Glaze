import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../state/agent_operations_log_provider.dart';
import 'agentic_operations_log_dialog.dart' show AgenticSessionScope, OperationTile;

enum _LogFilter { all, failed, success }

class AgenticOperationsTab extends ConsumerStatefulWidget {
  const AgenticOperationsTab({super.key});

  @override
  ConsumerState<AgenticOperationsTab> createState() =>
      _AgenticOperationsTabState();
}

class _AgenticOperationsTabState extends ConsumerState<AgenticOperationsTab> {
  _LogFilter _filter = _LogFilter.all;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(agentOperationsLogProvider);
    final sessionId = _sessionIdOf(context);
    final allRecords = state.forSession(sessionId);
    final filtered = switch (_filter) {
      _LogFilter.all => allRecords,
      _LogFilter.failed => allRecords.where((r) => r.status.isFailure).toList(),
      _LogFilter.success => allRecords.where((r) => r.status.isOk).toList(),
    };
    filtered.sort((a, b) => b.finishedAtMs.compareTo(a.finishedAtMs));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              SegmentedButton<_LogFilter>(
                segments: const [
                  ButtonSegment(value: _LogFilter.all, label: Text('All')),
                  ButtonSegment(
                    value: _LogFilter.failed,
                    label: Text('Failed'),
                    icon: Icon(Icons.error_outline, size: 16),
                  ),
                  ButtonSegment(
                    value: _LogFilter.success,
                    label: Text('Success'),
                    icon: Icon(Icons.check_circle_outline, size: 16),
                  ),
                ],
                selected: {_filter},
                onSelectionChanged: (s) => setState(() => _filter = s.first),
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
              const SizedBox(width: 8),
              Text(
                '${filtered.length} ops',
                style: TextStyle(
                  fontSize: 11,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (state.records.isNotEmpty)
                IconButton(
                  onPressed: () => _confirmClear(context),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  tooltip: 'Clear log',
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No agentic operations recorded yet.\n\n'
                      'Operations appear here when the POST-cleaner, Studio '
                      'Ledger, tracker agents, or agentic memory search/write '
                      'tools are invoked during generation.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.cs.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 12, endIndent: 12),
                  itemBuilder: (context, i) =>
                      OperationTile(record: filtered[i]),
                ),
        ),
      ],
    );
  }

  String? _sessionIdOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AgenticSessionScope>();
    return scope?.sessionId;
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear operations log?'),
        content: const Text(
          'This removes all recorded agentic operations from memory. '
          'The chat itself is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(agentOperationsLogProvider.notifier).state =
          const AgentOperationsLogState();
    }
  }
}
