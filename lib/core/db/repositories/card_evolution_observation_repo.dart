import 'dart:convert';

import 'package:drift/drift.dart';

import '../../models/card_evolution_observation.dart';
import '../app_db.dart';

/// Repository for the Card Rewriter observation journal. Observations are
/// session-scoped candidate durable changes recorded by the observation pass.
/// One active observation per `(sessionId, semanticScopeKey)` is enforced by a
/// unique key; confirmations bump `repeatCount`/`lastConfirmedRun`, promotion
/// flips `status` to `promoted`, and a successful apply marks it `consumed`.
class CardEvolutionObservationRepo {
  CardEvolutionObservationRepo(this.db);

  final AppDatabase db;

  Future<CardEvolutionObservation?> findByScopeKey(
    String sessionId,
    String semanticScopeKey,
  ) => db.transaction(() async {
    final row =
        await (db.select(db.cardEvolutionObservations)
              ..where((r) => r.sessionId.equals(sessionId))
              ..where((r) => r.semanticScopeKey.equals(semanticScopeKey)))
            .getSingleOrNull();
    return row == null ? null : _toModel(row);
  });

  Future<CardEvolutionObservation?> findById(String id) =>
      db.transaction(() async {
        final row = await (db.select(
          db.cardEvolutionObservations,
        )..where((r) => r.id.equals(id))).getSingleOrNull();
        return row == null ? null : _toModel(row);
      });

  Future<void> insertObservation(CardEvolutionObservation observation) => db
      .into(db.cardEvolutionObservations)
      .insert(
        CardEvolutionObservationsCompanion.insert(
          id: observation.id,
          sessionId: observation.sessionId,
          characterId: observation.characterId,
          runOrdinal: observation.runOrdinal,
          semanticScopeKey: observation.semanticScopeKey,
          observedChange: observation.observedChange,
          canonicalClaim: Value(observation.canonicalClaim),
          evidenceMessageIds: jsonEncode(observation.evidenceMessageIds),
          evidenceClustersJson: Value(jsonEncode(observation.evidenceClusters)),
          retrievalKeysJson: Value(jsonEncode(observation.retrievalKeys)),
          targetKind: Value(observation.targetKind),
          cardFieldPath: Value(observation.cardFieldPath),
          lorebookEntryId: Value(observation.lorebookEntryId),
          confidence: observation.confidence,
          status: observation.status,
          firstSeenRun: observation.firstSeenRun,
          repeatCount: Value(observation.repeatCount),
          lastConfirmedRun: Value(observation.lastConfirmedRun),
          createdAt: observation.createdAt,
          updatedAt: observation.updatedAt,
        ),
      );

  /// Starts a new evidence cycle for a scope that was previously terminal.
  /// Active/promoted rows remain authoritative and are never overwritten.
  Future<ObservationActivationOutcome> insertOrReactivate(
    CardEvolutionObservation observation,
  ) => db.transaction(() async {
    final existing =
        await (db.select(db.cardEvolutionObservations)..where(
              (row) =>
                  row.sessionId.equals(observation.sessionId) &
                  row.semanticScopeKey.equals(observation.semanticScopeKey),
            ))
            .getSingleOrNull();
    if (existing == null) {
      await insertObservation(observation);
      return ObservationActivationOutcome.inserted;
    }
    if (existing.status == 'active' || existing.status == 'promoted') {
      return ObservationActivationOutcome.alreadyCurrent;
    }
    final changed =
        await (db.update(db.cardEvolutionObservations)..where(
              (row) =>
                  row.id.equals(existing.id) &
                  row.status.isIn(const ['expired', 'consumed']),
            ))
            .write(
              CardEvolutionObservationsCompanion(
                characterId: Value(observation.characterId),
                runOrdinal: Value(observation.runOrdinal),
                observedChange: Value(observation.observedChange),
                canonicalClaim: Value(observation.canonicalClaim),
                evidenceMessageIds: Value(
                  jsonEncode(observation.evidenceMessageIds),
                ),
                evidenceClustersJson: Value(
                  jsonEncode(observation.evidenceClusters),
                ),
                retrievalKeysJson: Value(jsonEncode(observation.retrievalKeys)),
                targetKind: Value(observation.targetKind),
                cardFieldPath: Value(observation.cardFieldPath),
                lorebookEntryId: Value(observation.lorebookEntryId),
                confidence: Value(observation.confidence),
                status: const Value('active'),
                firstSeenRun: Value(observation.firstSeenRun),
                repeatCount: Value(observation.repeatCount),
                lastConfirmedRun: Value(observation.lastConfirmedRun),
                updatedAt: Value(observation.updatedAt),
              ),
            );
    return changed == 1
        ? ObservationActivationOutcome.reactivated
        : ObservationActivationOutcome.conflict;
  });

