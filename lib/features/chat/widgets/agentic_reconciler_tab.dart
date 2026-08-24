import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_db.dart' show LedgerDebugRunRow;
import '../../../core/models/chat_message.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../services/manual_studio_ledger_service.dart';
import '../services/reconciler_view_service.dart';

class AgenticReconcilerTab extends ConsumerStatefulWidget {
  const AgenticReconcilerTab({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<AgenticReconcilerTab> createState() =>
      _AgenticReconcilerTabState();
}

class _AgenticReconcilerTabState extends ConsumerState<AgenticReconcilerTab> {
  bool _runningLedger = false;
  bool _runningReconciliation = false;

  Future<void> _refresh() async {
    ref.invalidate(reconcilerViewProvider(widget.sessionId));
    await ref.read(reconcilerViewProvider(widget.sessionId).future);
  }

  Future<ChatMessage?> _latestAssistant() async {
    final session = await ref.read(chatRepoProvider).getById(widget.sessionId);
    for (final message
        in (session?.messages ?? const <ChatMessage>[]).reversed) {
      if (message.role == 'assistant' &&
          !message.isError &&
          !message.isTyping &&
          message.content.trim().isNotEmpty) {
        return message;
      }
    }
    return null;
  }

  Future<void> _runReconciliation() async {
    if (_runningReconciliation) return;
    setState(() => _runningReconciliation = true);
    try {
      final outcome = await ref
          .read(manualStudioLedgerServiceProvider)
          .reconcile(widget.sessionId);
      if (!mounted) return;
      final result = outcome.result;
      GlazeToast.show(
        context,
        result.status == 'ok'
            ? 'Ledger reconciliation completed: ${result.opsApplied} ops.'
            : 'Ledger reconciliation failed: ${result.error ?? result.status}',
        isError: result.status != 'ok',
        position: ToastPosition.top,
      );
      await _refresh();
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'Ledger reconciliation failed: $error',
          isError: true,
          position: ToastPosition.top,
        );
      }
    } finally {
      if (mounted) setState(() => _runningReconciliation = false);
    }
  }

