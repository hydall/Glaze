import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/studio_ledger_service.dart';
import '../../../core/models/agent_operation_record.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/tracker.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../services/manual_studio_ledger_service.dart';
import '../state/agent_operations_log_provider.dart';
import 'agentic_operations_log_dialog.dart'
    show AgenticSessionScope, OperationTile;

class AgenticLastTurnTab extends ConsumerStatefulWidget {
  const AgenticLastTurnTab({super.key});

  @override
  ConsumerState<AgenticLastTurnTab> createState() => _AgenticLastTurnTabState();
}

class _AgenticLastTurnTabState extends ConsumerState<AgenticLastTurnTab> {
  bool _runningLedger = false;
  bool _runningReconciliation = false;

  @override
  Widget build(BuildContext context) {
    final sessionId = _sessionIdOf(context);
    if (sessionId == null) {
      return Center(
        child: Text(
          'Open Agentic Ops from a chat to inspect the last turn.',
          style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 12),
        ),
      );
    }
    final state = ref.watch(agentOperationsLogProvider);
    return FutureBuilder<ChatMessage?>(
      future: _latestAssistant(sessionId),
      builder: (context, snapshot) {
        final last = snapshot.data;
        final records = last == null
            ? <AgentOperationRecord>[]
            : state
                  .forSession(sessionId)
                  .where((r) => r.messageId == last.id)
                  .toList();
        records.sort((a, b) => a.startedAtMs.compareTo(b.startedAtMs));
        final failed = records.where((r) => r.status.isFailure).toList();

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    last == null
                        ? 'No assistant turn found.'
                        : 'Latest assistant turn: ${last.id}',
                    style: TextStyle(
                      fontSize: 11,
                      color: context.cs.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed:
                            last == null ||
                                _runningLedger ||
                                _runningReconciliation
                            ? null
                            : () => _runReconciliation(sessionId),
                        icon: _runningReconciliation
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.rule_folder_outlined, size: 16),
                        label: const Text('Run reconciliation'),
                      ),
                      FilledButton.icon(
                        onPressed:
                            last == null ||
                                _runningLedger ||
                                _runningReconciliation
                            ? null
                            : () => _rerunLedger(sessionId, last),
                        icon: _runningLedger
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.replay_outlined, size: 16),
                        label: const Text('Rerun Studio Ledger'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (failed.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${failed.length} failed operation(s) on this turn',
                    style: TextStyle(fontSize: 11, color: context.cs.error),
                  ),
                ),
              ),
            FutureBuilder<Tracker?>(
              future: ref
                  .read(trackerRepoProvider)
                  .get(sessionId, '_ledger_diag:studio_ledger_reconciliation'),
              builder: (context, diagnosticSnapshot) {
                final diagnostic = diagnosticSnapshot.data;
                if (diagnostic == null) return const SizedBox.shrink();
                return Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: context.cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Latest Ledger reconciliation',
                        style: TextStyle(
                          color: context.cs.onSurface,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        diagnostic.value,
                        style: TextStyle(
                          color: context.cs.onSurfaceVariant,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            Expanded(
              child: records.isEmpty
                  ? Center(
                      child: Text(
                        'No operations recorded for the latest turn yet.',
                        style: TextStyle(
                          color: context.cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: records.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 12, endIndent: 12),
                      itemBuilder: (context, i) =>
                          OperationTile(record: records[i]),
                    ),
            ),
          ],
        );
      },
    );
  }

