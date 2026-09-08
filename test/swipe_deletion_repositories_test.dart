import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/extensions/models/info_block.dart';

CharacterKnowledgeFact _fact({
  required String id,
  required int swipeId,
  required int agentSwipeId,
}) => CharacterKnowledgeFact(
  id: id,
  chatSessionId: 's1',
  knowerKey: 'knower-$id',
  knowerName: 'Knower',
  subjectKey: 'subject-$id',
  subjectName: 'Subject',
  factClass: CharacterKnowledgeFactClass.knowledge,
  scopeKey: 'scope-$id',
  predicate: 'predicate-$id',
  object: 'object-$id',
  epistemicState: CharacterKnowledgeEpistemicState.confirmed,
  confidence: 1,
  importance: 1,
  sourceMessageId: 'm1',
  sourceSwipeId: swipeId,
  sourceAgentSwipeId: agentSwipeId,
);

InfoBlock _block({
  required String id,
  required int swipeId,
  required int agentSwipeId,
}) => InfoBlock(
  id: id,
  sessionId: 's1',
  messageId: 'm1',
  swipeId: swipeId,
  agentSwipeId: agentSwipeId,
  blockId: id,
  blockName: id,
  blockType: 'infoblock',
  content: id,
  createdAt: 1,
);

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('green deletion removes its anchors and shifts later anchors', () async {
    final snapshots = container.read(trackerSnapshotRepoProvider);
    final facts = container.read(characterKnowledgeFactRepoProvider);
    final memory = container.read(memoryBookRepoProvider);
    final blocks = container.read(infoBlocksRepoProvider);

    await snapshots.upsertTrackers(
      sessionId: 's1',
      messageId: 'm1',
      swipeId: 0,
      agentSwipeId: 0,
      trackers: const [],
    );
    await snapshots.upsertTrackers(
      sessionId: 's1',
      messageId: 'm1',
      swipeId: 1,
      agentSwipeId: 0,
      trackers: const [],
    );
    await facts.insertTentative(
      _fact(id: 'removed-fact', swipeId: 0, agentSwipeId: 0),
    );
    await facts.insertTentative(
      _fact(id: 'kept-fact', swipeId: 1, agentSwipeId: 0),
    );
    await memory.put(
      const MemoryBook(
        id: 'memorybook_s1',
        sessionId: 's1',
        entries: [
          MemoryEntry(
            id: 'removed-memory',
            messageIds: ['m1'],
            sourceSwipeId: 0,
          ),
          MemoryEntry(id: 'kept-memory', messageIds: ['m1'], sourceSwipeId: 1),
        ],
      ),
    );
    await blocks.insert(
      _block(id: 'removed-block', swipeId: 0, agentSwipeId: 0),
    );
    await blocks.insert(_block(id: 'kept-block', swipeId: 1, agentSwipeId: 0));

    await db.transaction(() async {
      await snapshots.deleteSwipe(sessionId: 's1', messageId: 'm1', swipeId: 0);
      await snapshots.shiftSwipeIdsAfterRemoval(
        sessionId: 's1',
        messageId: 'm1',
        removedSwipeId: 0,
      );
      await facts.deleteSwipeAndShift(
        sessionId: 's1',
        messageId: 'm1',
        removedSwipeId: 0,
      );
      await memory.deleteSwipeAndShift(
        sessionId: 's1',
        messageId: 'm1',
        removedSwipeId: 0,
      );
      await blocks.deleteSwipeAndShift(
        sessionId: 's1',
        messageId: 'm1',
        removedSwipeId: 0,
      );
    });

    expect(
      await snapshots.getByAnchor(
        sessionId: 's1',
        messageId: 'm1',
        swipeId: 0,
        agentSwipeId: 0,
      ),
      isNotNull,
    );
    expect(await facts.getById('removed-fact'), isNull);
    expect(
      (await facts.getBySourceAnchor(
        sessionId: 's1',
        messageId: 'm1',
        swipeId: 0,
        agentSwipeId: 0,
      )).single.id,
      'kept-fact',
    );
    final book = await memory.getBySessionId('s1');
    expect(book!.entries.single.id, 'kept-memory');
    expect(book.entries.single.sourceSwipeId, 0);
    final remainingBlocks = await blocks.getBySessionId('s1');
    expect(remainingBlocks.single.id, 'kept-block');
    expect(remainingBlocks.single.swipeId, 0);
  });

  test(
    'blue deletion shifts exact anchors and preserves legacy blocks',
    () async {
      final snapshots = container.read(trackerSnapshotRepoProvider);
      final facts = container.read(characterKnowledgeFactRepoProvider);
      final memory = container.read(memoryBookRepoProvider);
      final blocks = container.read(infoBlocksRepoProvider);

      for (var agentSwipeId = 0; agentSwipeId < 3; agentSwipeId++) {
        await snapshots.upsertTrackers(
          sessionId: 's1',
          messageId: 'm1',
          swipeId: 2,
          agentSwipeId: agentSwipeId,
          trackers: const [],
        );
      }
      await facts.insertTentative(
        _fact(id: 'removed-fact', swipeId: 2, agentSwipeId: 1),
      );
      await facts.insertTentative(
        _fact(id: 'kept-fact', swipeId: 2, agentSwipeId: 2),
      );
      await memory.put(
        const MemoryBook(
          id: 'memorybook_s1',
          sessionId: 's1',
          pendingDrafts: [
            MemoryDraft(
              id: 'removed-draft',
              messageIds: ['m1'],
              sourceSwipeId: 2,
              sourceAgentSwipeId: 1,
            ),
            MemoryDraft(
              id: 'kept-draft',
              messageIds: ['m1'],
              sourceSwipeId: 2,
              sourceAgentSwipeId: 2,
            ),
          ],
        ),
      );
      await blocks.insert(
        _block(id: 'legacy-block', swipeId: 2, agentSwipeId: -1),
      );
      await blocks.insert(
        _block(id: 'removed-block', swipeId: 2, agentSwipeId: 1),
      );
      await blocks.insert(
        _block(id: 'kept-block', swipeId: 2, agentSwipeId: 2),
      );

      await db.transaction(() async {
        await snapshots.deleteAnchor(
          sessionId: 's1',
          messageId: 'm1',
          swipeId: 2,
          agentSwipeId: 1,
        );
        await snapshots.shiftAgentSwipeIdsAfterRemoval(
          sessionId: 's1',
          messageId: 'm1',
          swipeId: 2,
          removedAgentSwipeId: 1,
        );
        await facts.deleteAgentSwipeAndShift(
          sessionId: 's1',
          messageId: 'm1',
          swipeId: 2,
          removedAgentSwipeId: 1,
        );
        await memory.deleteAgentSwipeAndShift(
          sessionId: 's1',
          messageId: 'm1',
          swipeId: 2,
          removedAgentSwipeId: 1,
        );
        await blocks.deleteAgentSwipeAndShift(
          sessionId: 's1',
          messageId: 'm1',
          swipeId: 2,
          removedAgentSwipeId: 1,
        );
      });

      expect(
        await snapshots.getByAnchor(
          sessionId: 's1',
          messageId: 'm1',
          swipeId: 2,
          agentSwipeId: 1,
        ),
        isNotNull,
      );
      expect(await facts.getById('removed-fact'), isNull);
      expect(
        (await facts.getBySourceAnchor(
          sessionId: 's1',
          messageId: 'm1',
          swipeId: 2,
          agentSwipeId: 1,
        )).single.id,
        'kept-fact',
      );
      final book = await memory.getBySessionId('s1');
      expect(book!.pendingDrafts.single.id, 'kept-draft');
      expect(book.pendingDrafts.single.sourceAgentSwipeId, 1);
      final remainingBlocks = await blocks.getBySessionId('s1');
      expect(remainingBlocks.map((block) => block.id).toSet(), {
        'legacy-block',
        'kept-block',
      });
      expect(
        remainingBlocks
            .firstWhere((block) => block.id == 'legacy-block')
            .agentSwipeId,
        -1,
      );
      expect(
        remainingBlocks
            .firstWhere((block) => block.id == 'kept-block')
            .agentSwipeId,
        1,
      );
    },
  );
}
