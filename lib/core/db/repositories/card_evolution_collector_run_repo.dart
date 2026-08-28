import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';
import 'ledger_reconciliation_run_repo.dart';

final class CardEvolutionCollectorClaimOutcome {
  const CardEvolutionCollectorClaimOutcome(this.kind, [this.row]);

  final String kind;
  final CardEvolutionCollectorRunRow? row;

  bool get canRun => kind == 'claimed' || kind == 'existing';
}

const collectorReconciliationBatchSize = 3;

final class CardEvolutionCollectorBatch {
  CardEvolutionCollectorBatch(List<LedgerReconciliationSuccessfulRunRow> runs)
    : assert(runs.length == collectorReconciliationBatchSize),
      runs = List.unmodifiable(runs);

  final List<LedgerReconciliationSuccessfulRunRow> runs;

  LedgerReconciliationSuccessfulRunRow get first => runs.first;
  LedgerReconciliationSuccessfulRunRow get boundary => runs.last;

  String get rangeHash => sha256
      .convert(
        utf8.encode(
          runs.map((run) => '${run.id}\u001f${run.rangeHash}').join('\u001e'),
        ),
      )
      .toString();
}

/// Durable collector lease and completion journal. A valid empty observation
/// response is a completed run, so cadence remains stable across restarts.
class CardEvolutionCollectorRunRepo {
  CardEvolutionCollectorRunRepo(this.db);

  final AppDatabase db;

  /// Read-only audit history for Agent Ops, newest collector first.
  Future<List<CardEvolutionCollectorRunRow>> readSession(String sessionId) =>
      (db.select(db.cardEvolutionCollectorRuns)
            ..where((row) => row.sessionId.equals(sessionId))
            ..orderBy([
              (row) => OrderingTerm.desc(row.collectorOrdinal),
              (row) => OrderingTerm.desc(row.createdAt),
            ]))
          .get();

  Future<CardEvolutionCollectorRunRow?> getById(String id) => (db.select(
    db.cardEvolutionCollectorRuns,
  )..where((row) => row.id.equals(id))).getSingleOrNull();

  Future<CardEvolutionCollectorClaimOutcome> claim({
    required LedgerReconciliationSuccessfulRunRow reconciliationRun,
    required String characterId,
    required String inputHash,
    required String ownerId,
    required int now,
    required int leaseSeconds,
    String? rangeHash,
  }) => db.transaction(() async {
    final existing =
        await (db.select(db.cardEvolutionCollectorRuns)..where(
              (row) =>
                  row.sessionId.equals(reconciliationRun.sessionId) &
                  row.reconciliationRunId.equals(reconciliationRun.id),
            ))
            .getSingleOrNull();
    if (existing != null) {
      if (existing.status == 'completed') {
        return CardEvolutionCollectorClaimOutcome('completed', existing);
      }
      if (existing.status == 'failed') {
        return CardEvolutionCollectorClaimOutcome('failed', existing);
      }
      if (existing.status == 'claimed' &&
          existing.leaseExpiresAt > now &&
          existing.ownerId != ownerId) {
        return const CardEvolutionCollectorClaimOutcome('busy');
      }
      if (existing.inputHash != inputHash && existing.leaseExpiresAt > now) {
        return const CardEvolutionCollectorClaimOutcome('staleInput');
      }
      final changed =
          await (db.update(db.cardEvolutionCollectorRuns)..where(
                (row) =>
                    row.id.equals(existing.id) & row.status.equals('claimed'),
              ))
              .write(
                CardEvolutionCollectorRunsCompanion(
                  ownerId: Value(ownerId),
                  leaseExpiresAt: Value(now + leaseSeconds),
                  status: const Value('claimed'),
                  inputHash: Value(inputHash),
                  failureCode: const Value(null),
                  failureDetail: const Value(null),
                  failedAt: const Value(null),
                ),
              );
      if (changed != 1) {
        return const CardEvolutionCollectorClaimOutcome('busy');
      }
      final row = await (db.select(
        db.cardEvolutionCollectorRuns,
      )..where((row) => row.id.equals(existing.id))).getSingle();
      return CardEvolutionCollectorClaimOutcome('existing', row);
    }

    final nextOrdinalRow = await db
        .customSelect(
          'SELECT COALESCE(MAX(collector_ordinal), 0) + 1 AS ordinal '
          'FROM card_evolution_collector_runs WHERE session_id = ?',
          variables: [Variable.withString(reconciliationRun.sessionId)],
        )
        .getSingle();
    final collectorOrdinal = nextOrdinalRow.read<int>('ordinal');
    final id = 'evolution-collector-${generateId()}';
    try {
      await db
          .into(db.cardEvolutionCollectorRuns)
          .insert(
            CardEvolutionCollectorRunsCompanion.insert(
              id: id,
              sessionId: reconciliationRun.sessionId,
              characterId: characterId,
              collectorOrdinal: collectorOrdinal,
              reconciliationRunId: reconciliationRun.id,
              reconciliationRunOrdinal: reconciliationRun.ordinal,
              reconciliationChainHash: reconciliationRun.chainHash,
              rangeHash: rangeHash ?? reconciliationRun.rangeHash,
              inputHash: inputHash,
              ownerId: ownerId,
              status: 'claimed',
              leaseExpiresAt: now + leaseSeconds,
              createdAt: now,
            ),
          );
    } catch (_) {
      return const CardEvolutionCollectorClaimOutcome('busy');
    }
    final row = await (db.select(
      db.cardEvolutionCollectorRuns,
    )..where((item) => item.id.equals(id))).getSingle();
    return CardEvolutionCollectorClaimOutcome('claimed', row);
  });

