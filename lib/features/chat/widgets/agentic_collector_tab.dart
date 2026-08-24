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

  Future<void> _retryExact(CollectorRunView run) async {
    if (_recoveringRunId != null || !run.canRetryExact) return;
    setState(() => _recoveringRunId = run.row.id);
    try {
      final outcome = await ref
          .read(automatedCardEvolutionServiceProvider)
          .retryFailedCollector(run.row.id);
      if (!mounted) return;
      _refresh();
      GlazeToast.show(context, _recoveryMessage(outcome.kind, outcome.detail));
    } catch (error) {
      if (mounted) GlazeToast.show(context, 'Collector retry failed: $error');
    } finally {
      if (mounted) setState(() => _recoveringRunId = null);
    }
  }

  Future<void> _correct(CollectorRunView run) async {
    if (_recoveringRunId != null) return;
    final controller = TextEditingController(text: run.latestResponse ?? '');
    String? response;
    await GlazeBottomSheet.show<void>(
      context,
      title: 'Correct Collector response',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Edit the JSON response. It will be parsed and validated against the original immutable Collector input.',
            ),
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
              child: const Text('Validate and apply'),
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
        GlazeToast.show(context, 'Collector correction failed: $error');
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
    'collectorCompleted' => 'Collector recovery completed.',
    'persisted' || 'alreadyCompleted' =>
      'Collector recovered and Card Rewriter proposal is ready.',
    'exactCaptureUnavailable' =>
      'Exact prompt is unavailable or was truncated. Use response correction instead.',
    'staleInput' || 'collectorEvidenceStale' =>
      'Collector evidence changed; recovery was not applied.',
    'parserRejected' => detail ?? 'Corrected response is still invalid.',
    _ => detail ?? 'Collector recovery stopped: $kind',
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
              Text('Could not load Collector: $error'),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () =>
                    ref.invalidate(collectorViewProvider(widget.sessionId)),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
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
                    _SummaryValue(label: 'Runs', value: '${data.runs.length}'),
                    _SummaryValue(
                      label: 'Completed',
                      value:
                          '${data.runs.where((run) => run.row.status == 'completed').length}',
                    ),
                    _SummaryValue(
                      label: 'Observations',
                      value: '${data.observations.length}',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Collector runs',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            if (data.runs.isEmpty)
              const _CollectorEmpty(
                text: 'No Collector runs recorded for this session.',
              )
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
                    title: Text(run.label),
                    subtitle: Text(run.row.status),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Detail(label: 'Run ID', value: run.row.id),
                      _Detail(
                        label: 'Reconciliation',
                        value: run.row.reconciliationRunId,
                      ),
                      _Detail(label: 'Range hash', value: run.row.rangeHash),
                      _Detail(label: 'Input hash', value: run.row.inputHash),
                      _Detail(
                        label: 'Output hash',
                        value: run.row.modelOutputHash ?? 'Unavailable',
                      ),
                      if (run.row.failureCode != null)
                        _Detail(label: 'Failure', value: run.row.failureCode!),
                      if (run.row.failureDetail != null)
                        _Detail(
                          label: 'Failure detail',
                          value: run.row.failureDetail!,
                        ),
                      if (run.latestResponse != null)
                        _Detail(
                          label: 'Last response',
                          value: run.latestResponse!,
                        ),
                      if (run.latestParserVerdict case final verdict?) ...[
                        _Detail(
                          label: 'Parser verdict',
                          value:
                              '${verdict.kind}: ${verdict.parserCode ?? 'unknown'}',
                        ),
                        if (verdict.parserDetail != null)
                          _Detail(
                            label: 'Parser detail',
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
                                  _recoveringRunId == null && run.canRetryExact
                                  ? () => _retryExact(run)
                                  : null,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry exact prompt'),
                            ),
                            FilledButton.icon(
                              onPressed: _recoveringRunId == null
                                  ? () => _correct(run)
                                  : null,
                              icon: const Icon(Icons.edit_outlined),
                              label: const Text('Correct response'),
                            ),
                          ],
                        ),
                        if (!run.canRetryExact)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Exact retry is unavailable because the original prompt was not retained intact.',
                              style: TextStyle(
                                color: context.cs.onSurfaceVariant,
                                fontSize: 11,
                              ),
                            ),
                          ),
                      ] else if (run.callEvents.isEmpty)
                        Text(
                          'Request and response details are unavailable for this legacy run.',
                          style: TextStyle(
                            color: context.cs.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
            const SizedBox(height: 14),
            Text('Observations', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            if (data.observations.isEmpty)
              const _CollectorEmpty(
                text: 'No Collector observations recorded yet.',
              )
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
          '${observation.status} · confidence ${(observation.confidence * 100).round()}% · ${observation.repeatCount} confirmations',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Detail(label: 'Scope', value: observation.semanticScopeKey),
          _Detail(
            label: 'Target',
            value: observation.targetKind ?? 'Unavailable',
          ),
          if (observation.canonicalClaim != null)
            _Detail(label: 'Claim', value: observation.canonicalClaim!),
          _Detail(
            label: 'Evidence',
            value: observation.evidenceMessageIds.join(', '),
          ),
        ],
      ),
    );
  }
}

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
