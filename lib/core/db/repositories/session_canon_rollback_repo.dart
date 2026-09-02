import 'dart:convert';

import 'package:drift/drift.dart';

import '../../llm/character_tokens.dart';
import '../../models/character.dart';
import '../../models/chat_message.dart';
import '../../services/card_rewriter/card_rewriter_contracts.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';
import 'character_repo.dart';
import 'session_canon_checkpoint_repo.dart';
import 'session_lorebook_embedding_job_repo.dart';
import 'session_lorebook_revision_repo.dart';

final class SessionCanonRollbackOutcome {
  const SessionCanonRollbackOutcome._({
    required this.rolledBack,
    required this.loreStateChanged,
  });

  const SessionCanonRollbackOutcome.noChange()
    : this._(rolledBack: false, loreStateChanged: false);

  const SessionCanonRollbackOutcome.rolledBack({required bool loreStateChanged})
    : this._(rolledBack: true, loreStateChanged: loreStateChanged);

  final bool rolledBack;
  final bool loreStateChanged;
  bool get shouldWakeLoreEmbeddingWorker => loreStateChanged;
}

/// Reconciles append-only session canon after the caller durably mutates chat.
/// The caller owns the surrounding transaction.
class SessionCanonRollbackRepo {
  SessionCanonRollbackRepo(this.db)
    : _checkpoints = SessionCanonCheckpointRepo(db),
      _loreHistory = SessionLorebookRevisionRepo(db),
      _embeddingJobs = SessionLorebookEmbeddingJobRepo(db);

  final AppDatabase db;
  final SessionCanonCheckpointRepo _checkpoints;
  final SessionLorebookRevisionRepo _loreHistory;
  final SessionLorebookEmbeddingJobRepo _embeddingJobs;