  Future<void> _rerunLedger() async {
    if (_runningLedger) return;
    final target = await _latestAssistant();
    if (target == null || !mounted) return;
    setState(() => _runningLedger = true);
    try {
      final outcome = await ref
          .read(manualStudioLedgerServiceProvider)
          .rerun(sessionId: widget.sessionId, target: target);
      if (!mounted) return;
      final result = outcome.result;
      GlazeToast.show(
        context,
        result.status == 'ok'
            ? 'Studio Ledger rerun completed: ${result.opsApplied} ops.'
            : 'Studio Ledger rerun failed: ${result.error ?? result.status}',
        isError: result.status != 'ok',
        position: ToastPosition.top,
      );
      await _refresh();
    } on ManualStudioLedgerConfigException catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'Studio Ledger rerun failed: $error',
          isError: true,
          position: ToastPosition.top,
        );
      }
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'Studio Ledger rerun failed: $error',
          isError: true,
          position: ToastPosition.top,
        );
      }
    } finally {
      if (mounted) setState(() => _runningLedger = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ledgerEnabled =
        ref.watch(studioPresetProvider).value?.agentEnabled['ledger'] != false;
    final snapshot = ref.watch(reconcilerViewProvider(widget.sessionId));
    return snapshot.when(
      loading: () => const Center(child: GlazeSpinner()),
      error: (error, _) => _ErrorState(error: error, onRetry: _refresh),
      data: (data) => RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
          children: [
            GlassSurface(
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.chainIsValid
                          ? '${data.runs.where((run) => run.isCurrent).length} current commits'
                          : 'Reconciliation chain integrity failure',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      data.checkpoint == null
                          ? 'No reconciliation checkpoint yet.'
                          : 'Checkpoint: ${data.checkpoint!.messageIds.length} messages, ending at ${data.checkpoint!.endMessageId}',
                      style: TextStyle(
                        color: context.cs.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed:
                              ledgerEnabled &&
                                  !_runningLedger &&
                                  !_runningReconciliation
                              ? _runReconciliation
                              : null,
                          icon: _runningReconciliation
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: GlazeSpinner(),
                                )
                              : const Icon(Icons.rule_folder_outlined),
                          label: const Text('Run reconciliation'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed:
                              ledgerEnabled &&
                                  !_runningLedger &&
                                  !_runningReconciliation
                              ? _rerunLedger
                              : null,
                          icon: _runningLedger
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: GlazeSpinner(),
                                )
                              : const Icon(Icons.replay_outlined),
                          label: const Text('Rerun latest Ledger'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text('Commits', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            if (data.runs.isEmpty)
              const _EmptyState(
                text: 'No reconciliation commits recorded for this session.',
              )
            else
              for (final run in data.runs.reversed) _RunTile(run: run),
            const SizedBox(height: 14),
            Text(
              'Parsing attempts',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            if (data.debugRuns.isEmpty)
              const _EmptyState(
                text: 'No durable reconciliation responses recorded yet.',
              )
            else
              for (final run in data.debugRuns) _DebugTile(row: run),
          ],
        ),
      ),
    );
  }
}

class _RunTile extends StatelessWidget {
  const _RunTile({required this.run});

  final ReconciliationRunView run;

  @override
  Widget build(BuildContext context) {
    final (icon, color, status) = switch (run.status) {
      ReconciliationRunViewStatus.current => (
        Icons.check_circle_outline,
        context.cs.primary,
        'Current',
      ),
      ReconciliationRunViewStatus.invalidated => (
        Icons.block_outlined,
        context.cs.error,
        'Invalidated',
      ),
      ReconciliationRunViewStatus.stale => (
        Icons.history_toggle_off,
        Colors.orange,
        'Stale evidence',
      ),
      ReconciliationRunViewStatus.chainCorrupt => (
        Icons.warning_amber_rounded,
        context.cs.error,
        'Chain corrupt',
      ),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ExpansionTile(
        leading: Icon(icon, color: color),
        title: Text(run.label),
        subtitle: Text('$status · ${run.approximateOperations.length} ops'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MonoDetail(label: 'Run ID', value: run.row.id),
          _MonoDetail(label: 'Range hash', value: run.row.rangeHash),
          _MonoDetail(label: 'Chain hash', value: run.row.chainHash),
          if (run.invalidation != null)
            _MonoDetail(label: 'Invalidation', value: run.invalidation!.reason),
          const SizedBox(height: 6),
          Text(
            run.approximateOperations.isEmpty
                ? 'Exact before/after diff is unavailable for this legacy commit.'
                : 'Approximate operations:\n${run.approximateOperations.join('\n')}',
            style: TextStyle(
              color: context.cs.onSurfaceVariant,
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _DebugTile extends StatelessWidget {
  const _DebugTile({required this.row});

  final LedgerDebugRunRow row;

  @override
  Widget build(BuildContext context) {
    final failed = row.status != 'ok' || row.parseFailure != 'none';
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ExpansionTile(
        leading: Icon(
          failed ? Icons.error_outline : Icons.data_object,
          color: failed ? context.cs.error : context.cs.primary,
        ),
        title: Text('${row.status} · ${row.model}'),
        subtitle: Text(
          failed
              ? row.rejectionReason ?? row.error ?? row.parseFailure
              : 'Parsed',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MonoDetail(label: 'Endpoint', value: row.messageId),
          _MonoDetail(label: 'Parse', value: row.parseFailure),
          const SizedBox(height: 6),
          SelectableText(
            row.responseText ?? 'Raw response unavailable for this run.',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
          if (row.repairResponseText != null) ...[
            const SizedBox(height: 10),
            const Text('Repair response'),
            SelectableText(
              row.repairResponseText!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

class _MonoDetail extends StatelessWidget {
  const _MonoDetail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: SelectableText(
      '$label: $value',
      style: TextStyle(
        color: context.cs.onSurfaceVariant,
        fontFamily: 'monospace',
        fontSize: 11,
      ),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 12),
      ),
    ),
  );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Could not load Reconciler: $error',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    ),
  );
}
