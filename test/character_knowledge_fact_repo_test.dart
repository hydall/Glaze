import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/knowledge_cleanup.dart';

void main() {
  late AppDatabase db;
  late CharacterKnowledgeFactRepo repo;

  CharacterKnowledgeFact fact({
    String id = 'fact-1',
    String sessionId = 'session-1',
    String messageId = 'message-1',
    int swipeId = 0,
    int agentSwipeId = 0,
  }) => CharacterKnowledgeFact(
    id: id,
    chatSessionId: sessionId,
    knowerKey: 'entity:lucy',
    knowerName: 'Lucy',
    subjectKey: 'entity:danvi',
    subjectName: 'Danvi',
    factClass: CharacterKnowledgeFactClass.relationship,
    scopeKey: 'relationship:danvi',
    predicate: 'trusts',
    object: 'trusts Danvi with netrunning work',
    epistemicState: CharacterKnowledgeEpistemicState.confirmed,
    confidence: 0.9,
    importance: 0.8,
    entities: const ['Lucy', 'Danvi'],
    topics: const ['trust', 'netrunning'],
    sourceMessageId: messageId,
    sourceSwipeId: swipeId,
    sourceAgentSwipeId: agentSwipeId,
  );

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = CharacterKnowledgeFactRepo(db);
  });
  tearDown(() => db.close());

  test('tentative facts stay invisible until their anchor commits', () async {
    await repo.insertTentative(fact());

    expect(await repo.getActiveForSession('session-1'), isEmpty);

    await repo.activateAnchor(
      sessionId: 'session-1',
      messageId: 'message-1',
      swipeId: 0,
      agentSwipeId: 0,
    );

    expect((await repo.getActiveForSession('session-1')).single.id, 'fact-1');
  });

  test('round-trips basis revision metadata', () async {
    await repo.insertTentative(
      fact().copyWith(basisRevisionNumber: 12, basisRevisionHash: 'card-hash'),
    );

    final stored = await repo.getById('fact-1');
    expect(stored!.basisRevisionNumber, 12);
    expect(stored.basisRevisionHash, 'card-hash');
  });

  test('restores exact session rows and rejects foreign snapshots', () async {
    await repo.insertTentative(fact());
    final captured = await (db.select(
      db.characterKnowledgeFactRows,
    )..where((row) => row.chatSessionId.equals('session-1'))).get();
    final rowsJson = jsonEncode(captured.map((row) => row.toJson()).toList());

    await repo.insertTentative(fact(id: 'fact-2', messageId: 'message-2'));
    await repo.restoreSessionRowsExact('session-1', rowsJson);

    final restored = await repo.getById('fact-1');
    expect(restored!.id, captured.single.id);
    expect(restored.object, captured.single.object);
    expect(restored.lifecycle.name, captured.single.lifecycle);
    expect(await repo.getById('fact-2'), isNull);

    final foreign = CharacterKnowledgeFactRow.fromJson({
      ...captured.single.toJson(),
      'id': 'foreign',
      'chatSessionId': 'session-2',
    });
    expect(
      () => repo.restoreSessionRowsExact(
        'session-1',
        jsonEncode([foreign.toJson()]),
      ),
      throwsArgumentError,
    );
    expect(await repo.getById('fact-1'), isNotNull);
  });

  test('legacy facts default basis revision metadata', () {
    final legacy = fact();

    expect(legacy.basisRevisionNumber, 0);
    expect(legacy.basisRevisionHash, isEmpty);
  });

  test('activating an anchor retracts rejected sibling swipe facts', () async {
    await repo.insertTentative(fact(id: 'rejected', swipeId: 0));
    await repo.insertTentative(fact(id: 'accepted', swipeId: 1));

    await repo.activateAnchor(
      sessionId: 'session-1',
      messageId: 'message-1',
      swipeId: 1,
      agentSwipeId: 0,
    );

    expect(
      (await repo.getById('rejected'))!.lifecycle,
      CharacterKnowledgeFactLifecycle.retracted,
    );
    expect(
      (await repo.getById('accepted'))!.lifecycle,
      CharacterKnowledgeFactLifecycle.active,
    );
  });

  test(
    'replaying an anchor replaces its tentative export instead of duplicating',
    () async {
      await repo.insertTentative(fact(id: 'old'));
      await repo.insertTentative(fact(id: 'replacement'));

      final atAnchor = await repo.getBySourceAnchor(
        sessionId: 'session-1',
        messageId: 'message-1',
        swipeId: 0,
        agentSwipeId: 0,
      );
      expect(atAnchor.map((item) => item.id), ['replacement']);
    },
  );

  test('reconciliation retracts only an existing reviewable fact', () async {
    await repo.insertTentative(fact());
    await repo.activateAnchor(
      sessionId: 'session-1',
      messageId: 'message-1',
      swipeId: 0,
      agentSwipeId: 0,
    );

    final applied = await repo.applyReconciliationCleanup(
      sessionId: 'session-1',
      ops: const [
        KnowledgeCleanupOp.retract('fact-1'),
        KnowledgeCleanupOp.retract('missing'),
      ],
    );

    expect(applied, 1);
    expect(
      (await repo.getById('fact-1'))!.lifecycle,
      CharacterKnowledgeFactLifecycle.retracted,
    );
  });

  test('identity migration deduplicates only the migrated slot', () async {
    await repo.insertTentative(fact(id: 'canonical'));
    await repo.activateAnchor(
      sessionId: 'session-1',
      messageId: 'message-1',
      swipeId: 0,
      agentSwipeId: 0,
    );
    await repo.insertTentative(
      fact(id: 'placeholder', messageId: 'message-2').copyWith(
        knowerKey: 'entity:unidentified_netrunner',
        knowerName: 'Unidentified Netrunner',
        importance: 0.2,
      ),
    );
    await repo.activateAnchor(
      sessionId: 'session-1',
      messageId: 'message-2',
      swipeId: 0,
      agentSwipeId: 0,
    );

    final applied = await repo.applyReconciliationCleanup(
      sessionId: 'session-1',
      ops: const [
        KnowledgeCleanupOp.renameEntity(
          fromKey: 'entity:unidentified_netrunner',
          toKey: 'entity:lucy',
          canonicalName: 'Lucy',
        ),
      ],
    );

    expect(applied, 2);
    expect(
      (await repo.getById('canonical'))!.lifecycle,
      CharacterKnowledgeFactLifecycle.active,
    );
    final placeholder = await repo.getById('placeholder');
    expect(placeholder!.knowerKey, 'entity:lucy');
    expect(placeholder.knowerName, 'Lucy');
    expect(placeholder.lifecycle, CharacterKnowledgeFactLifecycle.retracted);
  });

  test(
    'reconciliation cleanup cannot mutate facts outside its range',
    () async {
      await repo.insertTentative(fact(id: 'inside', messageId: 'message-1'));
      await repo.activateAnchor(
        sessionId: 'session-1',
        messageId: 'message-1',
        swipeId: 0,
        agentSwipeId: 0,
      );
      await repo.insertTentative(fact(id: 'future', messageId: 'message-2'));
      await repo.activateAnchor(
        sessionId: 'session-1',
        messageId: 'message-2',
        swipeId: 0,
        agentSwipeId: 0,
      );

      final applied = await repo.applyReconciliationCleanup(
        sessionId: 'session-1',
        ops: const [KnowledgeCleanupOp.retract('future')],
        allowedFactIds: const {'inside'},
        endpointMessageId: 'message-1',
        messageIds: const ['message-1'],
      );

      expect(applied, 0);
      expect(
        (await repo.getById('future'))!.lifecycle,
        CharacterKnowledgeFactLifecycle.active,
      );
    },
  );

  test('reconciliation cleanup journal restores renamed facts', () async {
    await repo.insertTentative(
      fact(
        id: 'placeholder',
      ).copyWith(knowerKey: 'entity:unknown', knowerName: 'Unknown'),
    );
    await repo.activateAnchor(
      sessionId: 'session-1',
      messageId: 'message-1',
      swipeId: 0,
      agentSwipeId: 0,
    );
    await repo.applyReconciliationCleanup(
      sessionId: 'session-1',
      ops: const [
        KnowledgeCleanupOp.renameEntity(
          fromKey: 'entity:unknown',
          toKey: 'entity:lucy',
          canonicalName: 'Lucy',
        ),
      ],
      allowedFactIds: const {'placeholder'},
      endpointMessageId: 'message-2',
      messageIds: const ['message-1', 'message-2'],
    );

    expect((await repo.getById('placeholder'))!.knowerKey, 'entity:lucy');
    await repo.rollbackReconciliationCleanupForMessages('session-1', const {
      'message-2',
    });

    final restored = await repo.getById('placeholder');
    expect(restored!.knowerKey, 'entity:unknown');
    expect(restored.knowerName, 'Unknown');
    expect(
      await db.select(db.ledgerReconciliationCleanupJournals).get(),
      isEmpty,
    );
  });

  test('reconciliation cleanup journal restores retracted facts', () async {
    await repo.insertTentative(fact());
    await repo.activateAnchor(
      sessionId: 'session-1',
      messageId: 'message-1',
      swipeId: 0,
      agentSwipeId: 0,
    );
    await repo.applyReconciliationCleanup(
      sessionId: 'session-1',
      ops: const [KnowledgeCleanupOp.retract('fact-1')],
      allowedFactIds: const {'fact-1'},
      endpointMessageId: 'message-2',
      messageIds: const ['message-1', 'message-2'],
    );

    expect(
      (await repo.getById('fact-1'))!.lifecycle,
      CharacterKnowledgeFactLifecycle.retracted,
    );
    await repo.rollbackReconciliationCleanupForMessages('session-1', const {
      'message-2',
    });

    expect(
      (await repo.getById('fact-1'))!.lifecycle,
      CharacterKnowledgeFactLifecycle.active,
    );
  });

  test('deletes cleanup journal only for the exact ordered range', () async {
    await db.customStatement(
      'INSERT INTO ledger_reconciliation_cleanup_journals '
      '(session_id, endpoint_message_id, message_ids_json, before_images_json, created_at) '
      "VALUES ('session-1', 'end', '[\"a\",\"end\"]', '[]', 1), "
      "('session-1', 'end', '[\"other\",\"end\"]', '[]', 2)",
    );

    await repo.deleteCleanupJournalsForExactRange(
      sessionId: 'session-1',
      endpointMessageId: 'end',
      messageIds: const ['a', 'end'],
    );

    final rows = await db.select(db.ledgerReconciliationCleanupJournals).get();
    expect(rows, hasLength(1));
    expect(rows.single.messageIdsJson, '["other","end"]');
  });

  test(
    'replaying an anchor with no facts clears stale tentative output',
    () async {
      await repo.insertTentative(fact(id: 'stale'));

      await repo.replaceTentativeAnchor(
        sessionId: 'session-1',
        messageId: 'message-1',
        swipeId: 0,
        agentSwipeId: 0,
        facts: const [],
      );

      expect(
        await repo.getBySourceAnchor(
          sessionId: 'session-1',
          messageId: 'message-1',
          swipeId: 0,
          agentSwipeId: 0,
        ),
        isEmpty,
      );
    },
  );

  test(
    'activating a relationship slot supersedes its prior current value',
    () async {
      await repo.insertTentative(fact(id: 'low', messageId: 'message-1'));
      await repo.activateAnchor(
        sessionId: 'session-1',
        messageId: 'message-1',
        swipeId: 0,
        agentSwipeId: 0,
      );
      await repo.insertTentative(
        fact(
          id: 'high',
          messageId: 'message-2',
        ).copyWith(predicate: 'fully trusts', object: 'fully trusts Danvi'),
      );

      await repo.activateAnchor(
        sessionId: 'session-1',
        messageId: 'message-2',
        swipeId: 0,
        agentSwipeId: 0,
      );

      expect(
        (await repo.getActiveForSession('session-1')).map((item) => item.id),
        ['high'],
      );
      expect(
        (await repo.getById('low'))!.lifecycle,
        CharacterKnowledgeFactLifecycle.superseded,
      );
      expect((await repo.getById('high'))!.supersedesId, 'low');
    },
  );

  test('retracting a replacement restores prior relationship truth', () async {
    await repo.insertTentative(fact(id: 'low', messageId: 'message-1'));
    await repo.activateAnchor(
      sessionId: 'session-1',
      messageId: 'message-1',
      swipeId: 0,
      agentSwipeId: 0,
    );
    await repo.insertTentative(
      fact(
        id: 'high',
        messageId: 'message-2',
      ).copyWith(predicate: 'fully trusts', object: 'fully trusts Danvi'),
    );
    await repo.activateAnchor(
      sessionId: 'session-1',
      messageId: 'message-2',
      swipeId: 0,
      agentSwipeId: 0,
    );

    await repo.retractAnchor(
      sessionId: 'session-1',
      messageId: 'message-2',
      swipeId: 0,
      agentSwipeId: 0,
    );

    expect(
      (await repo.getActiveForSession('session-1')).map((item) => item.id),
      ['low'],
    );
  });

  test(
    'superseding preserves the old row but excludes it from active retrieval',
    () async {
      await repo.insertTentative(fact(id: 'old'));
      await repo.activateAnchor(
        sessionId: 'session-1',
        messageId: 'message-1',
        swipeId: 0,
        agentSwipeId: 0,
      );

      await repo.supersede('old', fact(id: 'new', messageId: 'message-2'));

      expect(
        (await repo.getActiveForSession('session-1')).map((item) => item.id),
        ['new'],
      );
      final old = await repo.getById('old');
      expect(old!.lifecycle, CharacterKnowledgeFactLifecycle.superseded);
      expect((await repo.getById('new'))!.supersedesId, 'old');
    },
  );

  test(
    'retracting an anchor removes facts from active retrieval without delete',
    () async {
      await repo.insertTentative(fact());
      await repo.activateAnchor(
        sessionId: 'session-1',
        messageId: 'message-1',
        swipeId: 0,
        agentSwipeId: 0,
      );

      await repo.retractAnchor(
        sessionId: 'session-1',
        messageId: 'message-1',
        swipeId: 0,
        agentSwipeId: 0,
      );

      expect(await repo.getActiveForSession('session-1'), isEmpty);
      expect(
        (await repo.getById('fact-1'))!.lifecycle,
        CharacterKnowledgeFactLifecycle.retracted,
      );
    },
  );

  test(
    'retracting a deleted message tombstones every swipe at that message',
    () async {
      await repo.insertTentative(fact(id: 'swipe-0', swipeId: 0));
      await repo.insertTentative(fact(id: 'swipe-1', swipeId: 1));
      await repo.activateAnchor(
        sessionId: 'session-1',
        messageId: 'message-1',
        swipeId: 0,
        agentSwipeId: 0,
      );
      await repo.activateAnchor(
        sessionId: 'session-1',
        messageId: 'message-1',
        swipeId: 1,
        agentSwipeId: 0,
      );

      await repo.retractForMessage('session-1', 'message-1');

      expect(await repo.getActiveForSession('session-1'), isEmpty);
      expect(
        (await repo.getById('swipe-0'))!.lifecycle,
        CharacterKnowledgeFactLifecycle.retracted,
      );
      expect(
        (await repo.getById('swipe-1'))!.lifecycle,
        CharacterKnowledgeFactLifecycle.retracted,
      );
    },
  );

  test(
    'branch copies only facts whose source messages exist in the slice',
    () async {
      await repo.insertTentative(fact(id: 'kept', messageId: 'message-1'));
      await repo.insertTentative(fact(id: 'skipped', messageId: 'message-2'));
      await repo.activateAnchor(
        sessionId: 'session-1',
        messageId: 'message-1',
        swipeId: 0,
        agentSwipeId: 0,
      );
      await repo.activateAnchor(
        sessionId: 'session-1',
        messageId: 'message-2',
        swipeId: 0,
        agentSwipeId: 0,
      );

      await repo.copyForSessionBranch(
        fromSessionId: 'session-1',
        toSessionId: 'branch-1',
        messageIds: const {'message-1'},
      );

      expect(
        (await repo.getActiveForSession('branch-1')).map((item) => item.id),
        ['kept@branch-1'],
      );
    },
  );

  test(
    'branch copies reconciliation cleanup journal for a full range',
    () async {
      await repo.insertTentative(fact(id: 'kept'));
      await repo.activateAnchor(
        sessionId: 'session-1',
        messageId: 'message-1',
        swipeId: 0,
        agentSwipeId: 0,
      );
      await repo.applyReconciliationCleanup(
        sessionId: 'session-1',
        ops: const [KnowledgeCleanupOp.retract('kept')],
        allowedFactIds: const {'kept'},
        endpointMessageId: 'message-2',
        messageIds: const ['message-1', 'message-2'],
      );

      await repo.copyForSessionBranch(
        fromSessionId: 'session-1',
        toSessionId: 'branch-1',
        messageIds: const {'message-1', 'message-2'},
      );

      final journals = await (db.select(
        db.ledgerReconciliationCleanupJournals,
      )..where((row) => row.sessionId.equals('branch-1'))).get();
      expect(journals, hasLength(1));
      expect(journals.single.endpointMessageId, 'message-2');
      expect(journals.single.beforeImagesJson, contains('kept@branch-1'));
    },
  );
}
