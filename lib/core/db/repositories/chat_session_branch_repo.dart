import 'dart:convert';

import 'package:drift/drift.dart';

import '../../llm/character_tokens.dart';
import '../../models/character.dart';
import '../../models/chat_message.dart';
import '../../services/card_rewriter/card_rewriter_contracts.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';
import 'session_canon_checkpoint_repo.dart';
import 'session_lorebook_embedding_job_repo.dart';

final class ChatSessionBranchResult {
  const ChatSessionBranchResult({
    required this.session,
    required this.sourceCheckpointSequence,
    required this.rootSnapshotJson,
    required this.rootRevisionHash,
  });

  final ChatSession session;
  final int? sourceCheckpointSequence;
  final String rootSnapshotJson;
  final String rootRevisionHash;
}

/// Owns the cross-table, checkpoint-aware root of a session branch.
class ChatSessionBranchRepo {
  ChatSessionBranchRepo(this.db)
    : _checkpointRepo = SessionCanonCheckpointRepo(db),
      _embeddingJobRepo = SessionLorebookEmbeddingJobRepo(db);

  final AppDatabase db;
  final SessionCanonCheckpointRepo _checkpointRepo;
  final SessionLorebookEmbeddingJobRepo _embeddingJobRepo;

  Future<ChatSessionBranchResult> createInTransaction({
    required Character sourceCharacter,
    required ChatSession sourceSession,
    required List<ChatMessage> retainedMessages,
    required Map<String, String> sessionVars,
  }) async {
    final checkpoints = await _checkpointRepo.getForSession(sourceSession.id);
    final selected = _selectCheckpoint(checkpoints, retainedMessages);
    final snapshot = selected == null
        ? sourceCharacter
        : await _loadSnapshot(selected) ??
              (throw StateError('Checkpoint character revision is missing.'));
    final groupId = sourceCharacter.variantGroupId.isEmpty
        ? sourceCharacter.id
        : sourceCharacter.variantGroupId;
    final maxOrder = db.characters.variantOrder.max();
    final orderRow =
        await (db.selectOnly(db.characters)
              ..addColumns([maxOrder])
              ..where(db.characters.variantGroupId.equals(groupId)))
            .getSingle();
    final now = currentTimestampSeconds();
    final character = snapshot.copyWith(
      id: generateId(),
      avatarPath: sourceCharacter.avatarPath,
      gallery: const [],
      fav: false,
      currentSessionIndex: 0,
      variantGroupId: groupId,
      variantOrder: (orderRow.read(maxOrder) ?? 0) + 1,
      variantName: selected == null
          ? 'Branch from ${sourceCharacter.variantName ?? sourceCharacter.name}'
          : 'Branch at checkpoint ${selected.sequence}',
      createdAt: now,
      updatedAt: now,
    );
    await db.into(db.characters).insert(_characterCompanion(character));

    final revisionHash = CardCanonicalizer.sha256(character);
    await db
        .into(db.characterRevisionRows)
        .insert(
          CharacterRevisionRowsCompanion.insert(
            characterId: character.id,
            revision: 1,
            revisionHash: revisionHash,
            snapshotJson: jsonEncode(character.toJson()),
            createdAt: Value(now),
          ),
        );

    final session = ChatSession(
      id: '${character.id}_0',
      characterId: character.id,
      sessionIndex: 0,
      messages: retainedMessages,
      sessionVars: sessionVars,
      authorsNote: sourceSession.authorsNote,
      updatedAt: now,
    );
    await db.into(db.chatSessions).insert(_sessionCompanion(session));
    final root = await _checkpointRepo.appendRootInTransaction(
      sessionId: session.id,
      characterId: character.id,
      characterRevision: 1,
      characterRevisionHash: revisionHash,
    );
    await _reconstructLorebookState(
      sourceSessionId: sourceSession.id,
      branchSessionId: session.id,
      branchCheckpointId: root.id,
      selectedSequence: selected?.sequence,
      hasTimeline: checkpoints.isNotEmpty,
      now: now,
    );
    return ChatSessionBranchResult(
      session: session,
      sourceCheckpointSequence: selected?.sequence,
      rootSnapshotJson: jsonEncode(character.toJson()),
      rootRevisionHash: revisionHash,
    );
  }