  Future<SessionCanonRollbackOutcome> reconcileInTransaction({
    required String sessionId,
    required List<ChatMessage> survivingMessages,
  }) async {
    final timeline = await _checkpoints.getForSession(sessionId);
    if (timeline.isEmpty) return const SessionCanonRollbackOutcome.noChange();

    final survivingById = {
      for (final message in survivingMessages) message.id: message,
    };
    bool anchorSurvives(SessionCanonCheckpointRow checkpoint) =>
        checkpoint.sequence == 0 ||
        checkpoint.anchorMessageId.startsWith('canon-rollback-root:') ||
        (survivingById[checkpoint.anchorMessageId]?.swipeId ==
                checkpoint.anchorSwipeId &&
            survivingById[checkpoint.anchorMessageId]?.agentSwipeId ==
                checkpoint.anchorAgentSwipeId);

    SessionCanonCheckpointRow target = timeline.first;
    var prefixValid = true;
    for (final checkpoint in timeline.skip(1)) {
      final isRollback =
          checkpoint.rewriteJobId?.startsWith('canon-rollback:') ?? false;
      if (isRollback) prefixValid = anchorSurvives(checkpoint);
      if (prefixValid && anchorSurvives(checkpoint)) {
        target = checkpoint;
      } else if (!isRollback) {
        prefixValid = false;
      }
    }

    final latest = timeline.last;
    if (target.id == latest.id) {
      return const SessionCanonRollbackOutcome.noChange();
    }
    final session = await (db.select(
      db.chatSessions,
    )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
    if (session == null) throw StateError('Rollback session does not exist.');
    final current = await CharacterRepo(db).getById(session.characterId);
    if (current == null) {
      throw StateError('Rollback session character does not exist.');
    }
    final targetCharacter = await _loadCharacterSnapshot(target);
    var rollbackCharacterId = current.id;
    var rollbackRevision = 0;
    var rollbackHash = '';
    final targetLive = target.characterId == current.id
        ? null
        : await CharacterRepo(db).getById(target.characterId);
    final canRebindToTarget =
        targetLive != null &&
        CardCanonicalizer.sha256(targetLive) == target.characterRevisionHash;

    if (canRebindToTarget) {
      final changed =
          await (db.update(db.chatSessions)..where(
                (row) =>
                    row.sessionId.equals(sessionId) &
                    row.characterId.equals(current.id),
              ))
              .write(
                ChatSessionsCompanion(characterId: Value(target.characterId)),
              );
      if (changed != 1) throw StateError('Rollback session owner is stale.');
      rollbackCharacterId = target.characterId;
      rollbackRevision = target.characterRevision;
      rollbackHash = target.characterRevisionHash;
    } else {
      final restored = targetCharacter.copyWith(
        id: current.id,
        name: current.name,
        displayName: current.displayName,
        avatarPath: current.avatarPath,
        color: current.color,
        updatedAt: current.updatedAt,
        createdAt: current.createdAt,
        gallery: current.gallery,
        currentSessionIndex: current.currentSessionIndex,
        fav: current.fav,
        characterVersion: current.characterVersion,
        picksHash: current.picksHash,
        tokenCount: current.tokenCount,
        variantGroupId: current.variantGroupId,
        variantName: current.variantName,
        variantOrder: current.variantOrder,
        hidden: current.hidden,
      );

      final latestRevision =
          await (db.select(db.characterRevisionRows)
                ..where((row) => row.characterId.equals(current.id))
                ..orderBy([(row) => OrderingTerm.desc(row.revision)])
                ..limit(1))
              .getSingleOrNull();
      if (latestRevision == null) {
        throw StateError('Rollback character lineage does not exist.');
      }
      rollbackRevision = latestRevision.revision + 1;
      rollbackHash = CardCanonicalizer.sha256(restored);
      await _restoreCharacterCas(current, restored);
      await db
          .into(db.characterRevisionRows)
          .insert(
            CharacterRevisionRowsCompanion.insert(
              characterId: current.id,
              revision: rollbackRevision,
              revisionHash: rollbackHash,
              parentRevisionHash: Value(latestRevision.revisionHash),
              snapshotJson: jsonEncode(restored.toJson()),
              createdAt: Value(currentTimestampSeconds()),
            ),
          );
    }

    final rollbackAnchor = target.sequence == 0
        ? SessionCanonCheckpointAnchor(
            messageId: 'canon-rollback-root:$sessionId',
            swipeId: 0,
            agentSwipeId: 0,
          )
        : SessionCanonCheckpointAnchor(
            messageId: target.anchorMessageId,
            swipeId: target.anchorSwipeId,
            agentSwipeId: target.anchorAgentSwipeId,
          );
    final rollbackId = 'canon-rollback:$sessionId:${latest.id}';
    final rollback = await _checkpoints.appendInTransaction(
      sessionId: sessionId,
      expectedParentCheckpointId: latest.id,
      characterId: rollbackCharacterId,
      characterRevision: rollbackRevision,
      characterRevisionHash: rollbackHash,
      rewriteJobId: rollbackId,
      anchor: rollbackAnchor,
    );

    await _retractFutureTransitions(
      sessionId: sessionId,
      timeline: timeline,
      targetSequence: target.sequence,
    );
    final loreChanged = await _restoreLore(
      sessionId: sessionId,
      timeline: timeline,
      targetSequence: target.sequence,
      rollbackCheckpointId: rollback.id,
      rollbackOperationId: rollbackId,
    );
    return SessionCanonRollbackOutcome.rolledBack(
      loreStateChanged: loreChanged,
    );
  }

  Future<Character> _loadCharacterSnapshot(
    SessionCanonCheckpointRow checkpoint,
  ) async {
    final revision =
        await (db.select(db.characterRevisionRows)..where(
              (row) =>
                  row.characterId.equals(checkpoint.characterId) &
                  row.revision.equals(checkpoint.characterRevision) &
                  row.revisionHash.equals(checkpoint.characterRevisionHash),
            ))
            .getSingleOrNull();
    if (revision == null) {
      throw StateError('Rollback checkpoint character revision is missing.');
    }
    try {
      return Character.fromJson(
        Map<String, dynamic>.from(jsonDecode(revision.snapshotJson) as Map),
      );
    } catch (_) {
      throw StateError('Rollback checkpoint character snapshot is invalid.');
    }
  }

  Future<void> _restoreCharacterCas(
    Character current,
    Character restored,
  ) async {
    final extensions = Map<String, dynamic>.from(restored.extensions);
    final displayName = current.displayName?.trim();
    if (displayName != null && displayName.isNotEmpty) {
      extensions['displayName'] = displayName;
    } else {
      extensions.remove('displayName');
    }
    final now = currentTimestampSeconds();
    final changed =
        await (db.update(db.characters)..where(
              (row) =>
                  row.charId.equals(current.id) &
                  row.updatedAt.equals(current.updatedAt),
            ))
            .write(
              CharactersCompanion(
                description: Value(restored.description),
                personality: Value(restored.personality),
                scenario: Value(restored.scenario),
                firstMes: Value(restored.firstMes),
                mesExample: Value(restored.mesExample),
                systemPrompt: Value(restored.systemPrompt),
                postHistoryInstructions: Value(
                  restored.postHistoryInstructions,
                ),
                creator: Value(restored.creator),
                creatorNotes: Value(restored.creatorNotes),
                tagsJson: Value(jsonEncode(restored.tags)),
                alternateGreetingsJson: Value(
                  jsonEncode(restored.alternateGreetings),
                ),
                extensionsJson: Value(
                  extensions.isEmpty ? null : jsonEncode(extensions),
                ),
                characterVersion: Value(restored.characterVersion),
                macroName: Value(restored.macroName),
                picksHash: Value(restored.picksHash),
                tokenCount: Value(estimateCharacterTokens(restored)),
                updatedAt: Value(
                  now > current.updatedAt ? now : current.updatedAt + 1,
                ),
              ),
            );
    if (changed != 1) throw StateError('Rollback character CAS is stale.');
  }

  Future<void> _retractFutureTransitions({
    required String sessionId,
    required List<SessionCanonCheckpointRow> timeline,
    required int targetSequence,
  }) async {
    final futureJobIds = timeline
        .where((row) => row.sequence > targetSequence)
        .map((row) => row.rewriteJobId)
        .whereType<String>()
        .toSet();
    if (futureJobIds.isEmpty) return;
    final operations = await (db.select(
      db.rewriteOperations,
    )..where((row) => row.rewriteJobId.isIn(futureJobIds))).get();
    final operationIds = operations.map((row) => row.id).toSet();
    if (operationIds.isEmpty) return;
    final transitions =
        await (db.select(db.appliedCanonTransitionRows)..where(
              (row) =>
                  row.chatSessionId.equals(sessionId) &
                  row.rewriteOperationId.isIn(operationIds),
            ))
            .get();
    final transitionIds = transitions.map((row) => row.id).toSet();
    if (transitionIds.isEmpty) return;
    await (db.delete(
      db.canonTransitionFactRefs,
    )..where((row) => row.appliedCanonTransitionId.isIn(transitionIds))).go();
    await (db.delete(
      db.appliedCanonTransitionRows,
    )..where((row) => row.id.isIn(transitionIds))).go();
  }

  Future<bool> _restoreLore({
    required String sessionId,
    required List<SessionCanonCheckpointRow> timeline,
    required int targetSequence,
    required String rollbackCheckpointId,
    required String rollbackOperationId,
  }) async {
    final sequenceByCheckpoint = {
      for (final checkpoint in timeline) checkpoint.id: checkpoint.sequence,
    };
    final history = await _loreHistory.getForSession(sessionId);
    final futureTargets = <String>{};
    final targetHistory = <String, SessionLorebookRevisionRow>{};
    for (final row in history) {
      final sequence = sequenceByCheckpoint[row.checkpointId];
      if (sequence == null) continue;
      final key = '${row.lorebookId}\u0000${row.entryId}';
      if (sequence > targetSequence) futureTargets.add(key);
      if (sequence <= targetSequence) {
        final previous = targetHistory[key];
        if (previous == null ||
            sequence > (sequenceByCheckpoint[previous.checkpointId] ?? -1)) {
          targetHistory[key] = row;
        }
      }
    }
    if (futureTargets.isEmpty) return false;

    final projections = await (db.select(
      db.sessionLorebookEvolutionRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).get();
    final projectionByKey = {
      for (final row in projections)
        '${row.lorebookId}\u0000${row.entryId}': row,
    };
    final now = currentTimestampSeconds();
    for (final key in futureTargets) {
      final projection = projectionByKey[key];
      if (projection == null) {
        throw StateError('Rollback lorebook projection is missing.');
      }
      final atTarget = targetHistory[key];
      // v121 has no lore tombstone. A target first introduced after the chosen
      // checkpoint is restored to its immutable source/base content instead.
      final content = atTarget?.content ?? projection.baseContent;
      final contentHash = atTarget?.contentHash ?? projection.baseContentHash;
      final changed =
          await (db.update(db.sessionLorebookEvolutionRows)..where(
                (row) =>
                    row.chatSessionId.equals(sessionId) &
                    row.lorebookId.equals(projection.lorebookId) &
                    row.entryId.equals(projection.entryId) &
                    row.contentHash.equals(projection.contentHash),
              ))
              .write(
                SessionLorebookEvolutionRowsCompanion(
                  content: Value(content),
                  contentHash: Value(contentHash),
                  updatedAt: Value(now),
                ),
              );
      if (changed != 1) throw StateError('Rollback lorebook CAS is stale.');
      await _loreHistory.appendInTransaction(
        checkpointId: rollbackCheckpointId,
        sessionId: sessionId,
        lorebookId: projection.lorebookId,
        entryId: projection.entryId,
        baseContentHash: projection.baseContentHash,
        expectedPreviousContentHash: projection.contentHash,
        content: content,
        contentHash: contentHash,
        rewriteOperationId:
            '$rollbackOperationId:${projection.lorebookId}:${projection.entryId}',
      );
      final embeddingEntryId =
          '$sessionId:${projection.lorebookId}:${projection.entryId}';
      await (db.delete(db.embeddings)..where(
            (row) =>
                row.sourceType.equals('session_lorebook_entry') &
                row.sourceId.equals(sessionId) &
                row.entryId.equals(embeddingEntryId),
          ))
          .go();
      await _embeddingJobs.enqueueInTransaction(
        sessionId: sessionId,
        checkpointId: rollbackCheckpointId,
        lorebookId: projection.lorebookId,
        entryId: projection.entryId,
        expectedContentHash: contentHash,
      );
    }
    return true;
  }
}
