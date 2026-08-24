import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/card_evolution_observation.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../services/collector_view_service.dart';

class AgenticCollectorTab extends ConsumerWidget {
  const AgenticCollectorTab({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(collectorViewProvider(sessionId));
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
                    ref.invalidate(collectorViewProvider(sessionId)),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
      data: (data) => RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(collectorViewProvider(sessionId));
          await ref.read(collectorViewProvider(sessionId).future);
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
                      run.row.status == 'completed'
                          ? Icons.check_circle_outline
                          : Icons.hourglass_top,
                      color: run.row.status == 'completed'
                          ? context.cs.primary
                          : Colors.orange,
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
                      const SizedBox(height: 6),
                      Text(
                        'Raw request, response, and parser verdict are unavailable for this legacy run.',
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