  Future<void> copyCanonTransitionsInTransaction({
    required String sourceSessionId,
    required String branchSessionId,
    required String branchCharacterId,
    required String branchRevisionHash,
    required int? sourceCheckpointSequence,
  }) async {
    if (sourceCheckpointSequence == null) return;
    final checkpointRows =
        await (db.select(db.sessionCanonCheckpointRows)..where(
              (row) =>
                  row.chatSessionId.equals(sourceSessionId) &
                  row.sequence.isSmallerOrEqualValue(sourceCheckpointSequence),
            ))
            .get();
    final jobIds = checkpointRows
        .map((checkpoint) => checkpoint.rewriteJobId)
        .whereType<String>()
        .toSet();
    final operations = jobIds.isEmpty
        ? const <RewriteOperationRow>[]
        : await (db.select(
            db.rewriteOperations,
          )..where((row) => row.rewriteJobId.isIn(jobIds))).get();
    final operationIds = operations.map((operation) => operation.id).toSet();
    final sourceTransitions = await (db.select(
      db.appliedCanonTransitionRows,
    )..where((row) => row.chatSessionId.equals(sourceSessionId))).get();
    final inheritedSuffix = '@$sourceSessionId';
    final transitions = sourceTransitions
        .where(
          (transition) =>
              operationIds.contains(transition.rewriteOperationId) ||
              transition.rewriteOperationId.endsWith(inheritedSuffix),
        )
        .toList(growable: false);
    for (final transition in transitions) {
      final copiedId = '${transition.id}@$branchSessionId';
      await db
          .into(db.appliedCanonTransitionRows)
          .insert(
            AppliedCanonTransitionRowsCompanion.insert(
              id: copiedId,
              chatSessionId: Value(branchSessionId),
              characterId: branchCharacterId,
              rewriteOperationId: Value(
                '${transition.rewriteOperationId}@$branchSessionId',
              ),
              revision: const Value(1),
              revisionHash: Value(branchRevisionHash),
              semanticScopeKey: Value(transition.semanticScopeKey),
              canonicalClaim: Value(transition.canonicalClaim),
              promotionDestination: Value(transition.promotionDestination),
              affectedTrackerKeysJson: Value(
                transition.affectedTrackerKeysJson,
              ),
              transitionJson: transition.transitionJson,
              basisRevision: const Value(1),
              basisRevisionHash: Value(branchRevisionHash),
              appliedAt: Value(transition.appliedAt),
            ),
          );
      final refs =
          await (db.select(db.canonTransitionFactRefs)..where(
                (row) => row.appliedCanonTransitionId.equals(transition.id),
              ))
              .get();
      for (final ref in refs) {
        final copiedFactId = '${ref.characterKnowledgeFactId}@$branchSessionId';
        final factExists = await (db.select(
          db.characterKnowledgeFactRows,
        )..where((row) => row.id.equals(copiedFactId))).getSingleOrNull();
        if (factExists == null) continue;
        await db
            .into(db.canonTransitionFactRefs)
            .insert(
              CanonTransitionFactRefsCompanion.insert(
                appliedCanonTransitionId: copiedId,
                characterKnowledgeFactId: copiedFactId,
                createdAt: Value(ref.createdAt),
              ),
            );
      }
    }
  }

  SessionCanonCheckpointRow? _selectCheckpoint(
    List<SessionCanonCheckpointRow> checkpoints,
    List<ChatMessage> messages,
  ) {
    final byId = {for (final message in messages) message.id: message};
    SessionCanonCheckpointRow? selected;
    var prefixValid = true;
    for (final checkpoint in checkpoints) {
      final anchorSurvives =
          checkpoint.sequence == 0 ||
          checkpoint.anchorMessageId.startsWith('canon-rollback-root:') ||
          (byId[checkpoint.anchorMessageId]?.swipeId ==
                  checkpoint.anchorSwipeId &&
              byId[checkpoint.anchorMessageId]?.agentSwipeId ==
                  checkpoint.anchorAgentSwipeId);
      final isRollback =
          checkpoint.rewriteJobId?.startsWith('canon-rollback:') ?? false;
      if (isRollback) prefixValid = anchorSurvives;
      if (prefixValid &&
          anchorSurvives &&
          (selected == null || checkpoint.sequence > selected.sequence)) {
        selected = checkpoint;
      } else if (!isRollback) {
        prefixValid = false;
      }
    }
    return selected;
  }

