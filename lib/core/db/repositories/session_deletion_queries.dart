import 'package:drift/drift.dart';

import '../app_db.dart';
import 'lorebook_use_manifest_repo.dart';

/// The DB-only session cascade. The caller must provide the surrounding
/// transaction so this can compose into larger atomic deletion operations.
class SessionDeletionQueries {
  final AppDatabase _db;

  SessionDeletionQueries(this._db);

  Future<void> deleteMessageDerivedRows({
    required String sessionId,
    required String? characterId,
    required bool preserveMemoryBookSettings,
  }) async {
    // Durable rewrite provenance survives clear chat and message/swipe edits.
    // A full session cascade removes it in [_deleteRewriteProvenance].
    if (preserveMemoryBookSettings) {
      await (_db.update(
        _db.memoryBookRows,
      )..where((row) => row.sessionId.equals(sessionId))).write(
        const MemoryBookRowsCompanion(
          entriesJson: Value('[]'),
          pendingDraftsJson: Value('[]'),
          lastProcessedMessageCount: Value(0),
        ),
      );
    } else {
      await (_db.delete(
        _db.memoryBookRows,
      )..where((row) => row.sessionId.equals(sessionId))).go();
    }
    await (_db.delete(
      _db.memoryCatalogRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.memoryEntityRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.memorySalienceRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.memoryCadenceRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.memoryConsolidationRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.trackerRows,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.trackerSnapshots,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.ledgerReconciliationCheckpoints,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.ledgerReconciliationCleanupJournals,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.ledgerReconciliationCursors,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.cardEvolutionCollectorRuns,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(_db.cardEvolutionClaims)..where((row) {
          final session = row.sessionId.equals(sessionId);
          return preserveMemoryBookSettings
              ? session & row.status.equals('claimed')
              : session;
        }))
        .go();
    await (_db.delete(
      _db.ledgerReconciliationRunInvalidations,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.ledgerReconciliationSuccessfulRuns,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.characterKnowledgeFactRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.chatSummaries,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.infoBlocks,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.ledgerDebugRuns,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.cardEvolutionDebugRuns,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.llmRequestCaptureRows,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.llmCallEventRows,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(_db.embeddings)..where((row) {
          final chatMessages =
              row.sourceType.equals('chat_message') &
              row.sourceId.equals(sessionId);
          if (characterId == null) return chatMessages;
          return chatMessages |
              (row.sourceType.equals('memory_entry') &
                  row.sourceId.equals('memorybook_${characterId}_$sessionId'));
        }))
        .go();
  }

  Future<void> deleteSessionRows(String sessionId) async {
    final session = await (_db.select(
      _db.chatSessions,
    )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
    final chatLorebookIds =
        await (_db.selectOnly(_db.lorebooks)
              ..addColumns([_db.lorebooks.lorebookId])
              ..where(
                _db.lorebooks.activationScope.equals('chat') &
                    _db.lorebooks.activationTargetId.equals(sessionId),
              ))
            .map((row) => row.read(_db.lorebooks.lorebookId)!)
            .get();

    await deleteMessageDerivedRows(
      sessionId: sessionId,
      characterId: session?.characterId,
      preserveMemoryBookSettings: false,
    );
    await LorebookUseManifestRepo(_db).deleteBySessionId(sessionId);
    // Child-first ordering keeps this safe when foreign keys are enabled.
    await _deleteRewriteProvenance(sessionId);
    await (_db.delete(
      _db.sessionLorebookEmbeddingJobRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.sessionLorebookRevisionRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.sessionCanonCheckpointRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.characterSessionBaselineRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.sessionLorebookEvolutionRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.studioConfigRows,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(_db.embeddings)..where(
          (row) =>
              row.sourceType.equals('session_lorebook_entry') &
              row.sourceId.equals(sessionId),
        ))
        .go();
    if (chatLorebookIds.isNotEmpty) {
      await (_db.delete(_db.embeddings)..where(
            (row) =>
                row.sourceType.equals('lorebook_entry') &
                row.sourceId.isIn(chatLorebookIds),
          ))
          .go();
    }
    await (_db.delete(_db.lorebooks)..where(
          (row) =>
              row.activationScope.equals('chat') &
              row.activationTargetId.equals(sessionId),
        ))
        .go();
    await (_db.delete(
      _db.chatSessions,
    )..where((row) => row.sessionId.equals(sessionId))).go();
  }

  Future<void> _deleteRewriteProvenance(String sessionId) async {
    await (_db.delete(
      _db.cardEvolutionProposalRuns,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    final rewriteJobs = await (_db.select(
      _db.rewriteJobs,
    )..where((row) => row.chatSessionId.equals(sessionId))).get();
    final rewriteJobIds = rewriteJobs.map((row) => row.id).toSet();
    final rewriteOperations = rewriteJobIds.isEmpty
        ? const <RewriteOperationRow>[]
        : await (_db.select(
            _db.rewriteOperations,
          )..where((row) => row.rewriteJobId.isIn(rewriteJobIds))).get();
    final rewriteOperationIds = rewriteOperations.map((row) => row.id).toSet();
    if (rewriteOperationIds.isNotEmpty) {
      await (_db.delete(
        _db.rewriteOperationRevisions,
      )..where((row) => row.rewriteOperationId.isIn(rewriteOperationIds))).go();
      await (_db.delete(
        _db.rewriteEvidenceRows,
      )..where((row) => row.rewriteOperationId.isIn(rewriteOperationIds))).go();
      await (_db.delete(
        _db.rewriteOperations,
      )..where((row) => row.id.isIn(rewriteOperationIds))).go();
    }
    if (rewriteJobIds.isNotEmpty) {
      await (_db.delete(
        _db.rewriteJobs,
      )..where((row) => row.id.isIn(rewriteJobIds))).go();
    }
    final transitions = await (_db.select(
      _db.appliedCanonTransitionRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).get();
    final transitionIds = transitions.map((row) => row.id).toSet();
    if (transitionIds.isNotEmpty) {
      await (_db.delete(
        _db.canonTransitionFactRefs,
      )..where((row) => row.appliedCanonTransitionId.isIn(transitionIds))).go();
      await (_db.delete(
        _db.appliedCanonTransitionRows,
      )..where((row) => row.id.isIn(transitionIds))).go();
    }
  }
}
