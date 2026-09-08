import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/character_folder_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/sheet_view.dart';
import 'folder_name_dialog.dart';

/// Multi-select sheet to toggle a character's folder memberships. A character
/// may be in many folders; tapping a row toggles that membership immediately
/// (the sheet stays open). Adding to a folder it's already in is a no-op.
class AddToFolderSheet extends ConsumerWidget {
  final String characterId;

  const AddToFolderSheet({super.key, required this.characterId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(characterFoldersProvider).value ?? const [];
    final memberships =
        ref.watch(folderMembershipsProvider).value ?? FolderMemberships.empty;
    final selected = memberships.foldersOf(characterId);
    final repo = ref.read(characterFolderRepoProvider);

    return SheetView(
      title: 'action_add_to_folder'.tr(),
      showHandle: true,
      bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          _NewFolderTile(
            onTap: () => GlazeBottomSheet.show<void>(
              context,
              title: 'folder_create_title'.tr(),
              child: FolderNameDialog(
                confirmLabel: 'btn_create'.tr(),
                onSubmit: (name) async {
                  final folder = await repo.create(name: name);
                  await repo.addMember(folder.id, characterId);
                },
              ),
            ),
          ),
          if (folders.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'folder_empty'.tr(),
                  style: TextStyle(color: context.cs.onSurfaceVariant),
                ),
              ),
            ),
          for (final folder in folders)
            _FolderToggleTile(
              name: folder.name,
              count: memberships.countFor(folder.id),
              selected: selected.contains(folder.id),
              onTap: () {
                if (selected.contains(folder.id)) {
                  repo.removeMember(folder.id, characterId);
                } else {
                  repo.addMember(folder.id, characterId);
                }
              },
            ),
        ],
      ),
    );
  }
}

/// Bulk variant of [AddToFolderSheet]: tapping a folder adds every character in
/// [characterIds] to it at once, then closes the sheet and runs [onDone].
class AddCharactersToFolderSheet extends ConsumerWidget {
  final Set<String> characterIds;
  final VoidCallback? onDone;

  const AddCharactersToFolderSheet({
    super.key,
    required this.characterIds,
    this.onDone,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(characterFoldersProvider).value ?? const [];
    final memberships =
        ref.watch(folderMembershipsProvider).value ?? FolderMemberships.empty;
    final repo = ref.read(characterFolderRepoProvider);

    Future<void> addAllTo(String folderId) async {
      for (final id in characterIds) {
        await repo.addMember(folderId, id);
      }
    }

    return SheetView(
      title: 'action_add_to_folder'.tr(),
      showHandle: true,
      bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          _NewFolderTile(
            onTap: () => GlazeBottomSheet.show<void>(
              context,
              title: 'folder_create_title'.tr(),
              child: FolderNameDialog(
                confirmLabel: 'btn_create'.tr(),
                onSubmit: (name) async {
                  final folder = await repo.create(name: name);
                  await addAllTo(folder.id);
                  onDone?.call();
                },
              ),
            ),
          ),
          if (folders.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'folder_empty'.tr(),
                  style: TextStyle(color: context.cs.onSurfaceVariant),
                ),
              ),
            ),
          for (final folder in folders)
            _FolderToggleTile(
              name: folder.name,
              count: memberships.countFor(folder.id),
              selected: false,
              onTap: () async {
                await addAllTo(folder.id);
                if (context.mounted) {
                  Navigator.of(context, rootNavigator: true).pop();
                }
                onDone?.call();
              },
            ),
        ],
      ),
    );
  }
}

class _NewFolderTile extends StatelessWidget {
  final VoidCallback onTap;
  const _NewFolderTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: context.cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(Icons.create_new_folder_rounded,
                    size: 20, color: context.cs.primary),
                const SizedBox(width: 12),
                Text(
                  'folder_new'.tr(),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: context.cs.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FolderToggleTile extends StatelessWidget {
  final String name;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _FolderToggleTile({
    required this.name,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(
                  Icons.folder_rounded,
                  size: 20,
                  color: selected
                      ? context.cs.primary
                      : context.cs.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      color: context.cs.onSurface,
                    ),
                  ),
                ),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 22,
                  color: selected
                      ? context.cs.primary
                      : context.cs.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
