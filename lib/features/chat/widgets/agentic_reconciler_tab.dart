import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_db.dart' show LedgerDebugRunRow;
import '../../../core/models/chat_message.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../services/current_ledger_injection_preview_service.dart';
import '../services/manual_studio_ledger_service.dart';
import '../services/reconciler_view_service.dart';
import 'current_ledger_injection_preview.dart';

class AgenticReconcilerTab extends ConsumerStatefulWidget {
  const AgenticReconcilerTab({
    super.key,
    required this.sessionId,
    this.characterId,
  });

  final String sessionId;
  final String? characterId;

  @override
  ConsumerState<AgenticReconcilerTab> createState() =>
      _AgenticReconcilerTabState();
}

class _AgenticReconcilerTabState extends ConsumerState<AgenticReconcilerTab> {
  bool _runningLedger = false;
  bool _runningReconciliation = false;
  String? _regeneratingRunId;

  Future<void> _refresh() async {
    final previewKey = (
      sessionId: widget.sessionId,
      characterId: widget.characterId,
    );
    ref.invalidate(reconcilerViewProvider(widget.sessionId));
    ref.invalidate(currentLedgerInjectionPreviewProvider(previewKey));
    await Future.wait([
      ref.read(reconcilerViewProvider(widget.sessionId).future),
      ref.read(currentLedgerInjectionPreviewProvider(previewKey).future),
    ]);
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
            ? 'agent_ops_reconciliation_completed'.tr(
                namedArgs: {'count': '${result.opsApplied}'},
              )
            : 'agent_ops_reconciliation_failed'.tr(
                namedArgs: {'error': result.error ?? result.status},
              ),
        isError: result.status != 'ok',
        position: ToastPosition.top,
      );
      await _refresh();
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'agent_ops_reconciliation_failed'.tr(namedArgs: {'error': '$error'}),
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
            ? 'agent_ops_ledger_rerun_completed'.tr(
                namedArgs: {'count': '${result.opsApplied}'},
              )
            : 'agent_ops_ledger_rerun_failed'.tr(
                namedArgs: {'error': result.error ?? result.status},
              ),
        isError: result.status != 'ok',
        position: ToastPosition.top,
      );
      await _refresh();
    } on ManualStudioLedgerConfigException catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'agent_ops_ledger_rerun_failed'.tr(namedArgs: {'error': '$error'}),
          isError: true,
          position: ToastPosition.top,
        );
      }
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'agent_ops_ledger_rerun_failed'.tr(namedArgs: {'error': '$error'}),
          isError: true,
          position: ToastPosition.top,
        );
      }
    } finally {
      if (mounted) setState(() => _runningLedger = false);
    }
  }

  Future<void> _regenerate(ReconciliationRunView run) async {
    if (_regeneratingRunId != null) return;
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'agent_ops_regenerate_title'.tr(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'agent_ops_regenerate_body'.tr(
                namedArgs: {'commit': _runLabel(run)},
              ),
              style: TextStyle(color: context.cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context, rootNavigator: true).pop(true),
              child: Text('agent_ops_regenerate'.tr()),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context, rootNavigator: true).pop(false),
              child: Text('btn_cancel'.tr()),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _regeneratingRunId = run.row.id);
    try {
      final outcome = await ref
          .read(manualStudioLedgerServiceProvider)
          .regenerateLatest(
            sessionId: widget.sessionId,
            expectedRunId: run.row.id,
          );
      if (!mounted) return;
      final result = outcome.result;
      GlazeToast.show(
        context,
        result.status == 'ok'
            ? result.opsApplied == 0
                  ? 'agent_ops_regeneration_unchanged'.tr()
                  : 'agent_ops_regeneration_completed'.tr(
                      namedArgs: {'count': '${result.opsApplied}'},
                    )
            : 'agent_ops_regeneration_failed'.tr(
                namedArgs: {
                  'error': _localizedRegenerationError(
                    result.error ?? result.status,
                  ),
                },
              ),
        isError: result.status != 'ok',
        position: ToastPosition.top,
      );
      await _refresh();
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'agent_ops_regeneration_failed'.tr(namedArgs: {'error': '$error'}),
          isError: true,
          position: ToastPosition.top,
        );
      }
    } finally {
      if (mounted) setState(() => _regeneratingRunId = null);
    }
  }

  String _localizedRegenerationError(String error) => switch (error) {
    'Another reconciliation is already running for this session' =>
      'agent_ops_reconciliation_busy'.tr(),
    'An applied Card Rewriter proposal depends on this reconciliation' =>
      'agent_ops_regeneration_applied_dependency'.tr(),
    _ => error,
  };

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
                          ? 'agent_ops_current_commits'.tr(
                              namedArgs: {
                                'count':
                                    '${data.runs.where((run) => run.isCurrent).length}',
                              },
                            )
                          : 'agent_ops_chain_integrity_failure'.tr(),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      data.checkpoint == null
                          ? 'agent_ops_no_checkpoint'.tr()
                          : 'agent_ops_checkpoint'.tr(
                              namedArgs: {
                                'count':
                                    '${data.checkpoint!.messageIds.length}',
                                'messageId': data.checkpoint!.endMessageId,
                              },
                            ),
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
                                  !_runningReconciliation &&
                                  _regeneratingRunId == null
                              ? _runReconciliation
                              : null,
                          icon: _runningReconciliation
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: GlazeSpinner(),
                                )
                              : const Icon(Icons.rule_folder_outlined),
                          label: Text('agent_ops_run_reconciliation'.tr()),
                        ),
                        FilledButton.tonalIcon(
                          onPressed:
                              ledgerEnabled &&
                                  !_runningLedger &&
                                  !_runningReconciliation &&
                                  _regeneratingRunId == null
                              ? _rerunLedger
                              : null,
                          icon: _runningLedger
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: GlazeSpinner(),
                                )
                              : const Icon(Icons.replay_outlined),
                          label: Text('agent_ops_rerun_ledger'.tr()),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            CurrentLedgerInjectionPreviewCard(
              sessionId: widget.sessionId,
              characterId: widget.characterId,
            ),
            const SizedBox(height: 14),
            Text(
              'agent_ops_commits'.tr(),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            if (data.runs.isEmpty)
              _EmptyState(text: 'agent_ops_no_commits'.tr())
            else
              for (final run in data.runs.reversed)
                _RunTile(
                  run: run,
                  onRegenerate:
                      data.chainIsValid &&
                          run.isCurrent &&
                          run.effect != null &&
                          !_runningLedger &&
                          !_runningReconciliation &&
                          _regeneratingRunId == null &&
                          run.row.id ==
                              data.runs
                                  .lastWhere((item) => item.isCurrent)
                                  .row
                                  .id
                      ? () => _regenerate(run)
                      : null,
                  regenerating: _regeneratingRunId == run.row.id,
                ),
            const SizedBox(height: 14),
            Text(
              'agent_ops_parsing_attempts'.tr(),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            if (data.debugRuns.isEmpty)
              _EmptyState(text: 'agent_ops_no_responses'.tr())
            else
              for (final run in data.debugRuns) _DebugTile(row: run),
          ],
        ),
      ),
    );
  }
}