  Future<Character?> _loadSnapshot(
    SessionCanonCheckpointRow? checkpoint,
  ) async {
    if (checkpoint == null) return null;
    final row =
        await (db.select(db.characterRevisionRows)..where(
              (revision) =>
                  revision.characterId.equals(checkpoint.characterId) &
                  revision.revision.equals(checkpoint.characterRevision) &
                  revision.revisionHash.equals(
                    checkpoint.characterRevisionHash,
                  ),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    try {
      return Character.fromJson(
        Map<String, dynamic>.from(jsonDecode(row.snapshotJson) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _reconstructLorebookState({
    required String sourceSessionId,
    required String branchSessionId,
    required String branchCheckpointId,
    required int? selectedSequence,
    required bool hasTimeline,
    required int now,
  }) async {
    final latestRows = await (db.select(
      db.sessionLorebookEvolutionRows,
    )..where((row) => row.chatSessionId.equals(sourceSessionId))).get();
    final latestByTarget = {
      for (final row in latestRows)
        '${row.lorebookId}\u0000${row.entryId}': row,
    };
    final selectedHistory = <String, SessionLorebookRevisionRow>{};
    if (hasTimeline && selectedSequence != null) {
      final checkpoints = await _checkpointRepo.getForSession(sourceSessionId);
      final sequenceById = {
        for (final row in checkpoints) row.id: row.sequence,
      };
      final history = await (db.select(
        db.sessionLorebookRevisionRows,
      )..where((row) => row.chatSessionId.equals(sourceSessionId))).get();
      for (final row in history) {
        final sequence = sequenceById[row.checkpointId];
        if (sequence == null || sequence > selectedSequence) continue;
        final key = '${row.lorebookId}\u0000${row.entryId}';
        final previous = selectedHistory[key];
        if (previous == null ||
            sequence > (sequenceById[previous.checkpointId] ?? -1)) {
          selectedHistory[key] = row;
        }
      }
    }

    final targets = hasTimeline ? selectedHistory.keys : latestByTarget.keys;
    for (final key in targets) {
      final history = selectedHistory[key];
      final latest = latestByTarget[key];
      if (history == null && latest == null) continue;
      final lorebookId = history?.lorebookId ?? latest!.lorebookId;
      final entryId = history?.entryId ?? latest!.entryId;
      final content = history?.content ?? latest!.content;
      final contentHash = history?.contentHash ?? latest!.contentHash;
      final baseContentHash =
          history?.baseContentHash ?? latest!.baseContentHash;
      await db
          .into(db.sessionLorebookEvolutionRows)
          .insert(
            SessionLorebookEvolutionRowsCompanion.insert(
              chatSessionId: branchSessionId,
              lorebookId: lorebookId,
              entryId: entryId,
              baseContent: latest?.baseContent ?? content,
              baseContentHash: baseContentHash,
              content: content,
              contentHash: contentHash,
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db
          .into(db.sessionLorebookRevisionRows)
          .insert(
            SessionLorebookRevisionRowsCompanion.insert(
              checkpointId: branchCheckpointId,
              chatSessionId: branchSessionId,
              lorebookId: lorebookId,
              entryId: entryId,
              baseContentHash: baseContentHash,
              previousContentHash: contentHash,
              content: content,
              contentHash: contentHash,
              rewriteOperationId: 'branch-root@$branchSessionId',
              createdAt: now,
            ),
          );
      await _embeddingJobRepo.enqueueInTransaction(
        sessionId: branchSessionId,
        checkpointId: branchCheckpointId,
        lorebookId: lorebookId,
        entryId: entryId,
        expectedContentHash: contentHash,
      );
    }
  }

  CharactersCompanion _characterCompanion(Character character) {
    final extensions = Map<String, dynamic>.from(character.extensions);
    final displayName = character.displayName?.trim();
    if (displayName != null && displayName.isNotEmpty) {
      extensions['displayName'] = displayName;
    }
    return CharactersCompanion.insert(
      charId: character.id,
      name: character.name,
      avatarPath: Value(character.avatarPath),
      description: Value(character.description),
      personality: Value(character.personality),
      scenario: Value(character.scenario),
      firstMes: Value(character.firstMes),
      mesExample: Value(character.mesExample),
      systemPrompt: Value(character.systemPrompt),
      postHistoryInstructions: Value(character.postHistoryInstructions),
      creator: Value(character.creator),
      creatorNotes: Value(character.creatorNotes),
      color: Value(character.color),
      updatedAt: Value(character.updatedAt),
      createdAt: Value(character.createdAt),
      tagsJson: Value(jsonEncode(character.tags)),
      alternateGreetingsJson: Value(jsonEncode(character.alternateGreetings)),
      galleryJson: const Value('[]'),
      currentSessionIndex: const Value(0),
      fav: const Value(false),
      extensionsJson: Value(extensions.isEmpty ? null : jsonEncode(extensions)),
      characterVersion: Value(character.characterVersion),
      macroName: Value(character.macroName),
      picksHash: Value(character.picksHash),
      tokenCount: Value(estimateCharacterTokens(character)),
      variantGroupId: Value(character.variantGroupId),
      variantName: Value(character.variantName),
      variantOrder: Value(character.variantOrder),
      hidden: Value(character.hidden),
    );
  }

  ChatSessionsCompanion _sessionCompanion(ChatSession session) =>
      ChatSessionsCompanion.insert(
        sessionId: session.id,
        characterId: session.characterId,
        sessionIndex: session.sessionIndex,
        messagesJson: jsonEncode(
          session.messages.map((message) => message.toJson()).toList(),
        ),
        updatedAt: Value(session.updatedAt),
        sessionVarsJson: Value(jsonEncode(session.sessionVars)),
        authorsNoteJson: Value(
          session.authorsNote == null
              ? null
              : jsonEncode(session.authorsNote!.toJson()),
        ),
      );
}
