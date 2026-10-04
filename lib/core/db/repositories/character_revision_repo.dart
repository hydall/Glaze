import 'package:drift/drift.dart';

import '../app_db.dart';

final class CharacterRevisionRecord {
  const CharacterRevisionRecord({
    required this.characterId,
    required this.revision,
    required this.revisionHash,
    required this.parentRevisionHash,
    required this.snapshotJson,
    required this.createdAt,
  });
  final String characterId;
  final int revision;
  final String revisionHash;
  final String parentRevisionHash;
  final String snapshotJson;
  final int createdAt;
}

class CharacterRevisionRepo {
  const CharacterRevisionRepo(this._db);
  final AppDatabase _db;

  Future<List<CharacterRevisionRecord>> getForCharacter(String characterId) =>
      (_db.select(_db.characterRevisionRows)
            ..where((row) => row.characterId.equals(characterId))
            ..orderBy([(row) => OrderingTerm.asc(row.revision)]))
          .get()
          .then((rows) => rows.map(_fromRow).toList(growable: false));

  Future<void> insert(CharacterRevisionRecord value) => _db
      .into(_db.characterRevisionRows)
      .insertOnConflictUpdate(
        CharacterRevisionRowsCompanion.insert(
          characterId: value.characterId,
          revision: value.revision,
          revisionHash: value.revisionHash,
          parentRevisionHash: Value(value.parentRevisionHash),
          snapshotJson: value.snapshotJson,
          createdAt: Value(value.createdAt),
        ),
      );

  CharacterRevisionRecord _fromRow(CharacterRevisionRow row) =>
      CharacterRevisionRecord(
        characterId: row.characterId,
        revision: row.revision,
        revisionHash: row.revisionHash,
        parentRevisionHash: row.parentRevisionHash,
        snapshotJson: row.snapshotJson,
        createdAt: row.createdAt,
      );
}
