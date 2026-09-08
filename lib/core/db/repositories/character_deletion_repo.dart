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
          if (config.profileId.isEmpty ||
              config.profileId == config.sessionId) {
            studioConfigSessionIds.add(config.sessionId);
          }
        }
      }

      final lorebooks =
          await (_db.select(_db.lorebooks)..where(
                (row) =>
                    row.activationScope.equals('character') &
                    row.activationTargetId.isIn(ids),
              ))
              .get();
      final lorebookIds = lorebooks.map((row) => row.lorebookId).toSet();

      final sessionDeletion = SessionDeletionQueries(_db);
      for (final sessionId in sessionIds) {
        await sessionDeletion.deleteSessionRows(sessionId);
      }

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
}
