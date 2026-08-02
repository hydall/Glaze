import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/preset_folder.dart';
import '../../../core/state/preset_folder_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/folder_name_dialog.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';

/// Folders strip for the Presets list: a horizontal row of circular folder
/// covers. Tapping opens a folder; long-pressing exposes rename/delete. New
/// folders are created from the screen's Add sheet, not here.
///
/// Mirrors `CharacterFoldersSection`, minus the character-specific virtual
/// folders (Favorites / Our Picks) and avatar covers — presets have no images,
/// so each circle shows the folder glyph with its member count.
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

    return SizedBox(
      height: 104,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
        itemCount: folders.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (_, i) {
          final folder = folders[i];
          return _FolderCircle(
            folder: folder,
            count: memberships.countFor(folder.id),
            onTap: () => onOpenFolder(folder.id),
            onLongPress: () => showPresetFolderActions(context, ref, folder),
          );
        },
      ),
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

class _FolderCircle extends StatelessWidget {
  static const double _diameter = 64;

  final PresetFolder folder;
  final int count;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _FolderCircle({
    required this.folder,
    required this.count,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: _diameter,
              height: _diameter,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    context.cs.primary.withValues(alpha: 0.35),
                    context.cs.surfaceContainerHighest,
                  ],
                ),
                border: Border.all(
                  color: context.cs.primary.withValues(alpha: 0.25),
                  width: 2,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.folder_rounded,
                    size: 24,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.white.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              folder.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
