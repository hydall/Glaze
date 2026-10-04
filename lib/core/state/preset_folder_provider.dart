import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/repositories/preset_folder_repo.dart';
import '../models/preset_folder.dart';
import 'db_provider.dart';

final presetFolderRepoProvider = Provider<PresetFolderRepo>((ref) {
  return PresetFolderRepo(ref.watch(appDbProvider));
});

/// Reactive list of preset folders, ordered by sortOrder then createdAt.
final presetFoldersProvider = StreamProvider<List<PresetFolder>>((ref) {
  return ref.watch(presetFolderRepoProvider).watchFolders();
});

/// Two-way view of preset-folder membership, derived from the (small) member
/// table. Entries are keyed by [presetMemberKey] so chat and Studio presets
/// never collide.
class PresetFolderMemberships {
  /// folderId → set of member keys.
  final Map<String, Set<String>> byFolder;

  /// member key → set of folder ids.
  final Map<String, Set<String>> byPreset;

  const PresetFolderMemberships({
    required this.byFolder,
    required this.byPreset,
  });

  static const empty = PresetFolderMemberships(byFolder: {}, byPreset: {});

  Set<String> presetsIn(String folderId) => byFolder[folderId] ?? const {};

  Set<String> foldersOf(String presetId, PresetKind kind) =>
      byPreset[presetMemberKey(presetId, kind)] ?? const {};

  int countFor(String folderId) => byFolder[folderId]?.length ?? 0;
}

final presetFolderMembershipsProvider =
    StreamProvider<PresetFolderMemberships>((ref) {
      return ref.watch(presetFolderRepoProvider).watchMembers().map((rows) {
        final byFolder = <String, Set<String>>{};
        final byPreset = <String, Set<String>>{};
        for (final r in rows) {
          final key = presetMemberKey(
            r.presetId,
            PresetKind.fromWireName(r.kind),
          );
          (byFolder[r.folderId] ??= <String>{}).add(key);
          (byPreset[key] ??= <String>{}).add(r.folderId);
        }
        return PresetFolderMemberships(byFolder: byFolder, byPreset: byPreset);
      });
    });
