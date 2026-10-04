import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_use_manifest_repo.dart';
import 'package:glaze_flutter/core/llm/prompt/exact_lorebook_manifest.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/chat_message_service.dart';
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

final _messageServiceProvider = Provider(ChatMessageService.new);

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

  test(
    'manifest provenance fails closed for green and blue index shifts',
    () async {
      final repo = LorebookUseManifestRepo(db);
      Future<void> seed(int swipeId, int agentSwipeId) {
        final durable = _durableManifest('$swipeId-$agentSwipeId');
        return repo.insertGenerationManifest(
          identity: LorebookUseGenerationIdentity(
            sessionId: 's1',
            messageId: 'm1',
            swipeId: swipeId,
            agentSwipeId: agentSwipeId,
          ),
          manifest: LorebookUseManifestInput(
            manifestJson: durable.canonicalJson,
            manifestHash: durable.canonicalHash,
            manifestSchemaVersion: 1,
            finalPromptHash: durable.providerMessagesHash,
            presetSnapshotHash: durable.promptProvenance.presetSnapshotHash,
          ),
          createdAt: 1,
          entries: [
            LorebookUseManifestEntryInput(
              lorebookId: durable.entries.single.lorebookId,
              entryId: durable.entries.single.entryId,
              entryOrder: 0,
              evidenceJson: jsonEncode(durable.entries.single.toJson()),
            ),
          ],
        );
      }

      await seed(0, 0);
      await seed(1, 0);
      await seed(1, 1);
      await repo.insertVariationAcceptance(
        acceptanceId: 'shifted',
        identity: const LorebookUseGenerationIdentity(
          sessionId: 's1',
          messageId: 'm1',
          swipeId: 1,
          agentSwipeId: 1,
        ),
        acceptedByUserMessageId: 'u1',
        acceptedAt: 2,
      );

      final green = ChatSession(
        id: 's1',
        characterId: 'char',
        sessionIndex: 0,
        messages: [
          ChatMessage(
            id: 'm1',
            role: 'assistant',
            content: 'one',
            swipes: const ['one', 'two'],
            swipeId: 0,
            swipesMeta: [
              {
                'agentSwipes': [const AgentSwipe(content: 'one').toJson()],
              },
              {
                'agentSwipes': [
                  const AgentSwipe(content: 'two').toJson(),
                  const AgentSwipe(content: 'two clean').toJson(),
                ],
              },
            ],
          ),
        ],
      );
      await container.read(chatRepoProvider).put(green);
      await container.read(_messageServiceProvider).deleteActiveSwipe(green, 0);
      expect(await repo.getVariationAcceptances('s1'), isEmpty);
      final greenRows = await (db.select(
        db.lorebookUseManifests,
      )..where((row) => row.sessionId.equals('s1'))).get();
      expect(greenRows, isEmpty);

      await seed(0, 0);
      await seed(0, 1);
      final blue = ChatSession(
        id: 's1',
        characterId: 'char',
        sessionIndex: 0,
        messages: [
          ChatMessage(
            id: 'm1',
            role: 'assistant',
            content: 'one',
            swipes: const ['one'],
            agentSwipes: const [
              AgentSwipe(content: 'one'),
              AgentSwipe(content: 'clean'),
            ],
            agentSwipeId: 0,
            swipesMeta: [
              {
                'agentSwipes': [
                  const AgentSwipe(content: 'one').toJson(),
                  const AgentSwipe(content: 'clean').toJson(),
                ],
              },
            ],
          ),
        ],
      );
      await container.read(chatRepoProvider).put(blue);
      await container
          .read(_messageServiceProvider)
          .deleteActiveAgentSwipe(blue, 0);
      final blueRows = await (db.select(
        db.lorebookUseManifests,
      )..where((row) => row.sessionId.equals('s1'))).get();
      expect(blueRows, isEmpty);
    },
  );

  test(
    'ordinary message deletion removes all invalidated manifest provenance',
    () async {
      final manifests = container.read(lorebookUseManifestRepoProvider);
      Future<void> seed(String messageId) async {
        final durable = _durableManifest(messageId);
        final identity = LorebookUseGenerationIdentity(
          sessionId: 's1',
          messageId: messageId,
          swipeId: 0,
          agentSwipeId: 0,
        );
        await manifests.insertGenerationManifest(
          identity: identity,
          manifest: LorebookUseManifestInput(
            manifestJson: durable.canonicalJson,
            manifestHash: durable.canonicalHash,
            manifestSchemaVersion: 1,
            finalPromptHash: durable.providerMessagesHash,
            presetSnapshotHash: durable.promptProvenance.presetSnapshotHash,
          ),
          createdAt: 1,
          entries: [
            LorebookUseManifestEntryInput(
              lorebookId: durable.entries.single.lorebookId,
              entryId: durable.entries.single.entryId,
              entryOrder: 0,
              evidenceJson: jsonEncode(durable.entries.single.toJson()),
            ),
          ],
        );
        await manifests.insertVariationAcceptance(
          acceptanceId: 'accept-$messageId',
          identity: identity,
          acceptedByUserMessageId: 'user-$messageId',
          acceptedAt: 2,
        );
      }

      final session = ChatSession(
        id: 's1',
        characterId: 'char',
        sessionIndex: 0,
        messages: const [
          ChatMessage(id: 'm0', role: 'user', content: 'zero'),
          ChatMessage(id: 'm1', role: 'assistant', content: 'one'),
          ChatMessage(id: 'm2', role: 'user', content: 'two'),
        ],
      );
      await container.read(chatRepoProvider).put(session);
      await seed('m0');
      await seed('m1');
      await seed('m2');

      await container.read(_messageServiceProvider).deleteMessage(session, 1);

      final remaining = await (db.select(
        db.lorebookUseManifests,
      )..where((row) => row.sessionId.equals('s1'))).get();
      expect(remaining.map((row) => row.messageId), ['m0']);
      final acceptances = await manifests.getVariationAcceptances('s1');
      expect(acceptances, hasLength(1));
      expect(acceptances.single.messageId, 'm0');
      final entries = await (db.select(
        db.lorebookUseManifestEntries,
      )..where((row) => row.sessionId.equals('s1'))).get();
      expect(entries.map((row) => row.messageId), ['m0']);
    },
  );

  test(
    'deleting an accepting user message retracts prefix acceptance only',
    () async {
      final manifests = container.read(lorebookUseManifestRepoProvider);
      final durable = _durableManifest('assistant-a');
      const identity = LorebookUseGenerationIdentity(
        sessionId: 's1',
        messageId: 'a',
        swipeId: 0,
        agentSwipeId: 0,
      );
      await manifests.insertGenerationManifest(
        identity: identity,
        manifest: LorebookUseManifestInput(
          manifestJson: durable.canonicalJson,
          manifestHash: durable.canonicalHash,
          manifestSchemaVersion: 1,
          finalPromptHash: durable.providerMessagesHash,
          presetSnapshotHash: durable.promptProvenance.presetSnapshotHash,
        ),
        createdAt: 1,
        entries: [
          LorebookUseManifestEntryInput(
            lorebookId: durable.entries.single.lorebookId,
            entryId: durable.entries.single.entryId,
            entryOrder: 0,
            evidenceJson: jsonEncode(durable.entries.single.toJson()),
          ),
        ],
      );
      await manifests.insertVariationAcceptance(
        acceptanceId: 'accepted-by-u',
        identity: identity,
        acceptedByUserMessageId: 'u',
        acceptedAt: 2,
      );
      const session = ChatSession(
        id: 's1',
        characterId: 'char',
        sessionIndex: 0,
        messages: [
          ChatMessage(id: 'a', role: 'assistant', content: 'answer'),
          ChatMessage(id: 'u', role: 'user', content: 'follow-up'),
        ],
      );
      await container.read(chatRepoProvider).put(session);

      await container.read(_messageServiceProvider).deleteMessage(session, 1);

      expect(await manifests.getVariationAcceptances('s1'), isEmpty);
      final rows = await (db.select(
        db.lorebookUseManifests,
      )..where((row) => row.sessionId.equals('s1'))).get();
      expect(rows, hasLength(1));
      expect(rows.single.messageId, 'a');
    },
  );
}

ExactLorebookManifest _durableManifest(String id) => ExactLorebookManifest(
  entries: [
    ExactLorebookManifestEntry.fromMergedEntry(
      entry: LorebookEntry(
        id: 'entry-$id',
        lorebookId: 'book-$id',
        content: 'lore-$id',
        position: 'worldInfoBefore',
        order: 0,
      ),
      source: 'keyword',
      classification: 'worldInfoBefore',
      injectionIndex: 0,
      renderedContent: 'rendered-$id',
    ),
  ],
  promptProvenance: const ExactLorebookPromptProvenance(
    characterId: 'character',
    presetSnapshotHash: 'preset',
  ),
  providerMessagesHash: 'prompt',
);
