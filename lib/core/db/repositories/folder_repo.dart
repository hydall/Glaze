import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../models/folder.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';

/// Generic folders + membership shared by the non-legacy list domains.
///
/// Every query is scoped by [FolderDomain] so the same tables back lorebook,
/// persona, image-style and regex folders without crossing wires.
class FolderRepo {
  final AppDatabase _db;
  FolderRepo(this._db);

  // ── Folders ────────────────────────────────────────────────────────────

  Stream<List<Folder>> watchFolders(FolderDomain domain) {
    return (_db.select(_db.folders)
          ..where((t) => t.domain.equals(domain.wireName))
          ..orderBy([
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.createdAt),
          ]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  Future<List<Folder>> getFolders(FolderDomain domain) async {
    final rows =
        await (_db.select(_db.folders)
              ..where((t) => t.domain.equals(domain.wireName))
              ..orderBy([
                (t) => OrderingTerm.asc(t.sortOrder),
                (t) => OrderingTerm.asc(t.createdAt),
              ]))
            .get();
    return rows.map(_toModel).toList();
  }

  Future<Folder> create({
    required FolderDomain domain,
    required String name,
    String? color,
  }) async {
    final now = currentTimestampSeconds();
    final folder = Folder(
      id: generateId(),
      domain: domain,
      name: name,
      color: color,
      sortOrder: now,
      createdAt: now,
      updatedAt: now,
    );
    await _db
        .into(_db.folders)
        .insert(
          FoldersCompanion(
            folderId: Value(folder.id),
            domain: Value(folder.domain.wireName),
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
    await (_db.update(_db.folders)..where((t) => t.folderId.equals(folderId)))
        .write(
          FoldersCompanion(
            name: Value(name),
            updatedAt: Value(currentTimestampSeconds()),
          ),
        );
  }

  /// Deletes the folder and its membership rows (members are untouched).
  Future<void> delete(String folderId) async {
    await _db.transaction(() async {
      await (_db.delete(
        _db.folderMembers,
      )..where((t) => t.folderId.equals(folderId))).go();
      await (_db.delete(
        _db.folders,
      )..where((t) => t.folderId.equals(folderId))).go();
    });
  }

  // ── Membership ─────────────────────────────────────────────────────────

  /// Member rows belonging to [domain], resolved by joining the folder table.
  Stream<List<FolderMemberRow>> watchMembers(FolderDomain domain) {
    final query =
        _db.select(_db.folderMembers).join([
            innerJoin(
              _db.folders,
              _db.folders.folderId.equalsExp(_db.folderMembers.folderId),
            ),
          ])
          ..where(_db.folders.domain.equals(domain.wireName));
    return query.watch().map(
      (rows) => rows.map((row) => row.readTable(_db.folderMembers)).toList(),
    );
  }

  /// Idempotent: re-adding a member already in the folder is a no-op, which
  /// enforces the "no duplicates within a folder" rule (composite PK).
  Future<void> addMember(String folderId, String memberId) async {
    await _db
        .into(_db.folderMembers)
        .insertOnConflictUpdate(
          FolderMembersCompanion(
            folderId: Value(folderId),
            memberId: Value(memberId),
            addedAt: Value(currentTimestampSeconds()),
          ),
        );
  }

  Future<void> removeMember(String folderId, String memberId) async {
    await (_db.delete(_db.folderMembers)..where(
          (t) => t.folderId.equals(folderId) & t.memberId.equals(memberId),
        ))
        .go();
  }

  /// Drops every membership row for one member across [domain]. Called when the
  /// member itself is deleted so folders don't keep dangling members.
  Future<void> deleteMembersForMember(
    FolderDomain domain,
    String memberId,
  ) async {
    final folderIds =
        _db.selectOnly(_db.folders)
          ..addColumns([_db.folders.folderId])
          ..where(_db.folders.domain.equals(domain.wireName));
    await (_db.delete(_db.folderMembers)..where(
          (t) => t.memberId.equals(memberId) & t.folderId.isInQuery(folderIds),
        ))
        .go();
  }

  // ── Whole-collection access (cloud sync / backup) ──────────────────────

  /// Every folder across all domains. Used by the cloud-sync singleton store.
  Future<List<Folder>> getAllFolders() async {
    final rows =
        await (_db.select(_db.folders)..orderBy([
              (t) => OrderingTerm.asc(t.domain),
              (t) => OrderingTerm.asc(t.sortOrder),
              (t) => OrderingTerm.asc(t.createdAt),
            ]))
            .get();
    return rows.map(_toModel).toList();
  }

  /// Every membership row across all domains.
  Future<List<FolderMemberRow>> getAllMembers() =>
      _db.select(_db.folderMembers).get();

  Future<void> upsertFolderRaw(FolderRow row) async {
    await _db.into(_db.folders).insertOnConflictUpdate(row);
  }

  Future<void> upsertMemberRaw(FolderMemberRow row) async {
    await _db.into(_db.folderMembers).insertOnConflictUpdate(row);
  }

  Future<void> deleteAllFoldersAndMembers() async {
    await _db.transaction(() async {
      await _db.delete(_db.folderMembers).go();
      await _db.delete(_db.folders).go();
    });
  }

  Folder _toModel(FolderRow r) => Folder(
    id: r.folderId,
    domain: FolderDomain.fromWireName(r.domain),
    name: r.name,
    color: r.color,
    sortOrder: r.sortOrder,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
  );
}
