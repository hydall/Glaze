import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/card_evolution_observation.dart';
import '../../../core/state/card_rewriter_providers.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_text_field.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../services/collector_view_service.dart';
import '../services/prompt_capture_view_service.dart';

class AgenticCollectorTab extends ConsumerStatefulWidget {
  const AgenticCollectorTab({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<AgenticCollectorTab> createState() =>
      _AgenticCollectorTabState();
}

class _AgenticCollectorTabState extends ConsumerState<AgenticCollectorTab> {
  String? _recoveringRunId;
  bool _runningPending = false;

  Future<void> _runPendingCollectors() async {
    if (_runningPending || _recoveringRunId != null) return;
    setState(() => _runningPending = true);
    try {
      final outcome = await ref
          .read(automatedCardEvolutionServiceProvider)
          .runPendingCollectors(widget.sessionId);
      if (!mounted) return;
      _refresh();
      final isFailure = const {
        'disabled',
        'collectorUnavailable',
        'unexpectedFailure',
      }.contains(outcome.kind);
      GlazeToast.show(
        context,
        _pendingRunMessage(outcome.kind, outcome.detail),
        isError: isFailure,
      );
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'agent_ops_collector_run_failed'.tr(namedArgs: {'error': '$error'}),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _runningPending = false);
    }
  }

  Future<void> _retryCollector(CollectorRunView run) async {
    if (_runningPending || _recoveringRunId != null || !run.canRetry) {
      return;
    }
    setState(() => _recoveringRunId = run.row.id);
    try {
      final outcome = await ref
          .read(automatedCardEvolutionServiceProvider)
          .retryFailedCollector(run.row.id);
      if (!mounted) return;
      _refresh();
      GlazeToast.show(context, _recoveryMessage(outcome.kind, outcome.detail));
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'agent_ops_collector_retry_failed'.tr(namedArgs: {'error': '$error'}),
        );
      }
    } finally {
      if (mounted) setState(() => _recoveringRunId = null);
    }
  }

  Future<void> _correct(CollectorRunView run) async {
    if (_runningPending || _recoveringRunId != null) return;
    final controller = TextEditingController(text: run.latestResponse ?? '');
    String? response;
    await GlazeBottomSheet.show<void>(
      context,
      title: 'agent_ops_collector_correct_title'.tr(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('agent_ops_collector_correct_body'.tr()),
            const SizedBox(height: 12),
            GlazeTextField(
              controller: controller,
              maxLines: 12,
              hint: '{"observations": []}',
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                response = controller.text.trim();
                Navigator.of(context, rootNavigator: true).pop();
              },
              child: Text('agent_ops_validate_apply'.tr()),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (!mounted || response == null || response!.isEmpty) return;
    setState(() => _recoveringRunId = run.row.id);
    try {
      final outcome = await ref
          .read(automatedCardEvolutionServiceProvider)
          .correctFailedCollector(run.row.id, response: response!);
      if (!mounted) return;
      _refresh();
      GlazeToast.show(context, _recoveryMessage(outcome.kind, outcome.detail));
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'agent_ops_collector_correction_failed'.tr(
            namedArgs: {'error': '$error'},
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _recoveringRunId = null);
    }
  }

  void _refresh() {
    ref.invalidate(collectorViewProvider(widget.sessionId));
    ref.invalidate(promptCaptureViewsProvider(widget.sessionId));
  }

  static String _recoveryMessage(String kind, String? detail) => switch (kind) {
    'collectorCompleted' => 'agent_ops_collector_recovery_completed'.tr(),
    'persisted' ||
    'alreadyCompleted' => 'agent_ops_collector_proposal_ready'.tr(),
    'exactCaptureUnavailable' => 'agent_ops_collector_exact_unavailable'.tr(),
    'staleInput' ||
    'collectorEvidenceStale' => 'agent_ops_collector_evidence_changed'.tr(),
    'parserRejected' => detail ?? 'agent_ops_collector_response_invalid'.tr(),
    _ =>
      detail ??
          'agent_ops_collector_recovery_stopped'.tr(namedArgs: {'kind': kind}),
  };

  static String _pendingRunMessage(String kind, String? detail) =>
      switch (kind) {
        'collectorCompleted' => 'agent_ops_collector_run_completed'.tr(),
        'collectorUpToDate' => 'agent_ops_collector_up_to_date'.tr(),
        'persisted' ||
        'alreadyCompleted' => 'agent_ops_collector_proposal_ready'.tr(),
        _ =>
          detail ??
              'agent_ops_collector_run_stopped'.tr(namedArgs: {'kind': kind}),
      };

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(collectorViewProvider(widget.sessionId));
    return snapshot.when(
      loading: () => const Center(child: GlazeSpinner()),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'agent_ops_collector_load_failed'.tr(
                  namedArgs: {'error': '$error'},
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () =>
                    ref.invalidate(collectorViewProvider(widget.sessionId)),
                icon: const Icon(Icons.refresh),
                label: Text('btn_retry'.tr()),
              ),
            ],
          ),
        ),
      ),
      data: (data) => RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(collectorViewProvider(widget.sessionId));
          await ref.read(collectorViewProvider(widget.sessionId).future);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
          children: [
            GlassSurface(
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    _SummaryValue(
                      label: 'agent_ops_runs'.tr(),
                      value: '${data.runs.length}',
                    ),
                    _SummaryValue(
                      label: 'agent_ops_completed'.tr(),
                      value:
                          '${data.runs.where((run) => run.row.status == 'completed').length}',
                    ),
                    _SummaryValue(
                      label: 'agent_ops_observations'.tr(),
                      value: '${data.observations.length}',
                    ),
                  ],
                ),
              ),
            ),
            if (data.unclaimedPairCount > 0) ...[
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: _runningPending || _recoveringRunId != null
                    ? null
                    : _runPendingCollectors,
                icon: _runningPending
                    ? const SizedBox.square(
                        dimension: 16,
                        child: GlazeSpinner(),
                      )
                    : const Icon(Icons.play_arrow_outlined),
                label: Text(
                  'agent_ops_run_collector'.tr(
                    namedArgs: {'count': '${data.unclaimedPairCount}'},
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              'agent_ops_collector_runs'.tr(),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            if (data.runs.isEmpty)
              _CollectorEmpty(text: 'agent_ops_no_collector_runs'.tr())
            else
              for (final run in data.runs)
                Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ExpansionTile(
                    leading: Icon(
                      switch (run.row.status) {
                        'completed' => Icons.check_circle_outline,
                        'failed' => Icons.error_outline,
                        _ => Icons.hourglass_top,
                      },
                      color: switch (run.row.status) {
                        'completed' => context.cs.primary,
                        'failed' => context.cs.error,
                        _ => Colors.orange,
                      },
                    ),
                    title: Text(_collectorRunLabel(run)),
                    subtitle: Text(_collectorStatusLabel(run.row.status)),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Detail(
                        label: 'agent_ops_run_id'.tr(),
                        value: run.row.id,
                      ),
                      _Detail(
                        label: 'agent_ops_reconciliation'.tr(),
                        value: run.row.reconciliationRunId,
                      ),
                      _Detail(
                        label: 'agent_ops_range_hash'.tr(),
                        value: run.row.rangeHash,
                      ),
                      _Detail(
                        label: 'agent_ops_input_hash'.tr(),
                        value: run.row.inputHash,
                      ),
                      _Detail(
                        label: 'agent_ops_output_hash'.tr(),
                        value:
                            run.row.modelOutputHash ??
                            'agent_ops_unavailable'.tr(),
                      ),
                      if (run.row.failureCode != null)
                        _Detail(
                          label: 'agent_ops_failure'.tr(),
                          value: run.row.failureCode!,
                        ),
                      if (run.row.failureDetail != null)
                        _Detail(
                          label: 'agent_ops_failure_detail'.tr(),
                          value: run.row.failureDetail!,
                        ),
                      if (run.latestResponse != null)
                        _Detail(
                          label: 'agent_ops_last_response'.tr(),
                          value: run.latestResponse!,
                        ),
                      if (run.latestParserVerdict case final verdict?) ...[
                        _Detail(
                          label: 'agent_ops_parser_verdict'.tr(),
                          value:
                              '${verdict.kind}: ${verdict.parserCode ?? 'agent_ops_unknown'.tr()}',
                        ),
                        if (verdict.parserDetail != null)
                          _Detail(
                            label: 'agent_ops_parser_detail'.tr(),
                            value: verdict.parserDetail!,
                          ),
                      ],
                      const SizedBox(height: 6),
                      if (run.row.status == 'failed') ...[
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed:
                                  !_runningPending &&
                                      _recoveringRunId == null &&
                                      run.canRetry
                                  ? () => _retryCollector(run)
                                  : null,
                              icon: const Icon(Icons.refresh),
                              label: Text(
                                (run.canRetryExact
                                        ? 'agent_ops_retry_exact_prompt'
                                        : 'agent_ops_retry_collector')
                                    .tr(),
                              ),
                            ),
                            FilledButton.icon(
                              onPressed:
                                  !_runningPending && _recoveringRunId == null
                                  ? () => _correct(run)
                                  : null,
                              icon: const Icon(Icons.edit_outlined),
                              label: Text('agent_ops_correct_response'.tr()),
                            ),
                          ],
                        ),
                        if (!run.canRetryExact)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'agent_ops_retry_rebuild_notice'.tr(),
                              style: TextStyle(
                                color: context.cs.onSurfaceVariant,
                                fontSize: 11,
                              ),
                            ),
                          ),
                      ] else if (run.callEvents.isEmpty)
                        Text(
                          'agent_ops_legacy_details_unavailable'.tr(),
                          style: TextStyle(
                            color: context.cs.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
            const SizedBox(height: 14),
            Text(
              'agent_ops_observations'.tr(),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            if (data.observations.isEmpty)
              _CollectorEmpty(text: 'agent_ops_no_observations'.tr())
            else
              for (final observation in data.observations)
                _ObservationTile(observation: observation),
          ],
        ),
      ),
    );
  }
}

