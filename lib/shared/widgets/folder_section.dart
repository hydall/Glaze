import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/folder.dart';
import '../../core/state/folder_provider.dart';
import '../theme/app_colors.dart';
import 'folder_card.dart';
import 'folder_name_dialog.dart';
import 'glaze_bottom_sheet.dart';

/// The folders block of a list that uses the shared folder layer: one card per
/// folder, stacked above the items and pinned there. Tapping opens the folder;
/// the row's "⋯" (or a long press) exposes rename/delete.
class FolderSection extends ConsumerWidget {
  final FolderDomain domain;
  final ValueChanged<String> onOpenFolder;

  /// Leading glyph shared by every folder in this list.
  final IconData icon;

  const FolderSection({
    super.key,
    required this.domain,
    required this.onOpenFolder,
    this.icon = Icons.folder_rounded,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(foldersProvider(domain)).value ?? const [];
    if (folders.isEmpty) return const SizedBox.shrink();
    final memberships =
        ref.watch(folderMembershipsProvider(domain)).value ??
        FolderMemberships.empty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final folder in folders)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: FolderCard(
              name: folder.name,
              icon: icon,
              count: memberships.countFor(folder.id),
              onTap: () => onOpenFolder(folder.id),
              onMenu: () => showFolderActions(context, ref, folder),
            ),
          ),
      ],
    );
  }
}

/// Opens the create-folder name dialog for [domain].
Future<void> showCreateFolderDialog(
  BuildContext context,
  WidgetRef ref,
  FolderDomain domain, {
  VoidCallback? onCreated,
}) {
  return GlazeBottomSheet.show<void>(
    context,
    title: 'folder_create_title'.tr(),
    child: FolderNameDialog(
      confirmLabel: 'btn_create'.tr(),
      onSubmit: (name) async {
        await ref.read(folderRepoProvider).create(domain: domain, name: name);
        onCreated?.call();
      },
    ),
  );
}

/// Rename / delete actions for [folder].
void showFolderActions(
  BuildContext context,
  WidgetRef ref,
  Folder folder, {
  VoidCallback? onDeleted,
}) {
  GlazeBottomSheet.show<void>(
    context,
    title: folder.name,
    items: [
      BottomSheetItem(
        icon: Icons.edit_rounded,
        label: 'folder_rename_title'.tr(),
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          GlazeBottomSheet.show<void>(
            context,
            title: 'folder_rename_title'.tr(),
            child: FolderNameDialog(
              initialName: folder.name,
              confirmLabel: 'btn_save'.tr(),
              onSubmit: (name) =>
                  ref.read(folderRepoProvider).rename(folder.id, name),
            ),
          );
        },
      ),
      BottomSheetItem(
        icon: Icons.delete_rounded,
        label: 'folder_delete_title'.tr(),
        isDestructive: true,
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          _confirmDelete(context, ref, folder, onDeleted);
        },
      ),
    ],
  );
}

void _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  Folder folder,
  VoidCallback? onDeleted,
) {
  GlazeBottomSheet.show<void>(
    context,
    title: 'folder_delete_title'.tr(),
    bigInfo: BottomSheetBigInfo(
      icon: Icons.delete_outline,
      description: 'folder_delete_confirm_items'.tr(),
    ),
    items: [
      BottomSheetItem(
        label: 'btn_delete'.tr(),
        isDestructive: true,
        centered: true,
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          ref.read(folderRepoProvider).delete(folder.id);
          onDeleted?.call();
        },
      ),
      BottomSheetItem(
        label: 'btn_cancel'.tr(),
        centered: true,
        onTap: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
    ],
  );
}

/// Bulk "add to folder" sheet: tapping a folder adds every id in [targets] to
/// it at once, then closes and runs [onDone].
Future<void> showAddToFolderSheet(
  BuildContext context, {
  required FolderDomain domain,
  required List<String> targets,
  VoidCallback? onDone,
}) {
  return GlazeBottomSheet.show<void>(
    context,
    title: 'action_add_to_folder'.tr(),
    child: _AddToFolderSheet(
      domain: domain,
      targets: targets,
      onDone: onDone,
    ),
  );
}

class _AddToFolderSheet extends ConsumerWidget {
  final FolderDomain domain;
  final List<String> targets;
  final VoidCallback? onDone;

  const _AddToFolderSheet({
    required this.domain,
    required this.targets,
    this.onDone,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(foldersProvider(domain)).value ?? const [];
    final memberships =
        ref.watch(folderMembershipsProvider(domain)).value ??
        FolderMemberships.empty;
    final repo = ref.read(folderRepoProvider);

    Future<void> addAllTo(String folderId) async {
      for (final id in targets) {
        await repo.addMember(folderId, id);
      }
    }

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        _NewFolderTile(
          onTap: () => GlazeBottomSheet.show<void>(
            context,
            title: 'folder_create_title'.tr(),
            child: FolderNameDialog(
              confirmLabel: 'btn_create'.tr(),
              onSubmit: (name) async {
                final folder = await repo.create(domain: domain, name: name);
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
                'folder_empty_items'.tr(),
                style: TextStyle(color: context.cs.onSurfaceVariant),
              ),
            ),
          ),
        for (final folder in folders)
          _FolderTile(
            name: folder.name,
            count: memberships.countFor(folder.id),
            onTap: () async {
              await addAllTo(folder.id);
              if (context.mounted) {
                Navigator.of(context, rootNavigator: true).pop();
              }
              onDone?.call();
            },
          ),
      ],
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
                Icon(
                  Icons.create_new_folder_rounded,
                  size: 20,
                  color: context.cs.primary,
                ),
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

class _FolderTile extends StatelessWidget {
  final String name;
  final int count;
  final VoidCallback onTap;

  const _FolderTile({
    required this.name,
    required this.count,
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
                  color: context.cs.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, color: context.cs.onSurface),
                  ),
                ),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.onSurfaceVariant,
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

/// Empty state shown inside a folder that has no members.
class FolderEmptyState extends StatelessWidget {
  const FolderEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Text(
          'folder_empty_items'.tr(),
          style: TextStyle(color: context.cs.onSurfaceVariant),
        ),
      ),
    );
  }
}