  String? _sessionIdOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AgenticSessionScope>();
    return scope?.sessionId;
  }

  Future<ChatMessage?> _latestAssistant(String sessionId) async {
    final session = await ref.read(chatRepoProvider).getById(sessionId);
    final messages = session?.messages ?? const <ChatMessage>[];
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role == 'assistant' &&
          !m.isError &&
          !m.isTyping &&
          m.content.trim().isNotEmpty) {
        return m;
      }
    }
    return null;
  }

  Future<void> _rerunLedger(String sessionId, ChatMessage target) async {
    if (_runningLedger) return;
    setState(() => _runningLedger = true);
    final service = ref.read(manualStudioLedgerServiceProvider);
    try {
      final outcome = await service.rerun(sessionId: sessionId, target: target);
      if (!mounted) return;
      final result = outcome.result;
      _appendLedgerRecord(sessionId, target, result, outcome.startedAtMs);
      if (mounted) {
        GlazeToast.show(
          context,
          result.status == 'ok'
              ? 'Studio Ledger rerun ok: ops=${result.opsApplied}'
              : 'Studio Ledger rerun failed: ${result.error ?? result.status}',
          isError: result.status != 'ok',
          duration: 4000,
          position: ToastPosition.top,
        );
      }
    } on ManualStudioLedgerConfigException catch (e) {
      if (mounted) {
        GlazeToast.showWithoutContext(
          'Studio Ledger rerun failed: $e',
          duration: 4000,
          isError: true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      final result = LedgerRunResult(status: 'error', error: '$e');
      _appendLedgerRecord(
        sessionId,
        target,
        result,
        DateTime.now().millisecondsSinceEpoch,
      );
      if (mounted) {
        GlazeToast.show(
          context,
          'Studio Ledger rerun failed: $e',
          isError: true,
          duration: 4000,
          position: ToastPosition.top,
        );
      }
    } finally {
      if (mounted) setState(() => _runningLedger = false);
    }
  }

  Future<void> _runReconciliation(String sessionId) async {
    if (_runningReconciliation) return;
    setState(() => _runningReconciliation = true);
    final service = ref.read(manualStudioLedgerServiceProvider);
    try {
      final outcome = await service.reconcile(sessionId);
      if (!mounted) return;
      final result = outcome.result;
      _appendLedgerRecord(
        sessionId,
        outcome.target,
        result,
        outcome.startedAtMs,
        reconciliation: true,
      );
      GlazeToast.show(
        context,
        result.status == 'ok'
            ? 'Ledger reconciliation ok: ops=${result.opsApplied}'
            : 'Ledger reconciliation failed: ${result.error ?? result.status}',
        isError: result.status != 'ok',
        duration: 4000,
        position: ToastPosition.top,
      );
    } catch (e) {
      if (mounted) {
        GlazeToast.show(
          context,
          'Ledger reconciliation failed: $e',
          isError: true,
          duration: 4000,
          position: ToastPosition.top,
        );
      }
    } finally {
      if (mounted) setState(() => _runningReconciliation = false);
    }
  }

  void _appendLedgerRecord(
    String sessionId,
    ChatMessage target,
    LedgerRunResult result,
    int fallbackStartedAt, {
    bool reconciliation = false,
  }) {
    if (!mounted) return;
    final status = _ledgerStatusToOp(result.status);
    final now = DateTime.now().millisecondsSinceEpoch;
    ref.read(agentOperationsLogProvider.notifier).state = ref
        .read(agentOperationsLogProvider)
        .append(
          AgentOperationRecord(
            id:
                'studio-ledger-${reconciliation ? 'reconciliation-' : ''}manual-'
                '${target.id}-${DateTime.now().microsecondsSinceEpoch}',
            kind: reconciliation
                ? AgentOperationKind.studioLedgerReconciliation
                : AgentOperationKind.studioLedger,
            status: status,
            sessionId: sessionId,
            messageId: target.id,
            attempts: result.attempts,
            totalElapsedMs: result.elapsedMs,
            model: result.model,
            summary: status.isOk
                ? '${reconciliation ? 'manual reconciliation' : 'manual rerun'}: '
                      'ops=${result.opsApplied}'
                : result.error ?? result.status,
            startedAtMs: result.attempts.isNotEmpty
                ? result.attempts.first.startedAtMs
                : fallbackStartedAt,
            finishedAtMs: result.attempts.isNotEmpty
                ? result.attempts.last.startedAtMs +
                      result.attempts.last.elapsedMs
                : now,
            canRegenerate: status.isFailure,
          ),
        );
  }
}

AgentOperationStatus _ledgerStatusToOp(String status) {
  return switch (status) {
    'ok' => AgentOperationStatus.ok,
    'skipped' => AgentOperationStatus.disabled,
    'disabled' => AgentOperationStatus.disabled,
    'aborted' => AgentOperationStatus.aborted,
    'timeout' => AgentOperationStatus.timeout,
    'error' => AgentOperationStatus.error,
    _ => AgentOperationStatus.error,
  };
}
