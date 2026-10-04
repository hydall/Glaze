import '../../../core/application/sync_repo_interfaces.dart';
import '../../../core/db/app_db.dart';
import '../../../core/db/repositories/folder_repo.dart';
import '../../../core/db/repositories/preset_folder_repo.dart';

/// Cloud-sync / backup adapter for the generic folder tables and the preset
/// folders. One singleton payload covers every folder domain; each collection
/// is replaced wholesale on apply, the same contract character folders use.
class FolderSyncStore implements SyncFolderStore {
  final AppDatabase _db;
  final FolderRepo _genericRepo;
  final PresetFolderRepo _presetRepo;

  FolderSyncStore(this._db, this._genericRepo, this._presetRepo);

  @override
  Future<Map<String, dynamic>> getAll() async {
    final genericFolders = await _genericRepo.getAllFolders();
    final genericMembers = await _genericRepo.getAllMembers();
    final presetFolders = await _presetRepo.getFolders();
    final presetMembers = await _presetRepo.getAllMembers();
    return {
      '__folders': true,
      'genericFolders': [
        for (final f in genericFolders)
          {
            'folderId': f.id,
            'domain': f.domain.wireName,
            'name': f.name,
            'color': f.color,
            'sortOrder': f.sortOrder,
            'createdAt': f.createdAt,
            'updatedAt': f.updatedAt,
          },
      ],
      'genericMembers': [
        for (final m in genericMembers)
          {
            'folderId': m.folderId,
            'memberId': m.memberId,
            'addedAt': m.addedAt,
          },
      ],
      'presetFolders': [
        for (final f in presetFolders)
          {
            'folderId': f.id,
            'name': f.name,
            'color': f.color,
            'sortOrder': f.sortOrder,
            'createdAt': f.createdAt,
            'updatedAt': f.updatedAt,
          },
      ],
      'presetMembers': [
        for (final m in presetMembers)
          {
            'folderId': m.folderId,
            'presetId': m.presetId,
            'kind': m.kind,
            'addedAt': m.addedAt,
          },
      ],
    };
  }

  @override
  Future<void> applyAll(Map<String, dynamic> data) async {
    await _db.transaction(() async {
      await _genericRepo.deleteAllFoldersAndMembers();
      await _presetRepo.deleteAllFoldersAndMembers();

      for (final json in _maps(data['genericFolders'])) {
        await _genericRepo.upsertFolderRaw(
          FolderRow(
            folderId: json['folderId'] as String? ?? '',
            domain: json['domain'] as String? ?? '',
            name: json['name'] as String? ?? '',
            color: json['color'] as String?,
            sortOrder: json['sortOrder'] as int? ?? 0,
            createdAt: json['createdAt'] as int? ?? 0,
            updatedAt: json['updatedAt'] as int? ?? 0,
          ),
        );
      }
      for (final json in _maps(data['genericMembers'])) {
        await _genericRepo.upsertMemberRaw(
          FolderMemberRow(
            folderId: json['folderId'] as String? ?? '',
            memberId: json['memberId'] as String? ?? '',
            addedAt: json['addedAt'] as int? ?? 0,
          ),
        );
      }
      for (final json in _maps(data['presetFolders'])) {
        await _presetRepo.upsertFolderRaw(
          PresetFolderRow(
            folderId: json['folderId'] as String? ?? '',
            name: json['name'] as String? ?? '',
            color: json['color'] as String?,
            sortOrder: json['sortOrder'] as int? ?? 0,
            createdAt: json['createdAt'] as int? ?? 0,
            updatedAt: json['updatedAt'] as int? ?? 0,
          ),
        );
      }
      for (final json in _maps(data['presetMembers'])) {
        await _presetRepo.upsertMemberRaw(
          PresetFolderMemberRow(
            folderId: json['folderId'] as String? ?? '',
            presetId: json['presetId'] as String? ?? '',
            kind: json['kind'] as String? ?? 'normal',
            addedAt: json['addedAt'] as int? ?? 0,
          ),
        );
      }
    });
  }

  static List<Map<String, dynamic>> _maps(Object? raw) =>
      (raw as List?)
          ?.whereType<Map<dynamic, dynamic>>()
          .map((m) => m.cast<String, dynamic>())
          .toList() ??
      const [];
}
