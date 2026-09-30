import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/repositories/folder_repo.dart';
import '../models/folder.dart';
import 'db_provider.dart';

final folderRepoProvider = Provider<FolderRepo>((ref) {
  return FolderRepo(ref.watch(appDbProvider));
});

/// Reactive list of folders in one [FolderDomain], ordered by sortOrder then
/// createdAt.
final foldersProvider = StreamProvider.family<List<Folder>, FolderDomain>((
  ref,
  domain,
) {
  return ref.watch(folderRepoProvider).watchFolders(domain);
});

/// Two-way view of folder membership within one [FolderDomain].
class FolderMemberships {
  /// folderId → set of member ids.
  final Map<String, Set<String>> byFolder;

  /// memberId → set of folder ids.
  final Map<String, Set<String>> byMember;

  const FolderMemberships({required this.byFolder, required this.byMember});

  static const empty = FolderMemberships(byFolder: {}, byMember: {});

  Set<String> membersIn(String folderId) => byFolder[folderId] ?? const {};

  Set<String> foldersOf(String memberId) => byMember[memberId] ?? const {};

  int countFor(String folderId) => byFolder[folderId]?.length ?? 0;
}

final folderMembershipsProvider =
    StreamProvider.family<FolderMemberships, FolderDomain>((ref, domain) {
      return ref.watch(folderRepoProvider).watchMembers(domain).map((rows) {
        final byFolder = <String, Set<String>>{};
        final byMember = <String, Set<String>>{};
        for (final r in rows) {
          (byFolder[r.folderId] ??= <String>{}).add(r.memberId);
          (byMember[r.memberId] ??= <String>{}).add(r.folderId);
        }
        return FolderMemberships(byFolder: byFolder, byMember: byMember);
      });
    });
