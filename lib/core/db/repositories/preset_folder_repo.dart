import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../models/preset_folder.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';

/// Folders for the Presets list. Mirrors [CharacterFolderRepo]; membership rows
/// carry a `kind` so chat presets and Studio (agentic) presets can share a
/// folder without their independent id spaces colliding.
class PresetFolderRepo {
  final AppDatabase _db;
  PresetFolderRepo(this._db);

  // ── Folders ────────────────────────────────────────────────────────────

  Stream<List<PresetFolder>> watchFolders() {
    return (_db.select(_db.presetFolders)
          ..orderBy([
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.createdAt),
          ]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  Future<List<PresetFolder>> getFolders() async {
    final rows = await (_db.select(_db.presetFolders)
          ..orderBy([
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.createdAt),
          ]))
        .get();
    return rows.map(_toModel).toList();
  }

  Future<PresetFolder> create({required String name, String? color}) async {
    final now = currentTimestampSeconds();
    final folder = PresetFolder(
      id: generateId(),
      name: name,
      color: color,
      sortOrder: now,
      createdAt: now,
      updatedAt: now,
    );
    await _db
        .into(_db.presetFolders)
        .insert(
          PresetFoldersCompanion(
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
    await (_db.update(_db.presetFolders)
          ..where((t) => t.folderId.equals(folderId)))
        .write(
          PresetFoldersCompanion(
            name: Value(name),
            updatedAt: Value(currentTimestampSeconds()),
          ),
        );
  }

  /// Deletes the folder and its membership rows (presets are untouched).
  Future<void> delete(String folderId) async {
    await _db.transaction(() async {
      await (_db.delete(_db.presetFolderMembers)
            ..where((t) => t.folderId.equals(folderId)))
          .go();
      await (_db.delete(_db.presetFolders)
            ..where((t) => t.folderId.equals(folderId)))
          .go();
    });
  }

  // ── Membership ─────────────────────────────────────────────────────────

  Stream<List<PresetFolderMemberRow>> watchMembers() {
    return _db.select(_db.presetFolderMembers).watch();
  }

  /// Idempotent: re-adding a preset already in the folder is a no-op, which
  /// enforces the "no duplicates within a folder" rule (composite PK).
  Future<void> addMember(
    String folderId,
    String presetId,
    PresetKind kind,
  ) async {
    await _db
        .into(_db.presetFolderMembers)
        .insertOnConflictUpdate(
          PresetFolderMembersCompanion(
            folderId: Value(folderId),
            presetId: Value(presetId),
            kind: Value(kind.wireName),
            addedAt: Value(currentTimestampSeconds()),
          ),
        );
  }

  Future<void> removeMember(
    String folderId,
    String presetId,
    PresetKind kind,
  ) async {
    await (_db.delete(_db.presetFolderMembers)..where(
          (t) =>
              t.folderId.equals(folderId) &
              t.presetId.equals(presetId) &
              t.kind.equals(kind.wireName),
        ))
        .go();
  }

  /// Drops every membership row for a preset — called when the preset itself is
  /// deleted so folders don't keep dangling members.
  Future<void> deleteMembersForPreset(String presetId, PresetKind kind) async {
    await (_db.delete(_db.presetFolderMembers)..where(
          (t) => t.presetId.equals(presetId) & t.kind.equals(kind.wireName),
        ))
        .go();
  }

  PresetFolder _toModel(PresetFolderRow r) => PresetFolder(
    id: r.folderId,
    name: r.name,
    color: r.color,
    sortOrder: r.sortOrder,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
  );
}
