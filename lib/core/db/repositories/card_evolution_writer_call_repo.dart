import 'package:drift/drift.dart';

import '../../utils/cast_helpers.dart';
import '../../utils/id_generator.dart';
import '../app_db.dart';

final class CardEvolutionWriterCallOutcome {
  const CardEvolutionWriterCallOutcome(this.kind, [this.row]);

  final String kind;
  final CardEvolutionWriterCallRow? row;
  bool get succeeded => kind == 'prepared' || kind == 'completed';
}

/// Owns the durable, ordered call checkpoints for one Card Evolution claim.
class CardEvolutionWriterCallRepo {
  const CardEvolutionWriterCallRepo(this.db);

  final AppDatabase db;

  Future<List<CardEvolutionClaimRow>> readFailedClaims(String sessionId) =>
      (db.select(db.cardEvolutionClaims)
            ..where(
              (row) =>
                  row.sessionId.equals(sessionId) & row.status.equals('failed'),
            )
            ..orderBy([
              (row) => OrderingTerm.desc(row.failedAt),
              (row) => OrderingTerm.desc(row.createdAt),
            ]))
          .get();

  Future<List<CardEvolutionWriterCallRow>> readChain(String claimId) =>
      (db.select(db.cardEvolutionWriterCalls)
            ..where((row) => row.claimId.equals(claimId))
            ..orderBy([(row) => OrderingTerm.asc(row.ordinal)]))
          .get();

  Future<List<CardEvolutionWriterCallRow>> readRecoverableForSession(
    String sessionId,
  ) =>
      (db.select(db.cardEvolutionWriterCalls)
            ..where(
              (row) =>
                  row.sessionId.equals(sessionId) &
                  row.status.isIn(const ['prepared', 'failed']),
            )
            ..orderBy([
              (row) => OrderingTerm.desc(row.updatedAt),
              (row) => OrderingTerm.desc(row.ordinal),
            ]))
          .get();

  Future<CardEvolutionWriterCallRow?> getById(String id) => (db.select(
    db.cardEvolutionWriterCalls,
  )..where((row) => row.id.equals(id))).getSingleOrNull();

  Future<CardEvolutionWriterCallOutcome> prepareNextCall({
    required String claimId,
    required String ownerId,
    required int now,
    required int ordinal,
    required String stage,
    required int stageOrdinal,
    required String prompt,
    String? parentCallId,
  }) => db.transaction(() async {
    final claim = await _liveClaim(claimId, ownerId, now);
    if (claim == null) {
      return const CardEvolutionWriterCallOutcome('leaseLost');
    }
    final existing =
        await (db.select(db.cardEvolutionWriterCalls)..where(
              (row) =>
                  row.claimId.equals(claimId) & row.ordinal.equals(ordinal),
            ))
            .getSingleOrNull();
    if (existing != null) {
      return CardEvolutionWriterCallOutcome(existing.status, existing);
    }
    if (!await _hasCompletedPrefix(claimId, ordinal)) {
      return const CardEvolutionWriterCallOutcome('outOfOrder');
    }
    final id = 'evolution-call-${generateId()}';
    await db
        .into(db.cardEvolutionWriterCalls)
        .insert(
          CardEvolutionWriterCallsCompanion.insert(
            id: id,
            claimId: claimId,
            sessionId: claim.sessionId,
            ordinal: ordinal,
            stage: stage,
            stageOrdinal: stageOrdinal,
            status: 'prepared',
            prompt: prompt,
            promptHash: computeHash(prompt),
            parentCallId: Value(parentCallId),
            createdAt: now,
            updatedAt: now,
          ),
        );
    return CardEvolutionWriterCallOutcome('prepared', await getById(id));
  });

  Future<bool> retryFailed({
    required String id,
    required String claimId,
    required String ownerId,
    required int now,
  }) => db.transaction(() async {
    if (await _liveClaim(claimId, ownerId, now) == null) return false;
    final changed =
        await (db.update(db.cardEvolutionWriterCalls)..where(
              (row) =>
                  row.id.equals(id) &
                  row.claimId.equals(claimId) &
                  row.status.equals('failed'),
            ))
            .write(
              CardEvolutionWriterCallsCompanion(
                status: const Value('prepared'),
                source: const Value('exact_retry'),
                failureCode: const Value(null),
                failureDetail: const Value(null),
                failedAt: const Value(null),
                updatedAt: Value(now),
              ),
            );
    return changed == 1;
  });

  Future<bool> completeCall({
    required String id,
    required String claimId,
    required String ownerId,
    required int now,
    required String responseText,
    required String resultJson,
    required String source,
    required String parserCode,
    String? parserDetail,
    String? lastCallId,
  }) => db.transaction(() async {
    if (await _liveClaim(claimId, ownerId, now) == null) return false;
    final row = await getById(id);
    if (row == null || row.claimId != claimId || row.status != 'prepared') {
      return false;
    }
    if (!await _hasCompletedPrefix(claimId, row.ordinal)) return false;
    final changed =
        await (db.update(db.cardEvolutionWriterCalls)..where(
              (item) => item.id.equals(id) & item.status.equals('prepared'),
            ))
            .write(
              CardEvolutionWriterCallsCompanion(
                status: const Value('completed'),
                responseText: Value(responseText),
                responseHash: Value(computeHash(responseText)),
                resultJson: Value(resultJson),
                source: Value(source),
                lastCallId: Value(lastCallId),
                parserCode: Value(parserCode),
                parserDetail: Value(parserDetail),
                updatedAt: Value(now),
                completedAt: Value(now),
              ),
            );
    return changed == 1;
  });

  Future<bool> failCall({
    required String id,
    required String claimId,
    required String ownerId,
    required int now,
    required String code,
    String? detail,
    String? lastCallId,
    String? responseText,
    String? parserCode,
    String? parserDetail,
  }) => db.transaction(() async {
    if (await _liveClaim(claimId, ownerId, now) == null) return false;
    final changed =
        await (db.update(db.cardEvolutionWriterCalls)..where(
              (row) =>
                  row.id.equals(id) &
                  row.claimId.equals(claimId) &
                  row.status.equals('prepared'),
            ))
            .write(
              CardEvolutionWriterCallsCompanion(
                status: const Value('failed'),
                responseText: Value(responseText),
                responseHash: Value(
                  responseText == null ? null : computeHash(responseText),
                ),
                lastCallId: Value(lastCallId),
                parserCode: Value(parserCode),
                parserDetail: Value(parserDetail),
                failureCode: Value(code),
                failureDetail: Value(detail),
                updatedAt: Value(now),
                failedAt: Value(now),
              ),
            );
    return changed == 1;
  });

  Future<CardEvolutionClaimRow?> _liveClaim(
    String claimId,
    String ownerId,
    int now,
  ) =>
      (db.select(db.cardEvolutionClaims)..where(
            (row) =>
                row.id.equals(claimId) &
                row.ownerId.equals(ownerId) &
                row.status.equals('claimed') &
                row.leaseExpiresAt.isBiggerThanValue(now),
          ))
          .getSingleOrNull();

  Future<bool> _hasCompletedPrefix(String claimId, int ordinal) async {
    if (ordinal <= 0) return false;
    final prior =
        await (db.select(db.cardEvolutionWriterCalls)
              ..where(
                (row) =>
                    row.claimId.equals(claimId) &
                    row.ordinal.isSmallerThanValue(ordinal),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.ordinal)]))
            .get();
    if (prior.length != ordinal - 1) return false;
    return prior.indexed.every(
      (entry) =>
          entry.$2.ordinal == entry.$1 + 1 && entry.$2.status == 'completed',
    );
  }
}
