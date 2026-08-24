import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_db.dart';
import '../../../core/db/repositories/card_evolution_collector_run_repo.dart';
import '../../../core/db/repositories/card_evolution_observation_repo.dart';
import '../../../core/db/repositories/ledger_reconciliation_run_repo.dart';
import '../../../core/models/card_evolution_observation.dart';
import '../../../core/state/db_provider.dart';

final class CollectorRunView {
  const CollectorRunView({
    required this.row,
    required this.firstReconciliationOrdinal,
    required this.boundaryReconciliationOrdinal,
  });

  final CardEvolutionCollectorRunRow row;
  final int? firstReconciliationOrdinal;
  final int boundaryReconciliationOrdinal;

  String get label => firstReconciliationOrdinal == null
      ? 'Collector #${row.collectorOrdinal}'
      : 'Collector #${row.collectorOrdinal} '
            '(commits $firstReconciliationOrdinal-$boundaryReconciliationOrdinal)';
}

final class CollectorViewSnapshot {
  const CollectorViewSnapshot({required this.runs, required this.observations});

  final List<CollectorRunView> runs;
  final List<CardEvolutionObservation> observations;
}

class CollectorViewService {
  const CollectorViewService({
    required CardEvolutionCollectorRunRepo collectorRepo,
    required CardEvolutionObservationRepo observationRepo,
    required LedgerReconciliationRunRepo reconciliationRepo,
  }) : this._(collectorRepo, observationRepo, reconciliationRepo);

  const CollectorViewService._(
    this._collectorRepo,
    this._observationRepo,
    this._reconciliationRepo,
  );

  final CardEvolutionCollectorRunRepo _collectorRepo;
  final CardEvolutionObservationRepo _observationRepo;
  final LedgerReconciliationRunRepo _reconciliationRepo;

  Future<CollectorViewSnapshot> load(String sessionId) async {
    final values = await Future.wait<Object?>([
      _collectorRepo.readSession(sessionId),
      _observationRepo.getBySessionId(sessionId),
      _reconciliationRepo.readSession(sessionId),
    ]);
    final rows = values[0] as List<CardEvolutionCollectorRunRow>;
    final observations = values[1] as List<CardEvolutionObservation>;
    final reconciliations =
        values[2] as List<LedgerReconciliationSuccessfulRunRow>;
    final positions = {
      for (final entry in reconciliations.indexed) entry.$2.id: entry.$1,
    };
    return CollectorViewSnapshot(
      observations: observations,
      runs: [
        for (final row in rows)
          CollectorRunView(
            row: row,
            firstReconciliationOrdinal: switch (positions[row
                .reconciliationRunId]) {
              final index? when index > 0 => reconciliations[index - 1].ordinal,
              _ => null,
            },
            boundaryReconciliationOrdinal: row.reconciliationRunOrdinal,
          ),
      ],
    );
  }
}

final collectorViewServiceProvider = Provider<CollectorViewService>((ref) {
  return CollectorViewService(
    collectorRepo: ref.watch(cardEvolutionCollectorRunRepoProvider),
    observationRepo: ref.watch(cardEvolutionObservationRepoProvider),
    reconciliationRepo: ref.watch(ledgerReconciliationRunRepoProvider),
  );
});

final collectorViewProvider =
    FutureProvider.family<CollectorViewSnapshot, String>((ref, sessionId) {
      return ref.watch(collectorViewServiceProvider).load(sessionId);
    });
