import 'package:drift/drift.dart';

import '../../utils/time_helpers.dart';
import '../app_db.dart';

final class LedgerReconciliationLeaseRepo {
  const LedgerReconciliationLeaseRepo(this.db);

  final AppDatabase db;

  /// Reconciliation leases coordinate work inside one running app process.
  /// A new app scope has no surviving owner, so persisted rows are orphans.
  Future<void> clearProcessOrphans() async {
    await db.delete(db.ledgerReconciliationLeases).go();
  }

  Future<bool> acquire({
    required String sessionId,
    required String ownerId,
    required String purpose,
    required int ttlSeconds,
    int? now,
  }) => db.transaction(() async {
    final acquiredAt = now ?? currentTimestampSeconds();
    final expiresAt = acquiredAt + ttlSeconds;
    await db
        .into(db.ledgerReconciliationLeases)
        .insert(
          LedgerReconciliationLeasesCompanion.insert(
            sessionId: sessionId,
            ownerId: ownerId,
            purpose: purpose,
            leaseExpiresAt: expiresAt,
            acquiredAt: acquiredAt,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    final changed =
        await (db.update(db.ledgerReconciliationLeases)..where(
              (row) =>
                  row.sessionId.equals(sessionId) &
                  (row.ownerId.equals(ownerId) |
                      row.leaseExpiresAt.isSmallerOrEqualValue(acquiredAt)),
            ))
            .write(
              LedgerReconciliationLeasesCompanion(
                ownerId: Value(ownerId),
                purpose: Value(purpose),
                leaseExpiresAt: Value(expiresAt),
                acquiredAt: Value(acquiredAt),
              ),
            );
    if (changed == 1) return true;
    return ownsLiveLeaseInTransaction(
      sessionId: sessionId,
      ownerId: ownerId,
      now: acquiredAt,
    );
  });

  Future<bool> renew({
    required String sessionId,
    required String ownerId,
    required int ttlSeconds,
    int? now,
  }) async {
    final renewedAt = now ?? currentTimestampSeconds();
    final changed =
        await (db.update(db.ledgerReconciliationLeases)..where(
              (row) =>
                  row.sessionId.equals(sessionId) &
                  row.ownerId.equals(ownerId) &
                  row.leaseExpiresAt.isBiggerThanValue(renewedAt),
            ))
            .write(
              LedgerReconciliationLeasesCompanion(
                leaseExpiresAt: Value(renewedAt + ttlSeconds),
              ),
            );
    return changed == 1;
  }

  Future<bool> ownsLiveLeaseInTransaction({
    required String sessionId,
    required String ownerId,
    int? now,
  }) async {
    final checkedAt = now ?? currentTimestampSeconds();
    final row =
        await (db.select(db.ledgerReconciliationLeases)..where(
              (row) =>
                  row.sessionId.equals(sessionId) &
                  row.ownerId.equals(ownerId) &
                  row.leaseExpiresAt.isBiggerThanValue(checkedAt),
            ))
            .getSingleOrNull();
    return row != null;
  }

  Future<void> release({
    required String sessionId,
    required String ownerId,
  }) async {
    await (db.delete(db.ledgerReconciliationLeases)..where(
          (row) =>
              row.sessionId.equals(sessionId) & row.ownerId.equals(ownerId),
        ))
        .go();
  }
}