  Future<CardEvolutionCollectorClaimOutcome> claimFailed({
    required String id,
    required String ownerId,
    required int now,
    required int leaseSeconds,
  }) => db.transaction(() async {
    final existing = await getById(id);
    if (existing == null) {
      return const CardEvolutionCollectorClaimOutcome('notFound');
    }
    if (existing.status != 'failed') {
      return CardEvolutionCollectorClaimOutcome('notFailed', existing);
    }
    final changed =
        await (db.update(db.cardEvolutionCollectorRuns)
              ..where((row) => row.id.equals(id) & row.status.equals('failed')))
            .write(
              CardEvolutionCollectorRunsCompanion(
                ownerId: Value(ownerId),
                status: const Value('claimed'),
                leaseExpiresAt: Value(now + leaseSeconds),
                failureCode: const Value(null),
                failureDetail: const Value(null),
                failedAt: const Value(null),
              ),
            );
    if (changed != 1) {
      return const CardEvolutionCollectorClaimOutcome('busy');
    }
    return CardEvolutionCollectorClaimOutcome('claimed', await getById(id));
  });

  Future<bool> complete({
    required String id,
    required String ownerId,
    required String modelOutputHash,
    required int now,
  }) async {
    final changed =
        await (db.update(db.cardEvolutionCollectorRuns)..where(
              (row) =>
                  row.id.equals(id) &
                  row.ownerId.equals(ownerId) &
                  row.status.equals('claimed') &
                  row.leaseExpiresAt.isBiggerThanValue(now),
            ))
            .write(
              CardEvolutionCollectorRunsCompanion(
                status: const Value('completed'),
                modelOutputHash: Value(modelOutputHash),
                completedAt: Value(now),
              ),
            );
    return changed == 1;
  }

  /// Commits observation effects and collector completion atomically. If a
  /// chat mutation removed the claimed collector while its model call was in
  /// flight, no effects are applied.
  Future<bool> completeWithEffects({
    required String id,
    required String ownerId,
    required String modelOutputHash,
    required int now,
    required Future<void> Function() applyEffects,
    Future<bool> Function()? validateEvidence,
    String? lastCallId,
  }) => db.transaction(() async {
    final claimed =
        await (db.select(db.cardEvolutionCollectorRuns)..where(
              (row) =>
                  row.id.equals(id) &
                  row.ownerId.equals(ownerId) &
                  row.status.equals('claimed') &
                  row.leaseExpiresAt.isBiggerThanValue(now),
            ))
            .getSingleOrNull();
    if (claimed == null) return false;
    if (validateEvidence != null && !await validateEvidence()) return false;
    await applyEffects();
    final changed =
        await (db.update(db.cardEvolutionCollectorRuns)..where(
              (row) =>
                  row.id.equals(id) &
                  row.ownerId.equals(ownerId) &
                  row.status.equals('claimed') &
                  row.leaseExpiresAt.isBiggerThanValue(now),
            ))
            .write(
              CardEvolutionCollectorRunsCompanion(
                status: const Value('completed'),
                modelOutputHash: Value(modelOutputHash),
                lastCallId: lastCallId == null
                    ? const Value.absent()
                    : Value(lastCallId),
                completedAt: Value(now),
              ),
            );
    if (changed != 1) {
      throw StateError('Collector claim changed in transaction');
    }
    return true;
  });