  Future<ObservationConfirmationOutcome> confirmObservation({
    required String id,
    required int runOrdinal,
    required double confidence,
    required int now,
    required List<String> evidenceMessageIds,
    List<String>? retrievalKeys,
    String? targetKind,
  }) => db.transaction(() async {
    final row = await (db.select(
      db.cardEvolutionObservations,
    )..where((r) => r.id.equals(id))).getSingleOrNull();
    if (row == null) return ObservationConfirmationOutcome.duplicate;
    final incoming = _canonicalEvidence(evidenceMessageIds);
    if (incoming.isEmpty) return ObservationConfirmationOutcome.noEvidence;
    if (row.runOrdinal == runOrdinal || row.lastConfirmedRun == runOrdinal) {
      return ObservationConfirmationOutcome.sameRun;
    }
    final clusters = _decodeClusters(row.evidenceClustersJson);
    final incomingSet = incoming.toSet();
    if (clusters.any(
      (cluster) =>
          cluster.length == incomingSet.length &&
          incomingSet.containsAll(cluster),
    )) {
      return ObservationConfirmationOutcome.duplicate;
    }
    final existingIds = {for (final cluster in clusters) ...cluster};
    if (incoming.any(existingIds.contains)) {
      return ObservationConfirmationOutcome.overlap;
    }
    clusters.add(incoming);
    final union = _canonicalEvidence([
      for (final cluster in clusters) ...cluster,
    ]);
    await (db.update(
      db.cardEvolutionObservations,
    )..where((r) => r.id.equals(id))).write(
      CardEvolutionObservationsCompanion(
        repeatCount: Value(row.repeatCount + 1),
        lastConfirmedRun: Value(runOrdinal),
        confidence: Value(confidence),
        evidenceClustersJson: Value(jsonEncode(clusters)),
        evidenceMessageIds: Value(jsonEncode(union)),
        retrievalKeysJson: retrievalKeys == null
            ? const Value.absent()
            : Value(jsonEncode(_canonicalEvidence(retrievalKeys))),
        targetKind: targetKind == null
            ? const Value.absent()
            : Value(targetKind),
        updatedAt: Value(now),
      ),
    );
    return ObservationConfirmationOutcome.confirmed;
  });

  Future<void> promoteObservation(String id, {required int now}) =>
      (db.update(db.cardEvolutionObservations)
            ..where((r) => r.id.equals(id))
            ..where((r) => r.status.equals('active')))
          .write(
            CardEvolutionObservationsCompanion(
              status: const Value('promoted'),
              updatedAt: Value(now),
            ),
          );

  Future<void> contradictObservation(String id, {required int now}) =>
      (db.update(db.cardEvolutionObservations)
            ..where((r) => r.id.equals(id))
            ..where((r) => r.status.equals('active')))
          .write(
            CardEvolutionObservationsCompanion(
              status: const Value('expired'),
              updatedAt: Value(now),
            ),
          );

  Future<void> consumeObservation(String id, {required int now}) =>
      (db.update(db.cardEvolutionObservations)
            ..where((r) => r.id.equals(id))
            ..where((r) => r.status.equals('promoted')))
          .write(
            CardEvolutionObservationsCompanion(
              status: const Value('consumed'),
              updatedAt: Value(now),
            ),
          );

  /// Expires active candidates that went [maxUnconfirmedRuns] Collector passes
  /// without independent confirmation. Promoted observations are retained until
  /// an approved operation consumes them or explicit evidence contradicts them.
  Future<int> expireUnconfirmed({
    required String sessionId,
    required int currentRunOrdinal,
    required int maxUnconfirmedRuns,
    required int now,
  }) {
    if (maxUnconfirmedRuns <= 0) return Future<int>.value(0);
    final lastEligibleRun = currentRunOrdinal - maxUnconfirmedRuns;
    return (db.update(db.cardEvolutionObservations)..where(
          (row) =>
              row.sessionId.equals(sessionId) &
              row.status.equals('active') &
              row.runOrdinal.isSmallerOrEqualValue(lastEligibleRun) &
              (row.lastConfirmedRun.isNull() |
                  row.lastConfirmedRun.isSmallerOrEqualValue(lastEligibleRun)),
        ))
        .write(
          CardEvolutionObservationsCompanion(
            status: const Value('expired'),
            updatedAt: Value(now),
          ),
        );
  }

