import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/preset_folder.dart';
import '../../../core/state/preset_folder_provider.dart';
import '../../../shared/widgets/folder_name_dialog.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import 'preset_folder_card.dart';

/// Folders block of the Presets list: one card per folder, stacked above the
/// preset rows and pinned there — folders are never reordered or re-sorted with
/// the presets below them. Tapping opens a folder; the row's "⋯" (or a long
/// press) exposes rename/delete. New folders are created from the screen's Add
/// sheet, not here.
class PresetFoldersSection extends ConsumerWidget {
  final ValueChanged<String> onOpenFolder;

  const PresetFoldersSection({super.key, required this.onOpenFolder});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(presetFoldersProvider).value ?? const [];
    if (folders.isEmpty) return const SizedBox.shrink();

    final memberships =
        ref.watch(presetFolderMembershipsProvider).value ??
        PresetFolderMemberships.empty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final folder in folders)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: PresetFolderCard(
              folder: folder,
              count: memberships.countFor(folder.id),
              onTap: () => onOpenFolder(folder.id),
              onMenu: () => showPresetFolderActions(context, ref, folder),
            ),
          ),
      ],
    );
  }
}

/// Rename / delete actions for [folder]. Shared with the folder view's header
/// menu so both entry points offer the same operations.
void showPresetFolderActions(
  BuildContext context,
  WidgetRef ref,
  PresetFolder folder, {
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
                  ref.read(presetFolderRepoProvider).rename(folder.id, name),
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
  PresetFolder folder,
  VoidCallback? onDeleted,
) {
  GlazeBottomSheet.show<void>(
    context,
    title: 'folder_delete_title'.tr(),
    bigInfo: BottomSheetBigInfo(
      icon: Icons.delete_outline,
      description: 'preset_folder_delete_confirm'.tr(),
    ),
    items: [
      BottomSheetItem(
        label: 'btn_delete'.tr(),
        isDestructive: true,
        centered: true,
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          // Fire-and-forget: the folders stream repaints the strip when the
          // rows land.
          ref.read(presetFolderRepoProvider).delete(folder.id);
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