class _SummaryValue extends StatelessWidget {
  const _SummaryValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(value, style: Theme.of(context).textTheme.titleLarge),
        Text(
          label,
          style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 11),
        ),
      ],
    ),
  );
}

class _ObservationTile extends StatelessWidget {
  const _ObservationTile({required this.observation});

  final CardEvolutionObservation observation;

  @override
  Widget build(BuildContext context) {
    final color = switch (observation.status) {
      'promoted' => context.cs.primary,
      'expired' => context.cs.error,
      'consumed' => context.cs.onSurfaceVariant,
      _ => Colors.orange,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ExpansionTile(
        leading: Icon(Icons.auto_awesome_outlined, color: color),
        title: Text(observation.observedChange),
        subtitle: Text(
          'agent_ops_observation_summary'.tr(
            namedArgs: {
              'status': _observationStatusLabel(observation.status),
              'confidence': '${(observation.confidence * 100).round()}',
              'count': '${observation.repeatCount}',
            },
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Detail(
            label: 'agent_ops_scope'.tr(),
            value: observation.semanticScopeKey,
          ),
          _Detail(
            label: 'agent_ops_target'.tr(),
            value: observation.targetKind ?? 'agent_ops_unavailable'.tr(),
          ),
          if (observation.canonicalClaim != null)
            _Detail(
              label: 'agent_ops_claim'.tr(),
              value: observation.canonicalClaim!,
            ),
          _Detail(
            label: 'agent_ops_evidence'.tr(),
            value: observation.evidenceMessageIds.join(', '),
          ),
        ],
      ),
    );
  }
}

String _collectorRunLabel(CollectorRunView run) {
  final first = run.firstReconciliationOrdinal;
  if (first == null) {
    return 'agent_ops_collector_run'.tr(
      namedArgs: {'ordinal': '${run.row.collectorOrdinal}'},
    );
  }
  return 'agent_ops_collector_run_commits'.tr(
    namedArgs: {
      'ordinal': '${run.row.collectorOrdinal}',
      'start': '$first',
      'end': '${run.boundaryReconciliationOrdinal}',
    },
  );
}

String _collectorStatusLabel(String status) => switch (status) {
  'completed' => 'agent_ops_status_completed'.tr(),
  'failed' => 'agent_ops_status_failed'.tr(),
  _ => 'agent_ops_status_pending'.tr(),
};

String _observationStatusLabel(String status) => switch (status) {
  'promoted' => 'agent_ops_status_promoted'.tr(),
  'expired' => 'agent_ops_status_expired'.tr(),
  'consumed' => 'agent_ops_status_consumed'.tr(),
  'active' => 'agent_ops_status_active'.tr(),
  _ => status,
};

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});

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

class _CollectorEmpty extends StatelessWidget {
  const _CollectorEmpty({required this.text});

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
