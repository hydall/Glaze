import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_db.dart';
import '../../../core/db/repositories/card_evolution_collector_run_repo.dart';
import '../../../core/db/repositories/card_evolution_observation_repo.dart';
import '../../../core/db/repositories/ledger_reconciliation_run_repo.dart';
import '../../../core/db/repositories/llm_request_capture_repo.dart';
import '../../../core/models/card_evolution_observation.dart';
import '../../../core/state/db_provider.dart';

final class CollectorRunView {
  const CollectorRunView({
    required this.row,
    required this.firstReconciliationOrdinal,
    required this.boundaryReconciliationOrdinal,
    required this.exactCapture,
    required this.callEvents,
  });

  final CardEvolutionCollectorRunRow row;
  final int? firstReconciliationOrdinal;
  final int boundaryReconciliationOrdinal;
  final ExactLlmPromptCapture? exactCapture;
  final List<LlmCallEventRow> callEvents;

  bool get canRetryExact => row.status == 'failed' && exactCapture != null;

  String? get latestResponse {
    for (final event in callEvents.reversed) {
      if (event.responseText != null) return event.responseText;
    }
    return null;
  }

  LlmCallEventRow? get latestParserVerdict {
    for (final event in callEvents.reversed) {
      if (event.kind.startsWith('parser_')) return event;
    }
    return null;
  }
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
    required LlmRequestCaptureRepo captureRepo,
  }) : this._(collectorRepo, observationRepo, reconciliationRepo, captureRepo);

  const CollectorViewService._(
    this._collectorRepo,
    this._observationRepo,
    this._reconciliationRepo,
    this._captureRepo,
  );

  final CardEvolutionCollectorRunRepo _collectorRepo;
  final CardEvolutionObservationRepo _observationRepo;
  final LedgerReconciliationRunRepo _reconciliationRepo;
  final LlmRequestCaptureRepo _captureRepo;

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
    final diagnostics = await Future.wait([
      for (final row in rows) _loadDiagnostics(row),
    ]);
    return CollectorViewSnapshot(
      observations: observations,
      runs: [
        for (final entry in rows.indexed)
          CollectorRunView(
            row: entry.$2,
            firstReconciliationOrdinal: switch (positions[entry
                .$2
                .reconciliationRunId]) {
              final index? when index > 0 => reconciliations[index - 1].ordinal,
              _ => null,
            },
            boundaryReconciliationOrdinal: entry.$2.reconciliationRunOrdinal,
            exactCapture: diagnostics[entry.$1].$1,
            callEvents: diagnostics[entry.$1].$2,
          ),
      ],
    );
  }

  Future<(ExactLlmPromptCapture?, List<LlmCallEventRow>)> _loadDiagnostics(
    CardEvolutionCollectorRunRow row,
  ) async {
    final callId = row.lastCallId;
    if (callId == null) return (null, const <LlmCallEventRow>[]);
    final captureFuture = _captureRepo.exactPromptForCall(
      callId: callId,
      sessionId: row.sessionId,
      pipelineRunId: row.id,
      stage: 'card.collector',
    );
    final eventsFuture = _captureRepo.callEventsForArtifact(
      row.sessionId,
      row.id,
    );
    return (await captureFuture, await eventsFuture);
  }
}

final collectorViewServiceProvider = Provider<CollectorViewService>((ref) {
  return CollectorViewService(
    collectorRepo: ref.watch(cardEvolutionCollectorRunRepoProvider),
    observationRepo: ref.watch(cardEvolutionObservationRepoProvider),
    reconciliationRepo: ref.watch(ledgerReconciliationRunRepoProvider),
    captureRepo: ref.watch(llmRequestCaptureRepoProvider),
  );
});

final collectorViewProvider =
    FutureProvider.family<CollectorViewSnapshot, String>((ref, sessionId) {
      return ref.watch(collectorViewServiceProvider).load(sessionId);
    });
