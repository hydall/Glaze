import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart' hide ChatSummary;
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_use_manifest_repo.dart';
import 'package:glaze_flutter/core/llm/prompt/exact_lorebook_manifest.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_canon_checkpoint_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/character_session_baseline.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/extensions/models/block_run_status.dart';
import 'package:glaze_flutter/features/extensions/models/info_block.dart';

final _serviceProvider = Provider(ChatSessionService.new);

class _FailingBaselineRepo extends CharacterSessionBaselineRepo {
  const _FailingBaselineRepo(super.db);

  @override
  Future<void> copyForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
    String? characterId,
    String? baselineCardJson,
    String? baselineHash,
  }) => throw StateError('injected branch failure');
}

ChatMessage _message(String id) =>
    ChatMessage(id: id, role: 'assistant', content: id);

CharacterKnowledgeFact _fact(String id, String messageId) =>
    CharacterKnowledgeFact(
      id: id,
      chatSessionId: 'c1_0',
      knowerKey: 'char',
      subjectKey: id,
      factClass: CharacterKnowledgeFactClass.knowledge,
      predicate: 'knows',
      object: id,
      epistemicState: CharacterKnowledgeEpistemicState.confirmed,
      sourceMessageId: messageId,
      sourceSwipeId: 0,
      sourceAgentSwipeId: 0,
    );

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    await container.read(sharedPreferencesProvider.future);
    await container
        .read(characterRepoProvider)
        .put(
          const Character(id: 'c1', name: 'Character', currentSessionIndex: 0),
        );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    ChatSessionService.clearCache();
  });

  test('failure rolls back DB writes and does not copy preferences', () async {
    final current = ChatSession(
      id: 'c1_0',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [_message('m0')],
    );
    await container.read(chatRepoProvider).put(current);
    container.read(personaConnectionsProvider.notifier).state =
        const PersonaConnections(chat: {'c1_0': 'persona'});

    final failing = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        characterSessionBaselineRepoProvider.overrideWithValue(
          _FailingBaselineRepo(db),
        ),
      ],
    );
    addTearDown(failing.dispose);
    await failing.read(sharedPreferencesProvider.future);
    failing.read(personaConnectionsProvider.notifier).state =
        const PersonaConnections(chat: {'c1_0': 'persona'});

    await expectLater(
      failing.read(_serviceProvider).branchSession('c1', current, 0),
      throwsStateError,
    );

    expect(await container.read(chatRepoProvider).getAllSessions(), [current]);
    expect(await container.read(characterRepoProvider).getAll(), hasLength(1));
    expect(
      (await container.read(characterRepoProvider).getById('c1'))!
          .currentSessionIndex,
      0,
    );
    expect(failing.read(personaConnectionsProvider).chat.keys, ['c1_0']);
  });

  test(
    'branch is durable, current, provenance-filtered, and isolated',
    () async {
      final current = ChatSession(
        id: 'c1_0',
        characterId: 'c1',
        sessionIndex: 0,
        messages: [_message('m0'), _message('m1'), _message('m2')],
      );
      final other = ChatSession(
        id: 'c1_1',
        characterId: 'c1',
        sessionIndex: 1,
        messages: [_message('other')],
      );
      await container.read(chatRepoProvider).put(current);
      await container.read(chatRepoProvider).put(other);
      await container
          .read(characterSessionBaselineRepoProvider)
          .ensureBaseline(
            const CharacterSessionBaseline(
              chatSessionId: 'c1_0',
              characterId: 'c1',
              baselineCardJson: '{"name":"baseline"}',
              baselineHash: 'baseline-hash',
              cardUpdatePolicy: CharacterCardUpdatePolicy.pinnedBaseline,
            ),
          );
      await container
          .read(studioConfigRepoProvider)
          .upsert(const StudioConfig(sessionId: 'c1_0', enabled: true));
      await container
          .read(memoryBookRepoProvider)
          .put(
            const MemoryBook(
              id: 'memorybook_c1_0',
              sessionId: 'c1_0',
              settings: MemoryBookSettings(enabled: false, batchSize: 9),
              lastProcessedMessageCount: 3,
              entries: [
                MemoryEntry(id: 'kept', messageIds: ['m0', 'm1']),
                MemoryEntry(id: 'future', messageIds: ['m2']),
                MemoryEntry(id: 'manual-unprovenanced'),
              ],
              pendingDrafts: [
                MemoryDraft(id: 'kept-draft', messageIds: ['m1']),
                MemoryDraft(id: 'future-draft', messageIds: ['m2']),
              ],
            ),
          );
      final snapshots = container.read(trackerSnapshotRepoProvider);
      await snapshots.upsert(
        const TrackerSnapshot(
          sessionId: 'c1_0',
          messageId: 'm1',
          committed: true,
          createdAt: 10,
          trackers: [
            Tracker(sessionId: 'c1_0', name: 'location', value: 'kept'),
          ],
        ),
      );
      await snapshots.upsert(
        const TrackerSnapshot(
          sessionId: 'c1_0',
          messageId: 'm2',
          createdAt: 20,
          trackers: [
            Tracker(sessionId: 'c1_0', name: 'location', value: 'future'),
          ],
        ),
      );
      final facts = container.read(characterKnowledgeFactRepoProvider);
      await facts.insertTentative(_fact('kept-fact', 'm1'));
      await facts.insertTentative(_fact('future-fact', 'm2'));
      await facts.activateAnchor(
        sessionId: 'c1_0',
        messageId: 'm1',
        swipeId: 0,
        agentSwipeId: 0,
      );
      await container
          .read(ledgerReconciliationCheckpointRepoProvider)
          .upsert(
            const LedgerReconciliationCheckpoint(
              sessionId: 'c1_0',
              startMessageId: 'm0',
              endMessageId: 'm1',
              endSwipeId: 0,
              endAgentSwipeId: 0,
              messageIds: ['m0', 'm1'],
              rangeHash: 'retained-range',
            ),
          );
      await db
          .into(db.ledgerReconciliationCleanupJournals)
          .insert(
            LedgerReconciliationCleanupJournalsCompanion.insert(
              sessionId: 'c1_0',
              endpointMessageId: 'm1',
              messageIdsJson: drift.Value(jsonEncode(['m0', 'm1'])),
              beforeImagesJson: drift.Value(
                jsonEncode([
                  {'id': 'kept-fact'},
                  {'id': 'future-fact'},
                ]),
              ),
            ),
          );
      await container
          .read(infoBlocksRepoProvider)
          .insert(
            const InfoBlock(
              id: 'kept-block',
              sessionId: 'c1_0',
              messageId: 'm1',
              blockId: 'block',
              blockName: 'Block',
              blockType: 'text',
              content: 'kept',
              createdAt: 1,
            ),
          );
      await container
          .read(infoBlocksRepoProvider)
          .insert(
            const InfoBlock(
              id: 'running-block',
              sessionId: 'c1_0',
              messageId: 'm1',
              blockId: 'block',
              blockName: 'Block',
              blockType: 'text',
              content: 'partial',
              createdAt: 2,
              status: BlockRunStatus.running,
            ),
          );
      await container
          .read(infoBlocksRepoProvider)
          .insert(
            const InfoBlock(
              id: 'future-block',
              sessionId: 'c1_0',
              messageId: 'm2',
              blockId: 'block',
              blockName: 'Block',
              blockType: 'text',
              content: 'future',
              createdAt: 3,
            ),
          );
      await container
          .read(summaryRepoProvider)
          .put(
            sessionId: 'c1_0',
            content: 'future generated summary',
            messageCount: 3,
            enabled: false,
            prompt: 'custom prompt',
          );
      await db.customStatement(
        "INSERT INTO memory_cadence_rows "
        "(chat_session_id, assistant_messages_since_last_run) VALUES "
        "('c1_0', 7)",
      );
      await db.customStatement(
        "INSERT INTO embeddings (entry_id, source_type, source_id) VALUES "
        "('kept', 'memory_entry', 'c1_0')",
      );

      container.read(personaConnectionsProvider.notifier).state =
          const PersonaConnections(chat: {'c1_0': 'persona'});
      container.read(presetConnectionsProvider.notifier).state =
          const PresetConnections(chat: {'c1_0': 'preset'});

      final branch = await container
          .read(_serviceProvider)
          .branchSession('c1', current, 1);

      // No rewrite ran in the source session, so the branch keeps its card
      // and is just the character's next session.
      expect(branch.characterId, 'c1');
      expect(branch.id, 'c1_2');
      expect(branch.sessionIndex, 2);
      expect(
        await container.read(characterRepoProvider).getAll(),
        hasLength(1),
      );
      expect(
        await container
            .read(characterRevisionRepoProvider)
            .getForCharacter('c1'),
        isEmpty,
      );
      expect(
        await container
            .read(sessionCanonCheckpointRepoProvider)
            .getForSession(branch.id),
        isEmpty,
      );
      expect(branch.messages.map((message) => message.id), ['m0', 'm1']);
      expect(
        (await container.read(chatRepoProvider).getById(branch.id))?.id,
        branch.id,
      );
      expect(
        (await container.read(characterRepoProvider).getById('c1'))!
            .currentSessionIndex,
        2,
      );
      expect(
        (await container.read(chatRepoProvider).getById('c1_1'))!
            .messages
            .single
            .id,
        'other',
      );

      final baseline = await container
          .read(characterSessionBaselineRepoProvider)
          .getBySessionId(branch.id);
      expect(baseline?.baselineHash, 'baseline-hash');
      expect(baseline?.baselineCardJson, '{"name":"baseline"}');
      expect(baseline?.characterId, 'c1');
      expect(
        baseline?.cardUpdatePolicy,
        CharacterCardUpdatePolicy.pinnedBaseline,
      );
      final studio = await container
          .read(studioConfigRepoProvider)
          .getBySessionId(branch.id);
      expect(studio?.enabled, isTrue);
      expect(studio?.sessionId, branch.id);

      final memory = await container
          .read(memoryBookRepoProvider)
          .getBySessionId(branch.id);
      expect(memory?.entries.map((entry) => entry.id), ['kept@${branch.id}']);
      expect(memory?.pendingDrafts.map((draft) => draft.id), [
        'kept-draft@${branch.id}',
      ]);
      expect(memory?.settings.enabled, isFalse);
      expect(memory?.settings.batchSize, 9);
      expect(memory?.lastProcessedMessageCount, 0);

      expect(
        (await snapshots.getBySessionId(
          branch.id,
        )).map((item) => item.messageId),
        ['m1'],
      );
      expect(
        (await container.read(trackerRepoProvider).get(branch.id, 'location'))
            ?.value,
        'kept',
      );
      expect(
        (await container.read(trackerRepoProvider).get(branch.id, 'location'))
            ?.sessionId,
        branch.id,
      );
      expect(
        (await facts.getReviewableForSession(branch.id)).map((fact) => fact.id),
        ['kept-fact@${branch.id}'],
      );
      final checkpoint = await container
          .read(ledgerReconciliationCheckpointRepoProvider)
          .get(branch.id);
      expect(checkpoint?.rangeHash, 'retained-range');
      final journals = await (db.select(
        db.ledgerReconciliationCleanupJournals,
      )..where((row) => row.sessionId.equals(branch.id))).get();
      expect(journals, hasLength(1));
      expect(
        journals.single.beforeImagesJson,
        contains('kept-fact@${branch.id}'),
      );
      expect(journals.single.beforeImagesJson, isNot(contains('future-fact')));
      expect(
        (await container.read(infoBlocksRepoProvider).getBySessionId(branch.id))
            .map((block) => block.content),
        ['kept'],
      );
      final summary = await container.read(summaryRepoProvider).get(branch.id);
      expect(summary?.content, isEmpty);
      expect(summary?.messageCount, 0);
      expect(summary?.enabled, isFalse);
      expect(summary?.prompt, 'custom prompt');

      final cadence = await (db.select(
        db.memoryCadenceRows,
      )..where((row) => row.chatSessionId.equals(branch.id))).get();
      final branchEmbeddings = await (db.select(
        db.embeddings,
      )..where((row) => row.sourceId.equals(branch.id))).get();
      expect(cadence, isEmpty);
      expect(branchEmbeddings, isEmpty);
      expect(
        container.read(personaConnectionsProvider).chat[branch.id],
        'persona',
      );
      expect(
        container.read(presetConnectionsProvider).chat[branch.id],
        'preset',
      );
    },
  );

  test('branch fails closed and retains no lorebook provenance', () async {
    final current = ChatSession(
      id: 'c1_0',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [
        _message('m0'),
        _message('m1').copyWith(role: 'user', swipes: const ['one', 'two']),
        _message('m2'),
      ],
    );
    await container.read(chatRepoProvider).put(current);
    final manifests = container.read(lorebookUseManifestRepoProvider);
    Future<void> seed(String messageId, int swipeId) {
      final durable = _durableManifest('$messageId-$swipeId');
      return manifests.insertGenerationManifest(
        identity: LorebookUseGenerationIdentity(
          sessionId: 'c1_0',
          messageId: messageId,
          swipeId: swipeId,
          agentSwipeId: 0,
        ),
        manifest: LorebookUseManifestInput(
          manifestJson: durable.canonicalJson,
          manifestHash: durable.canonicalHash,
          manifestSchemaVersion: 1,
          finalPromptHash: durable.providerMessagesHash,
          presetSnapshotHash: durable.promptProvenance.presetSnapshotHash,
        ),
        createdAt: 10 + swipeId,
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

    await seed('m0', 0);
    await seed('m1', 0);
    await seed('m1', 1);
    await seed('m2', 0);
    await manifests.insertVariationAcceptance(
      acceptanceId: 'kept',
      identity: const LorebookUseGenerationIdentity(
        sessionId: 'c1_0',
        messageId: 'm0',
        swipeId: 0,
        agentSwipeId: 0,
      ),
      acceptedByUserMessageId: 'm1',
      acceptedAt: 20,
    );
    await manifests.insertVariationAcceptance(
      acceptanceId: 'excluded',
      identity: const LorebookUseGenerationIdentity(
        sessionId: 'c1_0',
        messageId: 'm1',
        swipeId: 0,
        agentSwipeId: 0,
      ),
      acceptedByUserMessageId: 'm2',
      acceptedAt: 21,
    );

    final branch = await container
        .read(_serviceProvider)
        .branchSession('c1', current, 1);

    final branchManifests = await (db.select(
      db.lorebookUseManifests,
    )..where((row) => row.sessionId.equals(branch.id))).get();
    expect(branchManifests, isEmpty);
    expect(await manifests.getVariationAcceptances(branch.id), isEmpty);
    final sourceManifests = await (db.select(
      db.lorebookUseManifests,
    )..where((row) => row.sessionId.equals('c1_0'))).get();
    expect(sourceManifests, hasLength(4));
    expect(await manifests.getVariationAcceptances('c1_0'), hasLength(2));
  });

  test('branch forks the card for a session-owned variant', () async {
    await container
        .read(characterRepoProvider)
        .put(
          const Character(
            id: 'c1',
            name: 'Character',
            currentSessionIndex: 0,
            variantGroupId: 'group',
            variantName: 'Session 1',
            variantOrder: 1,
          ),
        );
    final current = ChatSession(
      id: 'c1_0',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [_message('m0'), _message('m1')],
    );
    await container.read(chatRepoProvider).put(current);

    final branch = await container
        .read(_serviceProvider)
        .branchSession('c1', current, 0);

    // The variant is the source session's own card: a shared one would let a
    // rewrite in the branch edit the card the source session is still using.
    expect(branch.characterId, isNot('c1'));
    expect(branch.id, '${branch.characterId}_0');
    final forked = await container
        .read(characterRepoProvider)
        .getById(branch.characterId);
    expect(forked?.variantGroupId, 'group');
    expect(forked?.variantOrder, 2);
    expect(
      (await container
              .read(sessionCanonCheckpointRepoProvider)
              .getForSession(branch.id))
          .single
          .sequence,
      0,
    );
  });

  test('branch forks the card for an evolved lorebook entry', () async {
    final current = ChatSession(
      id: 'c1_0',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [_message('m0'), _message('m1')],
    );
    await container.read(chatRepoProvider).put(current);
    await db
        .into(db.sessionLorebookEvolutionRows)
        .insert(
          SessionLorebookEvolutionRowsCompanion.insert(
            chatSessionId: current.id,
            lorebookId: 'book',
            entryId: 'entry',
            baseContent: 'base',
            baseContentHash: CardCanonicalizer.scalarSha256('base'),
            content: 'evolved',
            contentHash: CardCanonicalizer.scalarSha256('evolved'),
            createdAt: 1,
            updatedAt: 2,
          ),
        );

    final branch = await container
        .read(_serviceProvider)
        .branchSession('c1', current, 0);

    expect(branch.characterId, isNot('c1'));
    final overlay = await container
        .read(sessionLorebookEvolutionRepoProvider)
        .getByTarget(
          sessionId: branch.id,
          lorebookId: 'book',
          entryId: 'entry',
        );
    expect(overlay?.content, 'evolved');
  });

  test('branch roots card and lore at latest surviving checkpoint', () async {
    final revision0 = const Character(
      id: 'c1',
      name: 'Character',
      description: 'root',
      avatarPath: 'shared.png',
      currentSessionIndex: 0,
    );
    final revision1 = revision0.copyWith(description: 'after checkpoint 1');
    final revision2 = revision0.copyWith(description: 'after checkpoint 2');
    await container.read(characterRepoProvider).put(revision2);
    final revisions = container.read(characterRevisionRepoProvider);
    Future<void> insertRevision(Character character, int revision) =>
        revisions.insert(
          CharacterRevisionRecord(
            characterId: 'c1',
            revision: revision,
            revisionHash: CardCanonicalizer.sha256(character),
            parentRevisionHash: revision == 1
                ? ''
                : CardCanonicalizer.sha256(
                    revision == 2 ? revision0 : revision1,
                  ),
            snapshotJson: jsonEncode(character.toJson()),
            createdAt: revision,
          ),
        );
    await insertRevision(revision0, 1);
    await insertRevision(revision1, 2);
    await insertRevision(revision2, 3);

    final current = ChatSession(
      id: 'c1_0',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [
        _message('m0'),
        _message('m1').copyWith(role: 'user'),
        _message('m2'),
        _message('m3').copyWith(role: 'user'),
      ],
    );
    await container.read(chatRepoProvider).put(current);
    final checkpoints = container.read(sessionCanonCheckpointRepoProvider);
    final root = await checkpoints.appendRootInTransaction(
      sessionId: current.id,
      characterId: 'c1',
      characterRevision: 1,
      characterRevisionHash: CardCanonicalizer.sha256(revision0),
    );
    final checkpoint1 = await checkpoints.appendInTransaction(
      sessionId: current.id,
      expectedParentCheckpointId: root.id,
      characterId: 'c1',
      characterRevision: 2,
      characterRevisionHash: CardCanonicalizer.sha256(revision1),
      rewriteJobId: 'job-1',
      anchor: const SessionCanonCheckpointAnchor(
        messageId: 'm0',
        swipeId: 0,
        agentSwipeId: 0,
      ),
    );
    final checkpoint2 = await checkpoints.appendInTransaction(
      sessionId: current.id,
      expectedParentCheckpointId: checkpoint1.id,
      characterId: 'c1',
      characterRevision: 3,
      characterRevisionHash: CardCanonicalizer.sha256(revision2),
      rewriteJobId: 'job-2',
      anchor: const SessionCanonCheckpointAnchor(
        messageId: 'm2',
        swipeId: 0,
        agentSwipeId: 0,
      ),
    );
    final lore1Hash = CardCanonicalizer.scalarSha256('lore one');
    final lore2Hash = CardCanonicalizer.scalarSha256('lore two');
    final loreHistory = container.read(sessionLorebookRevisionRepoProvider);
    await loreHistory.appendInTransaction(
      checkpointId: checkpoint1.id,
      sessionId: current.id,
      lorebookId: 'book',
      entryId: 'entry',
      baseContentHash: CardCanonicalizer.scalarSha256('base'),
      expectedPreviousContentHash: CardCanonicalizer.scalarSha256('base'),
      content: 'lore one',
      contentHash: lore1Hash,
      rewriteOperationId: 'lore-op-1',
    );
    await loreHistory.appendInTransaction(
      checkpointId: checkpoint2.id,
      sessionId: current.id,
      lorebookId: 'book',
      entryId: 'entry',
      baseContentHash: CardCanonicalizer.scalarSha256('base'),
      expectedPreviousContentHash: lore1Hash,
      content: 'lore two',
      contentHash: lore2Hash,
      rewriteOperationId: 'lore-op-2',
    );
    await db
        .into(db.sessionLorebookEvolutionRows)
        .insert(
          SessionLorebookEvolutionRowsCompanion.insert(
            chatSessionId: current.id,
            lorebookId: 'book',
            entryId: 'entry',
            baseContent: 'base',
            baseContentHash: CardCanonicalizer.scalarSha256('base'),
            content: 'lore two',
            contentHash: lore2Hash,
            createdAt: 1,
            updatedAt: 2,
          ),
        );

    final branch = await container
        .read(_serviceProvider)
        .branchSession('c1', current, 1);

    final branchCharacter = await container
        .read(characterRepoProvider)
        .getById(branch.characterId);
    expect(branchCharacter?.description, 'after checkpoint 1');
    expect(branchCharacter?.avatarPath, 'shared.png');
    expect(branchCharacter?.gallery, isEmpty);
    expect(branchCharacter?.fav, isFalse);
    expect(branchCharacter?.currentSessionIndex, 0);
    expect(branch.sessionIndex, 0);
    expect(branch.messages.map((message) => message.id), ['m0', 'm1']);

    final branchRevisions = await revisions.getForCharacter(branch.characterId);
    expect(branchRevisions, hasLength(1));
    expect(branchRevisions.single.revision, 1);
    final branchCheckpoints = await checkpoints.getForSession(branch.id);
    expect(branchCheckpoints, hasLength(1));
    expect(branchCheckpoints.single.sequence, 0);
    expect(branchCheckpoints.single.characterId, branch.characterId);
    final overlay = await container
        .read(sessionLorebookEvolutionRepoProvider)
        .getByTarget(
          sessionId: branch.id,
          lorebookId: 'book',
          entryId: 'entry',
        );
    expect(overlay?.content, 'lore one');
    final branchHistory = await loreHistory.getForSession(branch.id);
    expect(branchHistory.single.checkpointId, branchCheckpoints.single.id);
    expect(branchHistory.single.content, 'lore one');
    final jobs = await (db.select(
      db.sessionLorebookEmbeddingJobRows,
    )..where((row) => row.chatSessionId.equals(branch.id))).get();
    expect(jobs, hasLength(1));
    expect(jobs.single.status, 'pending');
    expect(jobs.single.expectedContentHash, lore1Hash);

    expect(
      (await container.read(characterRepoProvider).getById('c1'))?.description,
      'after checkpoint 2',
    );
    expect(await container.read(chatRepoProvider).getById('c1_0'), current);
    expect(await checkpoints.getForSession('c1_0'), hasLength(3));
  });
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
