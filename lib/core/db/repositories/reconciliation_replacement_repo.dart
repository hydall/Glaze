import 'dart:convert';

import 'package:drift/drift.dart';

import '../../utils/time_helpers.dart';
import '../app_db.dart';

final class ReconciliationReplacementRepo {
  const ReconciliationReplacementRepo(this.db);

  final AppDatabase db;

  Future<bool> hasAppliedDependency({
    required String sessionId,
    required String reconciliationRunId,
  }) async {
    final proposals = await (db.select(
      db.cardEvolutionProposalRuns,
    )..where((row) => row.sessionId.equals(sessionId))).get();
    for (final proposal in proposals) {
      final job =
          await (db.select(db.rewriteJobs)
                ..where((row) => row.id.equals(proposal.rewriteJobId)))
              .getSingleOrNull();
      if (job?.status != 'applied') continue;
      final dependency = _classify(
        proposal.selectedInputJson,
        reconciliationRunId,
      );
      if (dependency != _Dependency.unlinked) return true;
    }
    return false;
  }

  Future<void> resetDownstreamInTransaction({
    required String sessionId,
    required String reconciliationRunId,
    int? now,
  }) async {
    final proposals = await (db.select(
      db.cardEvolutionProposalRuns,
    )..where((row) => row.sessionId.equals(sessionId))).get();
    for (final proposal in proposals) {
      if (_classify(proposal.selectedInputJson, reconciliationRunId) ==
          _Dependency.unlinked) {
        continue;
      }
      final job =
          await (db.select(db.rewriteJobs)..where(
                (row) =>
                    row.id.equals(proposal.rewriteJobId) &
                    row.status.equals('pending'),
              ))
              .getSingleOrNull();
      if (job == null) continue;
      await (db.update(db.rewriteJobs)..where(
            (row) =>
                row.id.equals(job.id) &
                row.status.equals('pending') &
                row.version.equals(job.version),
          ))
          .write(
            RewriteJobsCompanion(
              status: const Value('cancelled'),
              statusReason: const Value('reconciliationReplaced'),
              version: Value(job.version + 1),
              updatedAt: Value(now ?? currentTimestampSeconds()),
            ),
          );
    }

    await (db.delete(
      db.cardEvolutionCollectorRuns,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (db.delete(
      db.cardEvolutionObservations,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (db.delete(
      db.ledgerReconciliationCursors,
    )..where((row) => row.sessionId.equals(sessionId))).go();

    final recoverableClaims =
        await (db.select(db.cardEvolutionClaims)..where(
              (row) =>
                  row.sessionId.equals(sessionId) &
                  (row.status.isIn(const ['claimed', 'failed']) |
                      (row.status.equals('completed') &
                          row.rewriteJobId.isNull())),
            ))
            .get();
    final claimIds = recoverableClaims.map((row) => row.id).toList();
    if (claimIds.isEmpty) return;
    await (db.delete(
      db.cardEvolutionWriterCalls,
    )..where((row) => row.claimId.isIn(claimIds))).go();
    await (db.delete(
      db.cardEvolutionClaims,
    )..where((row) => row.id.isIn(claimIds))).go();
  }
}

enum _Dependency { linked, unlinked, unknown }

_Dependency _classify(String source, String runId) {
  try {
    final root = jsonDecode(source);
    if (root is! Map) return _Dependency.unknown;
    final limits = root['limits'];
    if (limits is! Map) return _Dependency.unknown;
    final ids = limits['reconciliationRunIds'];
    if (ids is! List || ids.any((item) => item is! String)) {
      return _Dependency.unknown;
    }
    return ids.contains(runId) ? _Dependency.linked : _Dependency.unlinked;
  } on FormatException {
    return _Dependency.unknown;
  }
}