  Future<void> abandon({required String id, required String ownerId}) =>
      (db.delete(db.cardEvolutionCollectorRuns)..where(
            (row) =>
                row.id.equals(id) &
                row.ownerId.equals(ownerId) &
                row.status.equals('claimed'),
          ))
          .go();

  Future<bool> markFailed({
    required String id,
    required String ownerId,
    required int now,
    required String code,
    String? detail,
    String? callId,
  }) async {
    final changed =
        await (db.update(db.cardEvolutionCollectorRuns)..where(
              (row) =>
                  row.id.equals(id) &
                  row.ownerId.equals(ownerId) &
                  row.status.equals('claimed'),
            ))
            .write(
              CardEvolutionCollectorRunsCompanion(
                status: const Value('failed'),
                leaseExpiresAt: const Value(0),
                lastCallId: Value(callId),
                failureCode: Value(code),
                failureDetail: Value(detail),
                failedAt: Value(now),
              ),
            );
    return changed == 1;
  }

  Future<int> latestCompletedOrdinal(String sessionId) async {
    final row = await db
        .customSelect(
          'SELECT COALESCE(MAX(collector_ordinal), 0) AS ordinal '
          'FROM card_evolution_collector_runs '
          "WHERE session_id = ? AND status = 'completed'",
          variables: [Variable.withString(sessionId)],
        )
        .getSingle();
    return row.read<int>('ordinal');
  }

  Future<int> latestDeliveredWriterBoundary(String sessionId) async {
    final claims =
        await (db.select(db.cardEvolutionClaims)
              ..where((row) => row.sessionId.equals(sessionId))
              ..where((row) => row.status.equals('completed'))
              ..where((row) => row.predecessorRunOrdinal.isBiggerThanValue(0))
              ..orderBy([
                (row) => OrderingTerm.desc(row.predecessorRunOrdinal),
              ]))
            .get();
    for (final claim in claims) {
      final boundary =
          await (db.select(db.cardEvolutionCollectorRuns)
                ..where((row) => row.sessionId.equals(sessionId))
                ..where(
                  (row) =>
                      row.collectorOrdinal.equals(claim.predecessorRunOrdinal),
                )
                ..where((row) => row.status.equals('completed')))
              .getSingleOrNull();
      if (boundary != null &&
          boundary.reconciliationChainHash == claim.predecessorCursorHash) {
        return claim.predecessorRunOrdinal;
      }
    }
    return 0;
  }

  /// Missing non-overlapping batches from the valid logical reconciliation
  /// projection. One collector is anchored to each batch's final run.
  Future<List<CardEvolutionCollectorBatch>> pendingValidPairs(
    String sessionId, {
    LedgerReconciliationSuccessfulRunRow? currentRun,
  }) async {
    final runs = await _validOrLegacyRuns(sessionId, currentRun: currentRun);
    var collectors = await (db.select(
      db.cardEvolutionCollectorRuns,
    )..where((row) => row.sessionId.equals(sessionId))).get();
    final expectedBatches = <String, CardEvolutionCollectorBatch>{};
    for (
      var index = 0;
      index + collectorReconciliationBatchSize <= runs.length;
      index += collectorReconciliationBatchSize
    ) {
      final batch = CardEvolutionCollectorBatch(
        runs.sublist(index, index + collectorReconciliationBatchSize),
      );
      expectedBatches[batch.boundary.id] = batch;
    }
    final incompatibleJournal = collectors.any((collector) {
      final batch = expectedBatches[collector.reconciliationRunId];
      return batch == null || collector.rangeHash != batch.rangeHash;
    });
    if (incompatibleJournal) {
      // A journal from another cadence cannot prove the current batch ranges.
      // Rebuild it and its aggregate effects conservatively.
      await db.transaction(() async {
        await (db.delete(
          db.cardEvolutionCollectorRuns,
        )..where((row) => row.sessionId.equals(sessionId))).go();
        await (db.delete(
          db.cardEvolutionObservations,
        )..where((row) => row.sessionId.equals(sessionId))).go();
      });
      collectors = const [];
    }
    final completedByBoundary = {
      for (final row in collectors)
        if (row.status == 'completed') row.reconciliationRunId: row,
    };
    final batches = <CardEvolutionCollectorBatch>[];
    for (
      var index = 0;
      index + collectorReconciliationBatchSize <= runs.length;
      index += collectorReconciliationBatchSize
    ) {
      final batch = CardEvolutionCollectorBatch(
        runs.sublist(index, index + collectorReconciliationBatchSize),
      );
      final boundary = batch.boundary;
      final completed = completedByBoundary[boundary.id];
      if (completed == null || completed.rangeHash != batch.rangeHash) {
        batches.add(batch);
      }
    }
    return batches;
  }

