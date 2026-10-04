part of '../tables.dart';

/// Folders for the generic list domains (lorebooks, personas, image styles,
/// regex scripts…).
///
/// The `domain` column partitions folders per list. Row-level generic so one
/// repo and one set of widgets serve every list; the two legacy folder pairs
/// (`character_folders`, `preset_folders`) predate it and are untouched.
@DataClassName('FolderRow')
@TableIndex(name: 'idx_folders_domain', columns: {#domain})
class Folders extends Table {
  @override
  String get tableName => 'folders';

  TextColumn get folderId => text()();
  TextColumn get domain => text()();
  TextColumn get name => text()();
  TextColumn get color => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {folderId};
}

@DataClassName('FolderMemberRow')
@TableIndex(name: 'idx_folder_members_folder', columns: {#folderId})
@TableIndex(name: 'idx_folder_members_member', columns: {#memberId})
class FolderMembers extends Table {
  @override
  String get tableName => 'folder_members';

  TextColumn get folderId => text()();
  TextColumn get memberId => text()();
  IntColumn get addedAt => integer().withDefault(const Constant(0))();

  // Composite PK: a member can live in many folders, but cannot be duplicated
  // within one folder.
  @override
  Set<Column> get primaryKey => {folderId, memberId};
}
