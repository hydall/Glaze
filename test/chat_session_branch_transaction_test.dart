import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart' hide ChatSummary;
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/character_session_baseline.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
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

    expect(await container.read(chatRepoProvider).getById('c1_1'), isNull);
    expect(
      (await container.read(characterRepoProvider).getById('c1'))!
          .currentSessionIndex,
      0,
    );
    expect(
      failing.read(personaConnectionsProvider).chat.containsKey('c1_1'),
      isFalse,
    );
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
          .upsert(
            const StudioConfig(
              sessionId: 'c1_0',
              profileId: 'c1_0',
              enabled: true,
              finalPresetId: 'studio-preset',
            ),
          );
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

      expect(branch.id, 'c1_2');
      expect(branch.messages.map((message) => message.id), ['m0', 'm1']);
      expect(
        (await container.read(chatRepoProvider).getById('c1_2'))?.id,
        'c1_2',
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
          .getBySessionId('c1_2');
      expect(baseline?.baselineHash, 'baseline-hash');
      expect(
        baseline?.cardUpdatePolicy,
        CharacterCardUpdatePolicy.pinnedBaseline,
      );
      final studio = await container
          .read(studioConfigRepoProvider)
          .getBySessionId('c1_2');
      expect(studio?.enabled, isTrue);
      expect(studio?.finalPresetId, 'studio-preset');

      final memory = await container
          .read(memoryBookRepoProvider)
          .getBySessionId('c1_2');
      expect(memory?.entries.map((entry) => entry.id), ['kept@c1_2']);
      expect(memory?.pendingDrafts.map((draft) => draft.id), [
        'kept-draft@c1_2',
      ]);
      expect(memory?.settings.enabled, isFalse);
      expect(memory?.settings.batchSize, 9);
      expect(memory?.lastProcessedMessageCount, 0);

      expect(
        (await snapshots.getBySessionId('c1_2')).map((item) => item.messageId),
        ['m1'],
      );
      expect(
        (await container.read(trackerRepoProvider).get('c1_2', 'location'))
            ?.value,
        'kept',
      );
      expect(
        (await container.read(trackerRepoProvider).get('c1_2', 'location'))
            ?.sessionId,
        'c1_2',
      );
      expect(
        (await facts.getReviewableForSession('c1_2')).map((fact) => fact.id),
        ['kept-fact@c1_2'],
      );
      final checkpoint = await container
          .read(ledgerReconciliationCheckpointRepoProvider)
          .get('c1_2');
      expect(checkpoint?.rangeHash, 'retained-range');
      final journals = await (db.select(
        db.ledgerReconciliationCleanupJournals,
      )..where((row) => row.sessionId.equals('c1_2'))).get();
      expect(journals, hasLength(1));
      expect(journals.single.beforeImagesJson, contains('kept-fact@c1_2'));
      expect(journals.single.beforeImagesJson, isNot(contains('future-fact')));
      expect(
        (await container.read(infoBlocksRepoProvider).getBySessionId('c1_2'))
            .map((block) => block.content),
        ['kept'],
      );
      final summary = await container.read(summaryRepoProvider).get('c1_2');
      expect(summary?.content, isEmpty);
      expect(summary?.messageCount, 0);
      expect(summary?.enabled, isFalse);
      expect(summary?.prompt, 'custom prompt');

      final cadence = await db
          .customSelect(
            "SELECT * FROM memory_cadence_rows WHERE chat_session_id = 'c1_2'",
          )
          .get();
      final branchEmbeddings = await db
          .customSelect("SELECT * FROM embeddings WHERE entry_id LIKE '%@c1_2'")
          .get();
      expect(cadence, isEmpty);
      expect(branchEmbeddings, isEmpty);
      expect(
        container.read(personaConnectionsProvider).chat['c1_2'],
        'persona',
      );
      expect(container.read(presetConnectionsProvider).chat['c1_2'], 'preset');
    },
  );
}