  /// Valid reconciliation batches that can be started from the Collector UI.
  /// Failed and live in-flight rows use their dedicated recovery paths.
  Future<List<CardEvolutionCollectorBatch>> unclaimedValidPairs(
    String sessionId,
  ) async {
    final runs = await _validOrLegacyRuns(sessionId);
    final collectors = await (db.select(
      db.cardEvolutionCollectorRuns,
    )..where((row) => row.sessionId.equals(sessionId))).get();
    final now = currentTimestampSeconds();
    final batches = <CardEvolutionCollectorBatch>[];
    for (
      var index = 0;
      index + collectorReconciliationBatchSize <= runs.length;
      index += collectorReconciliationBatchSize
    ) {
      final batch = CardEvolutionCollectorBatch(
        runs.sublist(index, index + collectorReconciliationBatchSize),
      );
      final hasCompatibleClaim = collectors.any(
        (collector) =>
            collector.reconciliationRunId == batch.boundary.id &&
            collector.rangeHash == batch.rangeHash &&
            (collector.status != 'claimed' || collector.leaseExpiresAt > now),
      );
      if (!hasCompatibleClaim) batches.add(batch);
    }
    return batches;
  }

  /// Resolves collector boundaries back to their exact logical batches.
  Future<List<LedgerReconciliationSuccessfulRunRow>> runsForCollectors(
    String sessionId,
    List<CardEvolutionCollectorRunRow> collectors,
  ) async {
    if (collectors.isEmpty) return const [];
    final runs = await _validOrLegacyRuns(sessionId);
    final byBoundary = <String, CardEvolutionCollectorBatch>{};
    for (
      var index = 0;
      index + collectorReconciliationBatchSize <= runs.length;
      index += collectorReconciliationBatchSize
    ) {
      final batch = CardEvolutionCollectorBatch(
        runs.sublist(index, index + collectorReconciliationBatchSize),
      );
      byBoundary[batch.boundary.id] = batch;
    }
    final result = <LedgerReconciliationSuccessfulRunRow>[];
    for (final collector in collectors) {
      final batch = byBoundary[collector.reconciliationRunId];
      if (batch == null ||
          batch.boundary.chainHash != collector.reconciliationChainHash ||
          batch.rangeHash != collector.rangeHash) {
        return const [];
      }
      result.addAll(batch.runs);
    }
    return result;
  }

  Future<List<LedgerReconciliationSuccessfulRunRow>> _validOrLegacyRuns(
    String sessionId, {
    LedgerReconciliationSuccessfulRunRow? currentRun,
  }) async {
    final runRepo = LedgerReconciliationRunRepo(db);
    final logical = await runRepo.readSession(sessionId);
    // Batching needs an authoritative predecessor. Never infer one from raw
    // rows when the canonical logical chain cannot be projected.
    return logical;
  }

  /// Exact [count] completed collectors ending at [boundary]. Gaps or claimed
  /// rows fail closed, so a writer never substitutes newer reconciliation data.
  Future<List<CardEvolutionCollectorRunRow>> completedBoundary(
    String sessionId,
    int boundary, {
    required int count,
  }) async {
    if (count <= 0 || boundary < count) return const [];
    final rows =
        await (db.select(db.cardEvolutionCollectorRuns)
              ..where((row) => row.sessionId.equals(sessionId))
              ..where(
                (row) => row.collectorOrdinal.isBetweenValues(
                  boundary - count + 1,
                  boundary,
                ),
              )
              ..where((row) => row.status.equals('completed'))
              ..orderBy([(row) => OrderingTerm.asc(row.collectorOrdinal)]))
            .get();
    if (rows.length != count ||
        rows.indexed.any(
          (entry) =>
              entry.$2.collectorOrdinal != boundary - count + 1 + entry.$1,
        )) {
      return const [];
    }
    return rows;
  }
}
