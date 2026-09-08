import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../models/character_folder.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';

class CharacterFolderRepo {
  final AppDatabase _db;
  CharacterFolderRepo(this._db);

  // ── Folders ────────────────────────────────────────────────────────────

  Stream<List<CharacterFolder>> watchFolders() {
    return (_db.select(_db.characterFolders)
          ..orderBy([
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.createdAt),
          ]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  Future<List<CharacterFolder>> getFolders() async {
    final rows = await (_db.select(_db.characterFolders)
          ..orderBy([
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.createdAt),
          ]))
        .get();
    return rows.map(_toModel).toList();
  }

  Future<CharacterFolder> create({required String name, String? color}) async {
    final now = currentTimestampSeconds();
    final folder = CharacterFolder(
      id: generateId(),
      name: name,
      color: color,
      sortOrder: now,
      createdAt: now,
      updatedAt: now,
    );
    await _db.into(_db.characterFolders).insert(
          CharacterFoldersCompanion(
            folderId: Value(folder.id),
            name: Value(folder.name),
            color: Value(folder.color),
            sortOrder: Value(folder.sortOrder),
            createdAt: Value(folder.createdAt),
            updatedAt: Value(folder.updatedAt),
          ),
        );
    return folder;
  }

  Future<void> rename(String folderId, String name) async {
    await (_db.update(_db.characterFolders)
          ..where((t) => t.folderId.equals(folderId)))
        .write(
      CharacterFoldersCompanion(
        name: Value(name),
        updatedAt: Value(currentTimestampSeconds()),
      ),
    );
  }

  Future<void> setColor(String folderId, String? color) async {
    await (_db.update(_db.characterFolders)
          ..where((t) => t.folderId.equals(folderId)))
        .write(
      CharacterFoldersCompanion(
        color: Value(color),
        updatedAt: Value(currentTimestampSeconds()),
      ),
    );
  }

  /// Deletes the folder and its membership rows (characters are untouched).
  Future<void> delete(String folderId) async {
    await _db.transaction(() async {
      await (_db.delete(_db.characterFolderMembers)
            ..where((t) => t.folderId.equals(folderId)))
          .go();
      await (_db.delete(_db.characterFolders)
            ..where((t) => t.folderId.equals(folderId)))
          .go();
    });
  }

  // ── Membership ─────────────────────────────────────────────────────────

  Stream<List<CharacterFolderMemberRow>> watchMembers() {
    return _db.select(_db.characterFolderMembers).watch();
  }

  Future<Set<String>> getFolderIdsForChar(String charId) async {
    final rows = await (_db.select(_db.characterFolderMembers)
          ..where((t) => t.charId.equals(charId)))
        .get();
    return rows.map((r) => r.folderId).toSet();
  }

  /// Idempotent: re-adding a character already in the folder is a no-op, which
  /// enforces the "no duplicates within a folder" rule (composite PK).
  Future<void> addMember(String folderId, String charId) async {
    await _db.into(_db.characterFolderMembers).insertOnConflictUpdate(
          CharacterFolderMembersCompanion(
            folderId: Value(folderId),
            charId: Value(charId),
            addedAt: Value(currentTimestampSeconds()),
          ),
        );
  }

  Future<void> removeMember(String folderId, String charId) async {
    await (_db.delete(_db.characterFolderMembers)
          ..where((t) => t.folderId.equals(folderId) & t.charId.equals(charId)))
        .go();
  }

  Future<void> deleteMembersForChar(String charId) async {
    await (_db.delete(_db.characterFolderMembers)
          ..where((t) => t.charId.equals(charId)))
        .go();
  }

  Future<List<CharacterFolderMemberRow>> getAllMembers() async {
    return _db.select(_db.characterFolderMembers).get();
  }

  Future<void> upsertFolderRaw(CharacterFolderRow row) async {
    await _db.into(_db.characterFolders).insertOnConflictUpdate(row);
  }

  Future<void> upsertMemberRaw(CharacterFolderMemberRow row) async {
    await _db.into(_db.characterFolderMembers).insertOnConflictUpdate(row);
  }

  Future<void> deleteAllFoldersAndMembers() async {
    await _db.transaction(() async {
      await _db.delete(_db.characterFolderMembers).go();
      await _db.delete(_db.characterFolders).go();
    });
  }

  CharacterFolder _toModel(CharacterFolderRow r) => CharacterFolder(
        id: r.folderId,
        name: r.name,
        color: r.color,
        sortOrder: r.sortOrder,
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
      );
}
