import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/repositories/character_folder_repo.dart';
import '../models/character_folder.dart';
import 'db_provider.dart';

/// Sentinel id for the virtual "Favorites" folder. It is not a real folder
/// (no row in `character_folders`); it surfaces every favorited character and
/// cannot be renamed, deleted, or have membership edited through the folder UI.
/// Membership is driven purely by each character's `fav` flag.
const kFavoritesFolderId = '__favorites__';

/// Sentinel id for the virtual "Our Picks" folder. Like Favorites it is not a
/// real folder: its contents come from the remote curated catalog, so it cannot
/// be renamed and characters can't be added to or removed from it. The only
/// folder action it offers is hiding it (`showOurPicks` app setting).
const kPicksFolderId = '__picks__';

final characterFolderRepoProvider = Provider<CharacterFolderRepo>((ref) {
  return CharacterFolderRepo(ref.watch(appDbProvider));
});

/// Reactive list of user folders, ordered by sortOrder then createdAt.
final characterFoldersProvider = StreamProvider<List<CharacterFolder>>((ref) {
  return ref.watch(characterFolderRepoProvider).watchFolders();
});

/// Two-way view of folder membership, derived from the (small) member table.
class FolderMemberships {
  /// folderId → set of character ids.
  final Map<String, Set<String>> byFolder;

  /// characterId → set of folder ids.
  final Map<String, Set<String>> byChar;

  const FolderMemberships({required this.byFolder, required this.byChar});

  static const empty = FolderMemberships(byFolder: {}, byChar: {});

  Set<String> charsIn(String folderId) => byFolder[folderId] ?? const {};

  Set<String> foldersOf(String charId) => byChar[charId] ?? const {};

  int countFor(String folderId) => byFolder[folderId]?.length ?? 0;
}

final folderMembershipsProvider = StreamProvider<FolderMemberships>((ref) {
  return ref.watch(characterFolderRepoProvider).watchMembers().map((rows) {
    final byFolder = <String, Set<String>>{};
    final byChar = <String, Set<String>>{};
    for (final r in rows) {
      (byFolder[r.folderId] ??= <String>{}).add(r.charId);
      (byChar[r.charId] ??= <String>{}).add(r.folderId);
    }
    return FolderMemberships(byFolder: byFolder, byChar: byChar);
  });
});
