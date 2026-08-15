import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/features/chat/chat_message_service.dart';

final _messageServiceProvider = Provider(ChatMessageService.new);

ChatSession _session(int messageCount) => ChatSession(
  id: 's1',
  characterId: 'c1',
  sessionIndex: 0,
  messages: [
    for (var i = 0; i < messageCount; i++)
      ChatMessage(
        id: 'm$i',
        role: i.isEven ? 'user' : 'assistant',
        content: 'message $i',
      ),
  ],
);

void main() {
  test('planDeleteMessages shortens the session without a write', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final session = _session(5);
    await container.read(chatRepoProvider).put(session);

    final plan = container.read(_messageServiceProvider).planDeleteMessages(
      session,
      {1, 3},
    );

    expect(plan, isNotNull);
    expect(plan!.session.messages.map((m) => m.id), ['m0', 'm2', 'm4']);
    expect(plan.session.deletedMessageCount, 2);
    expect(plan.deletedIndices, unorderedEquals([1, 3]));
    expect(plan.earliestDeletedIndex, 1);
    // Everything from the earliest deletion on is causally invalidated.
    expect(
      plan.invalidatedMessageIds,
      unorderedEquals(['m1', 'm2', 'm3', 'm4']),
    );

    // Planning is pure: the row on disk is untouched until the commit runs.
    final persisted = await container.read(chatRepoProvider).getById('s1');
    expect(persisted?.messages.map((m) => m.id), [
      'm0',
      'm1',
      'm2',
      'm3',
      'm4',
    ]);
  });

  test('planDeleteMessages returns null when nothing is in range', () {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final service = container.read(_messageServiceProvider);
    expect(service.planDeleteMessages(_session(3), const <int>{}), isNull);
    expect(service.planDeleteMessages(_session(3), const {7, -1}), isNull);
  });

  test('commitDeleteMessages persists exactly the planned session', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final session = _session(5);
    await container.read(chatRepoProvider).put(session);

    final service = container.read(_messageServiceProvider);
    final plan = service.planDeleteMessages(session, {1, 3})!;
    final committed = await service.commitDeleteMessages(session, plan);

    expect(identical(committed, plan.session), isTrue);
    final persisted = await container.read(chatRepoProvider).getById('s1');
    expect(persisted?.messages.map((m) => m.id), ['m0', 'm2', 'm4']);
    expect(persisted?.deletedMessageCount, 2);
  });

  test(
    'tail deletion preserves completed reconciliation range and checkpoint',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      final session = _session(6);
      await container.read(chatRepoProvider).put(session);
      await _seedReconciliation(container, session);

      final service = container.read(_messageServiceProvider);
      final plan = service.planDeleteMessages(session, {4, 5})!;
      await service.commitDeleteMessages(session, plan);

      expect(
        await container
            .read(ledgerReconciliationCheckpointRepoProvider)
            .get(session.id),
        isNotNull,
      );
      expect(
        (await container
                .read(ledgerReconciliationRunRepoProvider)
                .getHead(session.id))
            ?.id,
        'run-1',
      );
      expect(
        (await db.select(db.cardEvolutionCollectorRuns).get()).map(
          (row) => row.id,
        ),
        ['collector-1'],
      );
    },
  );

  for (final testCase in const [
    (name: 'inside', deletedIndex: 2),
    (name: 'before', deletedIndex: 0),
  ]) {
    test(
      '${testCase.name} range deletion invalidates reconciliation and checkpoint',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final container = ProviderContainer(
          overrides: [appDbProvider.overrideWithValue(db)],
        );
        addTearDown(() async {
          container.dispose();
          await db.close();
        });

        final session = _session(6);
        await container.read(chatRepoProvider).put(session);
        await _seedReconciliation(container, session);

        final service = container.read(_messageServiceProvider);
        final plan = service.planDeleteMessages(session, {
          testCase.deletedIndex,
        })!;
        await service.commitDeleteMessages(session, plan);

        expect(
          await container
              .read(ledgerReconciliationCheckpointRepoProvider)
              .get(session.id),
          isNull,
        );
        expect(
          await container
              .read(ledgerReconciliationRunRepoProvider)
              .getHead(session.id),
          isNull,
        );
        final invalidations = await db
            .select(db.ledgerReconciliationRunInvalidations)
            .get();
        expect(invalidations.map((row) => row.runId), ['run-1']);
        expect(await db.select(db.cardEvolutionCollectorRuns).get(), isEmpty);
      },
    );
  }
}

Future<void> _seedReconciliation(
  ProviderContainer container,
  ChatSession session,
) async {
  final messages = session.messages.sublist(1, 4);
  const checkpoint = LedgerReconciliationCheckpoint(
    sessionId: 's1',
    startMessageId: 'm1',
    endMessageId: 'm3',
    endSwipeId: 0,
    endAgentSwipeId: 0,
    messageIds: ['m1', 'm2', 'm3'],
    rangeHash: 'checkpoint-hash',
  );
  await container
      .read(ledgerReconciliationCheckpointRepoProvider)
      .upsert(checkpoint);
  final run = LedgerReconciliationRun(
    id: 'run-1',
    sessionId: session.id,
    ordinal: 1,
    anchors: [
      for (final message in messages)
        ReconciliationAnchor(
          messageId: message.id,
          swipeId: message.swipeId,
          agentSwipeId: message.agentSwipeId,
          role: message.role,
          contentHash: computeHash(message.content),
        ),
    ],
    acceptedManifestRefs: const [],
    effectiveCanonStamp: 'canon',
    effectiveCanonRevision: 1,
    effectiveCanonHash: 'canon-hash',
    canonicalResult: const {'facts': <String>[]},
    predecessorChainHash: '',
    contractVersion: 1,
    opsApplied: const [],
    createdAt: 1,
  );
  final result = await container
      .read(ledgerReconciliationRunRepoProvider)
      .append(run);
  expect(result, isA<ReconciliationRunAppended>());
  final db = container.read(appDbProvider);
  await db
      .into(db.cardEvolutionCollectorRuns)
      .insert(
        CardEvolutionCollectorRunsCompanion.insert(
          id: 'collector-1',
          sessionId: session.id,
          characterId: session.characterId,
          collectorOrdinal: 1,
          reconciliationRunId: run.id,
          reconciliationRunOrdinal: run.ordinal,
          reconciliationChainHash: run.chainHash,
          rangeHash: run.rangeHash,
          inputHash: 'input-hash',
          ownerId: 'owner',
          status: 'completed',
          leaseExpiresAt: 1,
          createdAt: 1,
        ),
      );
}
