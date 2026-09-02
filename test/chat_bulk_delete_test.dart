import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/knowledge_cleanup.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_message_service.dart';

final _messageServiceProvider = Provider(ChatMessageService.new);

void main() {
  test(
    'deleting generated messages restores the original game-time seed',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      final session = ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        messages: const [
          ChatMessage(
            id: 'g1',
            role: 'assistant',
            content: 'hello',
            timestamp: 1,
          ),
          ChatMessage(id: 'u1', role: 'user', content: 'hi', timestamp: 2),
          ChatMessage(
            id: 'a1',
            role: 'assistant',
            content: 'reply',
            timestamp: 3,
          ),
          ChatMessage(id: 'u2', role: 'user', content: 'next', timestamp: 4),
          ChatMessage(
            id: 'a2',
            role: 'assistant',
            content: 'later',
            timestamp: 5,
          ),
        ],
      );
      await container.read(chatRepoProvider).put(session);
      final trackerRepo = container.read(trackerRepoProvider);
      await trackerRepo.seedInitialGameTime(
        sessionId: 's1',
        time: '08:00',
        date: '21.04.2026',
      );
      await trackerRepo.upsertValue(
        's1',
        'world:time',
        '08:27',
        scope: 'ledger',
        provenance: 'studio_ledger',
      );

      await container.read(_messageServiceProvider).deleteMessages(session, {
        2,
        3,
        4,
      });

      final seed = await trackerRepo.getInitialGameTimeSeed('s1');
      expect(seed.map((t) => t.name).toSet(), {
        'world:time',
        'world:date',
        'world:day',
      });
      final byName = {for (final t in seed) t.name: t.value};
      expect(byName['world:time'], '08:00');
      expect(byName['world:date'], '21.04.2026');
      expect(byName['world:day'], '0');
      expect((await trackerRepo.get('s1', 'world:time'))?.value, '08:00');
      expect(
        (await container.read(chatRepoProvider).getById('s1'))?.messages.map(
          (message) => message.id,
        ),
        ['g1', 'u1'],
      );
    },
  );

  test('legacy rollback keeps live clock without inventing a seed', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final session = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      messages: const [
        ChatMessage(id: 'u1', role: 'user', content: 'hi'),
        ChatMessage(id: 'a1', role: 'assistant', content: 'reply'),
      ],
    );
    await container.read(chatRepoProvider).put(session);
    final trackerRepo = container.read(trackerRepoProvider);
    for (final entry in {
      'world:time': '08:27',
      'world:date': '21.04.2026',
      'world:day': '0',
    }.entries) {
      await trackerRepo.upsertValue(
        's1',
        entry.key,
        entry.value,
        scope: 'ledger',
        provenance: 'studio_ledger',
      );
    }

    await container.read(_messageServiceProvider).deleteMessages(session, {1});

    expect((await trackerRepo.get('s1', 'world:time'))?.value, '08:27');
    expect(await trackerRepo.getInitialGameTimeSeed('s1'), isEmpty);
    expect(
      await trackerRepo.get('s1', TrackerRepo.initialGameTimeSeedName),
      isNull,
    );
  });

  test(
    'bulk delete persists final state and clears raw-message index',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      final messages = [
        for (var i = 0; i < 39; i++)
          ChatMessage(
            id: 'm$i',
            role: i.isEven ? 'user' : 'assistant',
            content: 'message $i',
          ),
      ];
      final session = ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        messages: messages,
      );
      await container.read(chatRepoProvider).put(session);
      await container
          .read(embeddingRepoProvider)
          .putEmbeddingVector(
            entryId: 's1_0',
            sourceType: 'chat_message',
            sourceId: 's1',
            vectors: const [
              [1, 0],
            ],
            textHash: 'old',
            retrievalMetadata: const {'chunkIndex': 0},
          );

      final updated = await container
          .read(_messageServiceProvider)
          .deleteMessages(session, {for (var i = 0; i < 30; i++) i});

      expect(updated.messages.map((message) => message.id), [
        for (var i = 30; i < 39; i++) 'm$i',
      ]);
      final persisted = await container.read(chatRepoProvider).getById('s1');
      expect(persisted?.messages.map((message) => message.id), [
        for (var i = 30; i < 39; i++) 'm$i',
      ]);
      expect(
        await container.read(embeddingRepoProvider).getBySourceId('s1'),
        isEmpty,
      );
    },
  );

  test(
    'deleteMessages accumulates the persisted deleted-message counter',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      final messages = [
        for (var i = 0; i < 6; i++)
          ChatMessage(
            id: 'm$i',
            role: i.isEven ? 'user' : 'assistant',
            content: 'message $i',
          ),
      ];
      final session = ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        messages: messages,
      );
      await container.read(chatRepoProvider).put(session);
      expect(session.deletedMessageCount, 0);

      final service = container.read(_messageServiceProvider);

      // Deleting two messages bumps the counter by two.
      final afterFirst = await service.deleteMessages(session, {0, 3});
      expect(afterFirst.deletedMessageCount, 2);

      // A second delete accumulates on top of the first.
      final afterSecond = await service.deleteMessages(afterFirst, {0});
      expect(afterSecond.deletedMessageCount, 3);

      // Out-of-range indices delete nothing and leave the counter untouched.
      final afterNoop = await service.deleteMessages(afterSecond, {999});
      expect(afterNoop.deletedMessageCount, 3);

      // The counter is persisted so it survives the messages being gone.
      final persisted = await container.read(chatRepoProvider).getById('s1');
      expect(persisted?.deletedMessageCount, 3);
    },
  );

  test(
    'middle deletion invalidates causal suffix and rolls reconciliation back',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      const sessionId = 's1';
      final messages = [
        for (var i = 0; i < 6; i++)
          ChatMessage(
            id: 'm$i',
            role: i.isEven ? 'user' : 'assistant',
            content: 'message $i',
          ),
      ];
      final session = ChatSession(
        id: sessionId,
        characterId: 'c1',
        sessionIndex: 0,
        messages: messages,
      );
      await container.read(chatRepoProvider).put(session);
      final snapshots = container.read(trackerSnapshotRepoProvider);
      final trackers = container.read(trackerRepoProvider);
      Tracker ledger(String value) => Tracker(
        sessionId: sessionId,
        name: 'scene.location',
        value: value,
        scope: 'ledger',
      );
      await snapshots.upsertTrackers(
        sessionId: sessionId,
        messageId: 'm1',
        swipeId: 0,
        agentSwipeId: 0,
        trackers: [ledger('prefix')],
        committed: true,
      );
      await snapshots.upsertTrackers(
        sessionId: sessionId,
        messageId: 'm3',
        swipeId: 0,
        agentSwipeId: 0,
        trackers: [ledger('reconciled')],
        committed: true,
      );
      await snapshots.upsertTrackers(
        sessionId: sessionId,
        messageId: 'm5',
        swipeId: 0,
        agentSwipeId: 0,
        trackers: [ledger('later')],
        committed: true,
      );
      await trackers.upsert(ledger('later'));
      await trackers.upsert(
        const Tracker(
          sessionId: sessionId,
          name: 'canon_lock:scene.location',
          value: 'locked',
          scope: 'ledger',
        ),
      );
      await trackers.upsert(
        const Tracker(
          sessionId: sessionId,
          name: '_ledger_diag:studio_ledger_reconciliation',
          value: 'status=ok',
          scope: 'ledger_diagnostic',
        ),
      );
      await container
          .read(ledgerReconciliationCheckpointRepoProvider)
          .upsert(
            const LedgerReconciliationCheckpoint(
              sessionId: sessionId,
              startMessageId: 'm0',
              endMessageId: 'm3',
              endSwipeId: 0,
              endAgentSwipeId: 0,
              messageIds: ['m0', 'm1', 'm2', 'm3'],
              rangeHash: 'hash',
            ),
          );

      final facts = container.read(characterKnowledgeFactRepoProvider);
      CharacterKnowledgeFact fact(String id, String messageId) =>
          CharacterKnowledgeFact(
            id: id,
            chatSessionId: sessionId,
            knowerKey: 'entity:unknown',
            knowerName: 'Unknown',
            subjectKey: 'entity:danvi',
            factClass: CharacterKnowledgeFactClass.knowledge,
            predicate: 'knows',
            object: id,
            epistemicState: CharacterKnowledgeEpistemicState.confirmed,
            sourceMessageId: messageId,
            sourceSwipeId: 0,
            sourceAgentSwipeId: 0,
          );
      await facts.insertTentative(fact('prefix-fact', 'm1'));
      await facts.activateAnchor(
        sessionId: sessionId,
        messageId: 'm1',
        swipeId: 0,
        agentSwipeId: 0,
      );
      await facts.insertTentative(fact('suffix-fact', 'm4'));
      await facts.activateAnchor(
        sessionId: sessionId,
        messageId: 'm4',
        swipeId: 0,
        agentSwipeId: 0,
      );
      await facts.applyReconciliationCleanup(
        sessionId: sessionId,
        ops: const [
          KnowledgeCleanupOp.renameEntity(
            fromKey: 'entity:unknown',
            toKey: 'entity:lucy',
            canonicalName: 'Lucy',
          ),
        ],
        allowedFactIds: const {'prefix-fact'},
        endpointMessageId: 'm3',
        messageIds: const ['m0', 'm1', 'm2', 'm3'],
      );

      final updated = await container
          .read(_messageServiceProvider)
          .deleteMessages(session, {2});

      expect(updated.messages.map((message) => message.id), [
        'm0',
        'm1',
        'm3',
        'm4',
        'm5',
      ]);
      expect(
        (await snapshots.getBySessionId(
          sessionId,
        )).map((item) => item.messageId),
        ['m1'],
      );
      expect(
        await container
            .read(ledgerReconciliationCheckpointRepoProvider)
            .get(sessionId),
        isNull,
      );
      expect(
        (await trackers.get(sessionId, 'scene.location'))?.value,
        'prefix',
      );
      expect(
        await trackers.get(sessionId, 'canon_lock:scene.location'),
        isNotNull,
      );
      expect(
        await trackers.get(
          sessionId,
          '_ledger_diag:studio_ledger_reconciliation',
        ),
        isNotNull,
      );
      expect((await facts.getById('prefix-fact'))!.knowerKey, 'entity:unknown');
      expect(
        (await facts.getById('suffix-fact'))!.lifecycle,
        CharacterKnowledgeFactLifecycle.retracted,
      );
      expect(
        await db.select(db.ledgerReconciliationCleanupJournals).get(),
        isEmpty,
      );
    },
  );
}
