import 'package:drift/drift.dart';

import '../../application/character_deletion_store.dart';
import '../app_db.dart';
import 'session_deletion_queries.dart';

class CharacterDeletionRepo implements CharacterDeletionStore {
  final AppDatabase _db;

  CharacterDeletionRepo(this._db);

  @override
  Future<CharacterDeletionResult> deleteCharacters(
    Set<String> characterIds,
  ) async {
    if (characterIds.isEmpty) {
      return const CharacterDeletionResult(
        characterIds: {},
        sessionIds: {},
        studioConfigSessionIds: {},
        lorebookIds: {},
      );
    }

    return _db.transaction(() async {
      final ids = characterIds.toList();
      final characterRows = await (_db.select(
        _db.characters,
      )..where((row) => row.charId.isIn(ids))).get();
      final sessionRows = await (_db.select(
        _db.chatSessions,
      )..where((row) => row.characterId.isIn(ids))).get();
      final sessionIds = sessionRows.map((row) => row.sessionId).toSet();
      final studioConfigSessionIds = <String>{};
      if (sessionIds.isNotEmpty) {
        final configs = await (_db.select(
          _db.studioConfigRows,
        )..where((row) => row.sessionId.isIn(sessionIds))).get();
        for (final config in configs) {
          studioConfigSessionIds.add(config.sessionId);
        }
      }

      final retainedVariantGroups = <String>{};
      for (final row in characterRows) {
        final groupId = row.variantGroupId.isEmpty
            ? row.charId
            : row.variantGroupId;
        final sibling =
            await (_db.select(_db.characters)
                  ..where(
                    (candidate) =>
                        candidate.variantGroupId.equals(groupId) &
                        candidate.charId.isNotIn(ids),
                  )
                  ..limit(1))
                .getSingleOrNull();
        if (sibling != null) retainedVariantGroups.add(groupId);
      }
      final deletedLorebookTargets = ids
          .where((id) => !retainedVariantGroups.contains(id))
          .toList();

      final lorebooks = deletedLorebookTargets.isEmpty
          ? const <LorebookRow>[]
          : await (_db.select(_db.lorebooks)..where(
                  (row) =>
                      row.activationScope.equals('character') &
                      row.activationTargetId.isIn(deletedLorebookTargets),
                ))
                .get();
      final lorebookIds = lorebooks.map((row) => row.lorebookId).toSet();

      final sessionDeletion = SessionDeletionQueries(_db);
      for (final sessionId in sessionIds) {
        await sessionDeletion.deleteSessionRows(sessionId);
      }
      // Character-global transitions have a NULL chat_session_id and therefore
      // intentionally survive individual session deletion. Remove every
      // character-owned rewrite/transition here, children before parents.
      await _deleteCharacterRewriteProvenance(ids);

      if (lorebookIds.isNotEmpty) {
        await (_db.delete(_db.embeddings)..where(
              (row) =>
                  row.sourceType.equals('lorebook_entry') &
                  row.sourceId.isIn(lorebookIds),
            ))
            .go();
        await (_db.delete(
          _db.lorebooks,
        )..where((row) => row.lorebookId.isIn(lorebookIds))).go();
      }
      await (_db.delete(
        _db.characterRevisionRows,
      )..where((row) => row.characterId.isIn(ids))).go();
      await (_db.delete(
        _db.characterFolderMembers,
      )..where((row) => row.charId.isIn(ids))).go();
      await (_db.delete(
        _db.characters,
      )..where((row) => row.charId.isIn(ids))).go();

      final representativeGroups = {
        for (final row in characterRows)
          if (row.variantOrder == 0)
            row.variantGroupId.isEmpty ? row.charId : row.variantGroupId,
      };
      for (final groupId in representativeGroups) {
        final sibling =
            await (_db.select(_db.characters)
                  ..where((row) => row.variantGroupId.equals(groupId))
                  ..orderBy([(row) => OrderingTerm.asc(row.variantOrder)])
                  ..limit(1))
                .getSingleOrNull();
        if (sibling != null && sibling.variantOrder != 0) {
          await (_db.update(_db.characters)
                ..where((row) => row.charId.equals(sibling.charId)))
              .write(const CharactersCompanion(variantOrder: Value(0)));
        }
      }

      return CharacterDeletionResult(
        characterIds: characterIds,
        sessionIds: sessionIds,
        studioConfigSessionIds: studioConfigSessionIds,
        lorebookIds: lorebookIds,
      );
    });
  }

  Future<void> _deleteCharacterRewriteProvenance(
    List<String> characterIds,
  ) async {
    final jobs = await (_db.select(
      _db.rewriteJobs,
    )..where((row) => row.characterId.isIn(characterIds))).get();
    final jobIds = jobs.map((row) => row.id).toSet();
    final operations = jobIds.isEmpty
        ? const <RewriteOperationRow>[]
        : await (_db.select(
            _db.rewriteOperations,
          )..where((row) => row.rewriteJobId.isIn(jobIds))).get();
    final operationIds = operations.map((row) => row.id).toSet();
    if (operationIds.isNotEmpty) {
      await (_db.delete(
        _db.rewriteOperationRevisions,
      )..where((row) => row.rewriteOperationId.isIn(operationIds))).go();
      await (_db.delete(
        _db.rewriteEvidenceRows,
      )..where((row) => row.rewriteOperationId.isIn(operationIds))).go();
      await (_db.delete(
        _db.rewriteOperations,
      )..where((row) => row.id.isIn(operationIds))).go();
    }
    if (jobIds.isNotEmpty) {
      await (_db.delete(
        _db.rewriteJobs,
      )..where((row) => row.id.isIn(jobIds))).go();
    }
    final transitions = await (_db.select(
      _db.appliedCanonTransitionRows,
    )..where((row) => row.characterId.isIn(characterIds))).get();
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
