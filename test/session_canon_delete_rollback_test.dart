import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_canon_checkpoint_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_message_service.dart';

final _serviceProvider = Provider(ChatMessageService.new);

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

  Future<void> revision(Character card, int revision, String parentHash) =>
      container
          .read(characterRevisionRepoProvider)
          .insert(
            CharacterRevisionRecord(
              characterId: card.id,
              revision: revision,
              revisionHash: CardCanonicalizer.sha256(card),
              parentRevisionHash: parentHash,
              snapshotJson: jsonEncode(card.toJson()),
              createdAt: revision,
            ),
          );

  Future<void> seedAppliedOperation(
    String jobId,
    String operationId,
    String transitionId,
    int revision,
  ) async {
    await db
        .into(db.rewriteJobs)
        .insert(
          RewriteJobsCompanion.insert(
            id: jobId,
            chatSessionId: 's1',
            characterId: 'c1',
            status: const Value('applied'),
          ),
        );
    await db
        .into(db.rewriteOperations)
        .insert(
          RewriteOperationsCompanion.insert(
            id: operationId,
            rewriteJobId: jobId,
            chatSessionId: 's1',
            status: const Value('applied'),
          ),
        );
    await db
        .into(db.appliedCanonTransitionRows)
        .insert(
          AppliedCanonTransitionRowsCompanion.insert(
            id: transitionId,
            chatSessionId: const Value('s1'),
            characterId: 'c1',
            rewriteOperationId: Value(operationId),
            revision: Value(revision),
            revisionHash: const Value('hash'),
            transitionJson: '{}',
          ),
        );
    await db
        .into(db.canonTransitionFactRefs)
        .insert(
          CanonTransitionFactRefsCompanion.insert(
            appliedCanonTransitionId: transitionId,
            characterKnowledgeFactId: 'fact-$revision',
          ),
        );
  }

  test('deleting checkpoint 2 restores checkpoint 1 canon', () async {
    final rootCard = _card('root').copyWith(
      name: 'Historical variation',
      avatarPath: 'historical.png',
      variantName: 'Historical',
      variantOrder: 1,
    );
    final card1 = rootCard.copyWith(description: 'card one');
    final card2 = _card('card two');
    await container.read(characterRepoProvider).put(card2);
    await revision(rootCard, 1, '');
    await revision(card1, 2, CardCanonicalizer.sha256(rootCard));
    await revision(card2, 3, CardCanonicalizer.sha256(card1));

    final session = _session();
    await container.read(chatRepoProvider).put(session);
    final checkpoints = container.read(sessionCanonCheckpointRepoProvider);
    final root = await checkpoints.appendRootInTransaction(
      sessionId: session.id,
      characterId: 'c1',
      characterRevision: 1,
      characterRevisionHash: CardCanonicalizer.sha256(rootCard),
    );
    final checkpoint1 = await checkpoints.appendInTransaction(
      sessionId: session.id,
      expectedParentCheckpointId: root.id,
      characterId: 'c1',
      characterRevision: 2,
      characterRevisionHash: CardCanonicalizer.sha256(card1),
      rewriteJobId: 'job-1',
      anchor: const SessionCanonCheckpointAnchor(
        messageId: 'm1',
        swipeId: 1,
        agentSwipeId: 2,
      ),
    );
    final checkpoint2 = await checkpoints.appendInTransaction(
      sessionId: session.id,
      expectedParentCheckpointId: checkpoint1.id,
      characterId: 'c1',
      characterRevision: 3,
      characterRevisionHash: CardCanonicalizer.sha256(card2),
      rewriteJobId: 'job-2',
      anchor: const SessionCanonCheckpointAnchor(
        messageId: 'm2',
        swipeId: 3,
        agentSwipeId: 4,
      ),
    );
    await seedAppliedOperation('job-1', 'op-1', 'transition-1', 2);
    await seedAppliedOperation('job-2', 'op-2', 'transition-2', 3);

    final baseHash = CardCanonicalizer.scalarSha256('base');
    final lore1Hash = CardCanonicalizer.scalarSha256('lore one');
    final lore2Hash = CardCanonicalizer.scalarSha256('lore two');
    final history = container.read(sessionLorebookRevisionRepoProvider);
    await history.appendInTransaction(
      checkpointId: checkpoint1.id,
      sessionId: session.id,
      lorebookId: 'book',
      entryId: 'entry',
      baseContentHash: baseHash,
      expectedPreviousContentHash: baseHash,
      content: 'lore one',
      contentHash: lore1Hash,
      rewriteOperationId: 'lore-op-1',
    );
    await history.appendInTransaction(
      checkpointId: checkpoint2.id,
      sessionId: session.id,
      lorebookId: 'book',
      entryId: 'entry',
      baseContentHash: baseHash,
      expectedPreviousContentHash: lore1Hash,
      content: 'lore two',
      contentHash: lore2Hash,
      rewriteOperationId: 'lore-op-2',
    );
    await db
        .into(db.sessionLorebookEvolutionRows)
        .insert(
          SessionLorebookEvolutionRowsCompanion.insert(
            chatSessionId: session.id,
            lorebookId: 'book',
            entryId: 'entry',
            baseContent: 'base',
            baseContentHash: baseHash,
            content: 'lore two',
            contentHash: lore2Hash,
            createdAt: 1,
            updatedAt: 2,
          ),
        );

    final service = container.read(_serviceProvider);
    final plan = service.planDeleteMessages(session, {2})!;
    await service.commitDeleteMessages(session, plan);

    final character = await container.read(characterRepoProvider).getById('c1');
    expect(character?.description, 'card one');
    expect(character?.name, 'Current variation');
    expect(character?.avatarPath, 'current.png');
    expect(character?.variantName, 'Current');
    expect(character?.variantOrder, 7);
    final revisions = await container
        .read(characterRevisionRepoProvider)
        .getForCharacter('c1');
    expect(revisions, hasLength(4));
    expect(revisions.last.revisionHash, CardCanonicalizer.sha256(character!));

    final timeline = await checkpoints.getForSession(session.id);
    expect(timeline, hasLength(4));
    expect(timeline.last.parentCheckpointId, checkpoint2.id);
    expect(timeline.last.rewriteJobId, startsWith('canon-rollback:'));
    expect(timeline.last.characterRevision, 4);

    final overlay = await container
        .read(sessionLorebookEvolutionRepoProvider)
        .getByTarget(
          sessionId: session.id,
          lorebookId: 'book',
          entryId: 'entry',
        );
    expect(overlay?.content, 'lore one');
    final loreHistory = await history.getForSession(session.id);
    expect(loreHistory, hasLength(3));
    expect(loreHistory.last.checkpointId, timeline.last.id);
    expect(loreHistory.last.previousContentHash, lore2Hash);
    expect(loreHistory.last.contentHash, lore1Hash);

    final transitions = await db.select(db.appliedCanonTransitionRows).get();
    expect(transitions.map((row) => row.id), ['transition-1']);
    final refs = await db.select(db.canonTransitionFactRefs).get();
    expect(refs.map((row) => row.appliedCanonTransitionId), ['transition-1']);
    final jobs = await db.select(db.sessionLorebookEmbeddingJobRows).get();
    expect(jobs, hasLength(1));
    expect(jobs.single.status, 'pending');
    expect(jobs.single.expectedContentHash, lore1Hash);

    final afterFirstRollback = await container
        .read(chatRepoProvider)
        .getById(session.id);
    final secondPlan = service.planDeleteMessages(afterFirstRollback!, {1})!;
    await service.commitDeleteMessages(afterFirstRollback, secondPlan);

    final rootRestored = await container
        .read(characterRepoProvider)
        .getById('c1');
    expect(rootRestored?.description, 'root');
    final repeatedTimeline = await checkpoints.getForSession(session.id);
    expect(repeatedTimeline, hasLength(5));
    expect(repeatedTimeline.last.parentCheckpointId, timeline.last.id);
    expect(repeatedTimeline.last.anchorMessageId, 'canon-rollback-root:s1');
    expect(repeatedTimeline.last.characterRevision, 5);
    final baseOverlay = await container
        .read(sessionLorebookEvolutionRepoProvider)
        .getByTarget(
          sessionId: session.id,
          lorebookId: 'book',
          entryId: 'entry',
        );
    expect(baseOverlay?.content, 'base');
    expect(await db.select(db.appliedCanonTransitionRows).get(), isEmpty);
    final repeatedHistory = await history.getForSession(session.id);
    expect(repeatedHistory, hasLength(4));
    expect(repeatedHistory.last.previousContentHash, lore1Hash);
    expect(repeatedHistory.last.contentHash, baseHash);
    final repeatedJobs = await db
        .select(db.sessionLorebookEmbeddingJobRows)
        .get();
    expect(repeatedJobs.where((row) => row.status == 'pending'), hasLength(1));
    expect(
      repeatedJobs
          .singleWhere((row) => row.status == 'pending')
          .expectedContentHash,
      baseHash,
    );
  });

  test('switching away from a checkpoint swipe rolls canon back', () async {
    final rootCard = _card('root');
    final rewritten = rootCard.copyWith(description: 'rewritten');
    await container.read(characterRepoProvider).put(rewritten);
    await revision(rootCard, 1, '');
    await revision(rewritten, 2, CardCanonicalizer.sha256(rootCard));
    final session = _session().copyWith(
      messages: [
        _session().messages.first,
        _session().messages[1].copyWith(
          content: 'accepted',
          swipes: const ['other', 'accepted'],
          swipeId: 1,
        ),
      ],
    );
    await container.read(chatRepoProvider).put(session);
    final checkpoints = container.read(sessionCanonCheckpointRepoProvider);
    final root = await checkpoints.appendRootInTransaction(
      sessionId: session.id,
      characterId: 'c1',
      characterRevision: 1,
      characterRevisionHash: CardCanonicalizer.sha256(rootCard),
    );
    await checkpoints.appendInTransaction(
      sessionId: session.id,
      expectedParentCheckpointId: root.id,
      characterId: 'c1',
      characterRevision: 2,
      characterRevisionHash: CardCanonicalizer.sha256(rewritten),
      rewriteJobId: 'job-1',
      anchor: const SessionCanonCheckpointAnchor(
        messageId: 'm1',
        swipeId: 1,
        agentSwipeId: 2,
      ),
    );

    final service = container.read(_serviceProvider);
    await service.commitMessageMutation(
      session,
      1,
      (latest, index) => service.setSwipe(latest, index, 0),
    );

    final durable = await container.read(chatRepoProvider).getById(session.id);
    expect(durable?.messages[1].swipeId, 0);
    final timeline = await checkpoints.getForSession(session.id);
    expect(timeline, hasLength(3));
    expect(timeline.last.anchorMessageId, 'canon-rollback-root:s1');
    final card = await container.read(characterRepoProvider).getById('c1');
    expect(card?.description, 'root');
  });

  test('deletion that preserves latest checkpoint is a canon no-op', () async {
    final card = _card('current');
    await container.read(characterRepoProvider).put(card);
    await revision(card, 1, '');
    final session = _session();
    await container.read(chatRepoProvider).put(session);
    final checkpoints = container.read(sessionCanonCheckpointRepoProvider);
    final root = await checkpoints.appendRootInTransaction(
      sessionId: session.id,
      characterId: 'c1',
      characterRevision: 1,
      characterRevisionHash: CardCanonicalizer.sha256(card),
    );
    await checkpoints.appendInTransaction(
      sessionId: session.id,
      expectedParentCheckpointId: root.id,
      characterId: 'c1',
      characterRevision: 1,
      characterRevisionHash: CardCanonicalizer.sha256(card),
      rewriteJobId: 'job-1',
      anchor: const SessionCanonCheckpointAnchor(
        messageId: 'm1',
        swipeId: 1,
        agentSwipeId: 2,
      ),
    );

    final service = container.read(_serviceProvider);
    final plan = service.planDeleteMessages(session, {0})!;
    await service.commitDeleteMessages(session, plan);

    expect(await checkpoints.getForSession(session.id), hasLength(2));
    expect(
      await container.read(characterRevisionRepoProvider).getForCharacter('c1'),
      hasLength(1),
    );
    expect(await db.select(db.sessionLorebookEmbeddingJobRows).get(), isEmpty);
  });

  test('a surviving later anchor cannot bypass a broken checkpoint', () async {
    final rootCard = _card('root');
    final card1 = rootCard.copyWith(description: 'one');
    final card2 = rootCard.copyWith(description: 'two');
    await container.read(characterRepoProvider).put(card2);
    await revision(rootCard, 1, '');
    await revision(card1, 2, CardCanonicalizer.sha256(rootCard));
    await revision(card2, 3, CardCanonicalizer.sha256(card1));
    final session = _session();
    await container.read(chatRepoProvider).put(session);
    final checkpoints = container.read(sessionCanonCheckpointRepoProvider);
    final root = await checkpoints.appendRootInTransaction(
      sessionId: session.id,
      characterId: 'c1',
      characterRevision: 1,
      characterRevisionHash: CardCanonicalizer.sha256(rootCard),
    );
    final first = await checkpoints.appendInTransaction(
      sessionId: session.id,
      expectedParentCheckpointId: root.id,
      characterId: 'c1',
      characterRevision: 2,
      characterRevisionHash: CardCanonicalizer.sha256(card1),
      rewriteJobId: 'job-1',
      anchor: const SessionCanonCheckpointAnchor(
        messageId: 'm1',
        swipeId: 1,
        agentSwipeId: 2,
      ),
    );
    await checkpoints.appendInTransaction(
      sessionId: session.id,
      expectedParentCheckpointId: first.id,
      characterId: 'c1',
      characterRevision: 3,
      characterRevisionHash: CardCanonicalizer.sha256(card2),
      rewriteJobId: 'job-2',
      anchor: const SessionCanonCheckpointAnchor(
        messageId: 'm2',
        swipeId: 3,
        agentSwipeId: 4,
      ),
    );

    final changed = session.copyWith(
      messages: [
        session.messages[0],
        session.messages[1].copyWith(swipeId: 9),
        session.messages[2],
      ],
    );
    final service = container.read(_serviceProvider);
    await service.commitMessageMutation(session, 1, (_, _) => changed);

    final restored = await container.read(characterRepoProvider).getById('c1');
    expect(restored?.description, 'root');
    expect(
      (await checkpoints.getForSession(session.id)).last.characterRevision,
      4,
    );
  });

  test('deleting a rewrite anchor rebinds an automatic fork', () async {
    final original = Character(
      id: 'original',
      name: 'Original',
      description: 'before rewrite',
    );
    final fork = Character(
      id: 'fork',
      name: 'Original',
      description: 'after rewrite',
      variantGroupId: 'original',
      variantOrder: 1,
    );
    await container.read(characterRepoProvider).put(original);
    await container.read(characterRepoProvider).put(fork);
    await revision(original, 12, '');
    await revision(fork, 1, '');
    await revision(fork, 2, CardCanonicalizer.sha256(fork));
    final session = const ChatSession(
      id: 's1',
      characterId: 'fork',
      sessionIndex: 0,
      messages: [
        ChatMessage(id: 'm0', role: 'user', content: 'before'),
        ChatMessage(id: 'anchor', role: 'assistant', content: 'rewrite'),
      ],
    );
    await container.read(chatRepoProvider).put(session);
    final checkpoints = container.read(sessionCanonCheckpointRepoProvider);
    final root = await checkpoints.appendRootInTransaction(
      sessionId: session.id,
      characterId: original.id,
      characterRevision: 12,
      characterRevisionHash: CardCanonicalizer.sha256(original),
    );
    await checkpoints.appendInTransaction(
      sessionId: session.id,
      expectedParentCheckpointId: root.id,
      characterId: fork.id,
      characterRevision: 2,
      characterRevisionHash: CardCanonicalizer.sha256(fork),
      rewriteJobId: 'job-fork',
      anchor: const SessionCanonCheckpointAnchor(
        messageId: 'anchor',
        swipeId: 0,
        agentSwipeId: 0,
      ),
    );

    final result = await container.read(_serviceProvider).deleteMessages(
      session,
      {1},
    );

    expect(result.characterId, original.id);
    expect(
      (await container.read(chatRepoProvider).getById(session.id))?.characterId,
      original.id,
    );
    final timeline = await checkpoints.getForSession(session.id);
    expect(timeline.last.characterId, original.id);
    expect(timeline.last.characterRevision, 12);
    expect(
      timeline.last.characterRevisionHash,
      CardCanonicalizer.sha256(original),
    );
    expect(
      await container
          .read(characterRevisionRepoProvider)
          .getForCharacter(original.id),
      hasLength(1),
    );
    expect(
      (await container.read(characterRepoProvider).getById(fork.id))
          ?.description,
      'after rewrite',
    );
  });
}

Character _card(String description) => Character(
  id: 'c1',
  name: 'Current variation',
  description: description,
  avatarPath: 'current.png',
  variantGroupId: 'group',
  variantName: 'Current',
  variantOrder: 7,
);

ChatSession _session() => const ChatSession(
  id: 's1',
  characterId: 'c1',
  sessionIndex: 0,
  messages: [
    ChatMessage(id: 'm0', role: 'user', content: 'before'),
    ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: 'checkpoint one',
      swipeId: 1,
      agentSwipeId: 2,
    ),
    ChatMessage(
      id: 'm2',
      role: 'assistant',
      content: 'checkpoint two',
      swipeId: 3,
      agentSwipeId: 4,
    ),
  ],
);