  Future<List<CardEvolutionObservation>> getActiveObservations(
    String sessionId,
  ) => db.transaction(() async {
    final rows =
        await (db.select(db.cardEvolutionObservations)
              ..where((r) => r.sessionId.equals(sessionId))
              ..where((r) => r.status.equals('active'))
              ..orderBy([(r) => OrderingTerm.asc(r.createdAt)]))
            .get();
    return [for (final row in rows) _toModel(row)];
  });

  Future<List<CardEvolutionObservation>> getPromotedObservations(
    String sessionId,
  ) => db.transaction(() async {
    final rows =
        await (db.select(db.cardEvolutionObservations)
              ..where((r) => r.sessionId.equals(sessionId))
              ..where((r) => r.status.equals('promoted'))
              ..orderBy([(r) => OrderingTerm.asc(r.createdAt)]))
            .get();
    return [for (final row in rows) _toModel(row)];
  });

  /// All lifecycle states for read-only diagnostics, newest update first.
  Future<List<CardEvolutionObservation>> getBySessionId(String sessionId) =>
      db.transaction(() async {
        final rows =
            await (db.select(db.cardEvolutionObservations)
                  ..where((row) => row.sessionId.equals(sessionId))
                  ..orderBy([
                    (row) => OrderingTerm.desc(row.updatedAt),
                    (row) => OrderingTerm.desc(row.id),
                  ]))
                .get();
        return [for (final row in rows) _toModel(row)];
      });

  Future<List<CardEvolutionObservation>> getPromotableObservations(
    String sessionId, {
    required int minRepeatCount,
    required double minConfidence,
  }) => db.transaction(() async {
    final rows =
        await (db.select(db.cardEvolutionObservations)
              ..where((r) => r.sessionId.equals(sessionId))
              ..where((r) => r.status.equals('active'))
              ..where((r) => r.repeatCount.isBiggerOrEqualValue(minRepeatCount))
              ..where((r) => r.confidence.isBiggerOrEqualValue(minConfidence)))
            .get();
    return [for (final row in rows) _toModel(row)];
  });

  static CardEvolutionObservation _toModel(CardEvolutionObservationRow row) {
    final evidenceClusters = _decodeClusters(row.evidenceClustersJson);
    return CardEvolutionObservation(
      id: row.id,
      sessionId: row.sessionId,
      characterId: row.characterId,
      runOrdinal: row.runOrdinal,
      semanticScopeKey: row.semanticScopeKey,
      observedChange: row.observedChange,
      canonicalClaim: row.canonicalClaim,
      evidenceClusters: evidenceClusters,
      retrievalKeys: _decodeStringList(row.retrievalKeysJson),
      targetKind: row.targetKind,
      cardFieldPath: row.cardFieldPath,
      lorebookEntryId: row.lorebookEntryId,
      confidence: row.confidence,
      status: row.status,
      firstSeenRun: row.firstSeenRun,
      repeatCount: row.repeatCount,
      lastConfirmedRun: row.lastConfirmedRun,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  static List<String> _canonicalEvidence(Iterable<Object?> values) {
    final result = <String>[];
    for (final value in values) {
      if (value is String && value.isNotEmpty && !result.contains(value)) {
        result.add(value);
      }
    }
    return result;
  }

  static List<List<String>> _decodeClusters(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return [];
      return [
        for (final cluster in decoded)
          if (cluster is List && _canonicalEvidence(cluster).isNotEmpty)
            _canonicalEvidence(cluster),
      ];
    } catch (_) {
      return [];
    }
  }

  static List<String> _decodeStringList(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      return decoded is List ? _canonicalEvidence(decoded) : const [];
    } catch (_) {
      return const [];
    }
  }
}

enum ObservationConfirmationOutcome {
  confirmed,
  duplicate,
  noEvidence,
  overlap,
  sameRun,
}

enum ObservationActivationOutcome {
  inserted,
  reactivated,
  alreadyCurrent,
  conflict,
}
