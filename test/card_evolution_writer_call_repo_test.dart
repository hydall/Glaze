import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_writer_call_repo.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

void main() {
  late AppDatabase db;
  late CardEvolutionWriterCallRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = CardEvolutionWriterCallRepo(db);
  });

  tearDown(() => db.close());

  test('persists an ordered completed prefix and immutable result', () async {
    await _insertClaim(db);
    final first = await repo.prepareNextCall(
      claimId: 'claim',
      ownerId: 'owner',
      now: 10,
      ordinal: 1,
      stage: 'history_consolidation',
      stageOrdinal: 1,
      prompt: 'first prompt',
    );
    expect(first.kind, 'prepared');
    expect(first.row?.promptHash, computeHash('first prompt'));

    final gap = await repo.prepareNextCall(
      claimId: 'claim',
      ownerId: 'owner',
      now: 11,
      ordinal: 3,
      stage: 'card_writer',
      stageOrdinal: 1,
      prompt: 'writer prompt',
    );
    expect(gap.kind, 'outOfOrder');

    expect(
      await repo.completeCall(
        id: first.row!.id,
        claimId: 'claim',
        ownerId: 'owner',
        now: 12,
        responseText: 'handoff',
        resultJson: '{"handoff":"handoff"}',
        source: 'model',
        parserCode: 'accepted',
        lastCallId: 'llm-call-1',
      ),
      isTrue,
    );
    final second = await repo.prepareNextCall(
      claimId: 'claim',
      ownerId: 'owner',
      now: 13,
      ordinal: 2,
      stage: 'card_writer',
      stageOrdinal: 1,
      prompt: 'writer prompt',
    );
    expect(second.kind, 'prepared');

    expect(
      () => db.customStatement(
        "UPDATE card_evolution_writer_calls SET response_text = 'changed' "
        "WHERE id = ?",
        [first.row!.id],
      ),
      throwsA(anything),
    );
  });

  test('failed current call can retry under a live owner lease', () async {
    await _insertClaim(db);
    final prepared = await repo.prepareNextCall(
      claimId: 'claim',
      ownerId: 'owner',
      now: 10,
      ordinal: 1,
      stage: 'card_writer',
      stageOrdinal: 1,
      prompt: 'prompt',
    );
    expect(
      await repo.failCall(
        id: prepared.row!.id,
        claimId: 'claim',
        ownerId: 'owner',
        now: 11,
        code: 'transportFailure',
        detail: 'offline',
        lastCallId: 'call-1',
      ),
      isTrue,
    );
    expect(
      await repo.retryFailed(
        id: prepared.row!.id,
        claimId: 'claim',
        ownerId: 'wrong-owner',
        now: 12,
      ),
      isFalse,
    );
    expect(
      await repo.retryFailed(
        id: prepared.row!.id,
        claimId: 'claim',
        ownerId: 'owner',
        now: 12,
      ),
      isTrue,
    );
    final retried = await repo.getById(prepared.row!.id);
    expect(retried?.status, 'prepared');
    expect(retried?.source, 'exact_retry');
    expect(retried?.failureCode, isNull);
  });
}

Future<void> _insertClaim(AppDatabase db) => db
    .into(db.cardEvolutionClaims)
    .insert(
      CardEvolutionClaimsCompanion.insert(
        id: 'claim',
        sessionId: 'session',
        characterId: 'character',
        ownerId: 'owner',
        status: 'claimed',
        leaseExpiresAt: 100,
        chatHistoryHash: 'history',
        effectiveCanonIdentity: 'canon',
        predecessorCursorHash: 'cursor',
        predecessorRunOrdinal: 1,
        inputHash: computeHash('{}'),
        selectedInputJson: const Value('{}'),
        createdAt: 1,
      ),
    );
