import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_writer_call_repo.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/features/card_rewrite/card_rewriter_recovery_view_service.dart';

void main() {
  late AppDatabase db;
  late CardRewriterRecoveryViewService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    service = CardRewriterRecoveryViewService(
      writerCallRepo: CardEvolutionWriterCallRepo(db),
    );
  });

  tearDown(() => db.close());

  test(
    'loads failed claims with ordered completed prefix and frontier',
    () async {
      await _insertClaim(db, id: 'older', failedAt: 10);
      await _insertClaim(db, id: 'newer', failedAt: 20);
      await _insertCall(
        db,
        id: 'completed',
        claimId: 'newer',
        ordinal: 1,
        status: 'completed',
      );
      await _insertCall(
        db,
        id: 'frontier',
        claimId: 'newer',
        ordinal: 2,
        status: 'failed',
      );

      final views = await service.load('session');

      expect(views.map((view) => view.claim.id), ['newer', 'older']);
      expect(views.first.calls.map((call) => call.id), [
        'completed',
        'frontier',
      ]);
      expect(views.first.completedCount, 1);
      expect(views.first.frontier?.id, 'frontier');
      expect(views.last.frontier, isNull);
    },
  );

  test(
    'completed boundary suppresses an older failed recovery chain',
    () async {
      await _insertClaim(
        db,
        id: 'failed',
        failedAt: 20,
        predecessorRunOrdinal: 3,
        predecessorCursorHash: 'shared-boundary',
      );
      await _insertClaim(
        db,
        id: 'completed',
        failedAt: 0,
        status: 'completed',
        predecessorRunOrdinal: 3,
        predecessorCursorHash: 'shared-boundary',
      );

      expect(await service.load('session'), isEmpty);
    },
  );

  test('same ordinal on another boundary remains recoverable', () async {
    await _insertClaim(
      db,
      id: 'failed',
      failedAt: 20,
      predecessorRunOrdinal: 3,
      predecessorCursorHash: 'failed-boundary',
    );
    await _insertClaim(
      db,
      id: 'completed',
      failedAt: 0,
      status: 'completed',
      predecessorRunOrdinal: 3,
      predecessorCursorHash: 'completed-boundary',
    );

    final views = await service.load('session');
    expect(views.map((view) => view.claim.id), ['failed']);
  });
}

Future<void> _insertClaim(
  AppDatabase db, {
  required String id,
  required int failedAt,
  String status = 'failed',
  int predecessorRunOrdinal = 1,
  String? predecessorCursorHash,
}) => db
    .into(db.cardEvolutionClaims)
    .insert(
      CardEvolutionClaimsCompanion.insert(
        id: id,
        sessionId: 'session',
        characterId: 'character',
        ownerId: 'owner',
        status: status,
        leaseExpiresAt: 0,
        chatHistoryHash: 'history-$id',
        effectiveCanonIdentity: 'canon-$id',
        predecessorCursorHash: predecessorCursorHash ?? 'cursor-$id',
        predecessorRunOrdinal: predecessorRunOrdinal,
        inputHash: computeHash('{"claim":"$id"}'),
        selectedInputJson: Value('{"claim":"$id"}'),
        failureCode: status == 'failed'
            ? const Value('transportFailure')
            : const Value(null),
        createdAt: 1,
        completedAt: status == 'completed' ? const Value(2) : const Value(null),
        failedAt: status == 'failed' ? Value(failedAt) : const Value(null),
      ),
    );

Future<void> _insertCall(
  AppDatabase db, {
  required String id,
  required String claimId,
  required int ordinal,
  required String status,
}) => db
    .into(db.cardEvolutionWriterCalls)
    .insert(
      CardEvolutionWriterCallsCompanion.insert(
        id: id,
        claimId: claimId,
        sessionId: 'session',
        ordinal: ordinal,
        stage: ordinal == 1 ? 'card_writer' : 'lorebook_writer',
        stageOrdinal: 1,
        status: status,
        prompt: 'prompt-$id',
        promptHash: computeHash('prompt-$id'),
        responseText: status == 'completed'
            ? const Value('response')
            : const Value(null),
        responseHash: status == 'completed'
            ? Value(computeHash('response'))
            : const Value(null),
        resultJson: status == 'completed'
            ? const Value('[]')
            : const Value(null),
        failureCode: status == 'failed'
            ? const Value('transportFailure')
            : const Value(null),
        createdAt: ordinal,
        updatedAt: ordinal,
      ),
    );
