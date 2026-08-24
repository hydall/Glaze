import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_lease_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_deletion_repo.dart';

void main() {
  late AppDatabase db;
  late LedgerReconciliationLeaseRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = LedgerReconciliationLeaseRepo(db);
  });

  tearDown(() => db.close());

  test('acquire, renew, expiry takeover, release, and isolation', () async {
    expect(
      await repo.acquire(
        sessionId: 'one',
        ownerId: 'first',
        purpose: 'normal',
        ttlSeconds: 10,
        now: 100,
      ),
      isTrue,
    );
    expect(
      await repo.acquire(
        sessionId: 'one',
        ownerId: 'foreign',
        purpose: 'manual',
        ttlSeconds: 10,
        now: 101,
      ),
      isFalse,
    );
    expect(
      await repo.renew(
        sessionId: 'one',
        ownerId: 'first',
        ttlSeconds: 10,
        now: 105,
      ),
      isTrue,
    );
    expect(
      await repo.acquire(
        sessionId: 'two',
        ownerId: 'foreign',
        purpose: 'replacement',
        ttlSeconds: 10,
        now: 105,
      ),
      isTrue,
    );
    expect(
      await repo.acquire(
        sessionId: 'one',
        ownerId: 'foreign',
        purpose: 'replacement',
        ttlSeconds: 10,
        now: 115,
      ),
      isTrue,
    );
    expect(
      await repo.ownsLiveLeaseInTransaction(
        sessionId: 'one',
        ownerId: 'first',
        now: 116,
      ),
      isFalse,
    );
    await repo.release(sessionId: 'one', ownerId: 'first');
    expect(
      await repo.ownsLiveLeaseInTransaction(
        sessionId: 'one',
        ownerId: 'foreign',
        now: 116,
      ),
      isTrue,
    );
    await repo.release(sessionId: 'one', ownerId: 'foreign');
    expect(
      await repo.ownsLiveLeaseInTransaction(
        sessionId: 'one',
        ownerId: 'foreign',
        now: 116,
      ),
      isFalse,
    );
  });

  test('session deletion and clear remove leases', () async {
    for (final sessionId in const ['delete', 'clear']) {
      await db.customStatement(
        'INSERT INTO chat_sessions '
        '(session_id, character_id, session_index, messages_json) '
        "VALUES ('$sessionId', 'character', 0, '[]')",
      );
      await repo.acquire(
        sessionId: sessionId,
        ownerId: 'owner',
        purpose: 'normal',
        ttlSeconds: 10,
        now: 100,
      );
    }

    final deletion = SessionDeletionRepo(db);
    await deletion.deleteSession('delete');
    await deletion.clearSession(
      sessionId: 'clear',
      replacementMessages: const [],
    );

    expect(await db.select(db.ledgerReconciliationLeases).get(), isEmpty);
  });
}