class _RunTile extends StatelessWidget {
  const _RunTile({
    required this.run,
    required this.onRegenerate,
    required this.regenerating,
  });

  final ReconciliationRunView run;
  final VoidCallback? onRegenerate;
  final bool regenerating;

  @override
  Widget build(BuildContext context) {
    final (icon, color, status) = switch (run.status) {
      ReconciliationRunViewStatus.current => (
        Icons.check_circle_outline,
        context.cs.primary,
        'agent_ops_status_current'.tr(),
      ),
      ReconciliationRunViewStatus.invalidated => (
        Icons.block_outlined,
        context.cs.error,
        'agent_ops_status_invalidated'.tr(),
      ),
      ReconciliationRunViewStatus.stale => (
        Icons.history_toggle_off,
        Colors.orange,
        'agent_ops_status_stale'.tr(),
      ),
      ReconciliationRunViewStatus.chainCorrupt => (
        Icons.warning_amber_rounded,
        context.cs.error,
        'agent_ops_status_chain_corrupt'.tr(),
      ),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ExpansionTile(
        leading: Icon(icon, color: color),
        title: Text(_runLabel(run)),
        subtitle: Text(
          'agent_ops_commit_summary'.tr(
            namedArgs: {
              'status': status,
              'count': '${run.approximateOperations.length}',
            },
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MonoDetail(label: 'agent_ops_run_id'.tr(), value: run.row.id),
          _MonoDetail(
            label: 'agent_ops_range_hash'.tr(),
            value: run.row.rangeHash,
          ),
          _MonoDetail(
            label: 'agent_ops_chain_hash'.tr(),
            value: run.row.chainHash,
          ),
          if (run.invalidation != null)
            _MonoDetail(
              label: 'agent_ops_invalidation'.tr(),
              value: run.invalidation!.reason,
            ),
          if (onRegenerate != null) ...[
            const SizedBox(height: 6),
            FilledButton.tonalIcon(
              onPressed: regenerating ? null : onRegenerate,
              icon: regenerating
                  ? const SizedBox.square(dimension: 16, child: GlazeSpinner())
                  : const Icon(Icons.refresh_outlined),
              label: Text('agent_ops_regenerate'.tr()),
            ),
          ],
          const SizedBox(height: 6),
          if (run.effect != null) ...[
            _MonoDetail(
              label: 'agent_ops_before_state'.tr(),
              value: run.effect!.beforeStateHash,
            ),
            _MonoDetail(
              label: 'agent_ops_after_state'.tr(),
              value: run.effect!.afterStateHash,
            ),
            const SizedBox(height: 6),
            SelectableText(
              run.effect!.actualEffectsJson,
              style: TextStyle(
                color: context.cs.onSurfaceVariant,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ] else
            Text(
              run.approximateOperations.isEmpty
                  ? 'agent_ops_exact_diff_unavailable'.tr()
                  : 'agent_ops_approximate_operations'.tr(
                      namedArgs: {
                        'operations': run.approximateOperations.join('\n'),
                      },
                    ),
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
              : 'agent_ops_parsed'.tr(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MonoDetail(label: 'agent_ops_endpoint'.tr(), value: row.messageId),
          _MonoDetail(label: 'agent_ops_parse'.tr(), value: row.parseFailure),
          const SizedBox(height: 6),
          SelectableText(
            row.responseText ?? 'agent_ops_raw_response_unavailable'.tr(),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
          if (row.repairResponseText != null) ...[
            const SizedBox(height: 10),
            Text('agent_ops_repair_response'.tr()),
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
            'agent_ops_reconciler_load_failed'.tr(
              namedArgs: {'error': '$error'},
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text('btn_retry'.tr()),
          ),
        ],
      ),
    ),
  );
}

String _runLabel(ReconciliationRunView run) {
  final first = run.firstMessageOrdinal;
  final last = run.lastMessageOrdinal;
  if (first == null || last == null) {
    return 'agent_ops_commit_messages'.tr(
      namedArgs: {
        'ordinal': '${run.row.ordinal}',
        'count': '${run.messageIds.length}',
      },
    );
  }
  return 'agent_ops_commit_range'.tr(
    namedArgs: {
      'ordinal': '${run.row.ordinal}',
      'start': '$first',
      'end': '$last',
    },
  );
}
