import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/glaze_bottom_sheet.dart';

/// The plain preset's "⋯" menu. Shared by the preset editor's dashboard card
/// and the same button on each row of the preset list, so both entry points
/// offer exactly the same actions. Mirrors [showStudioPresetOptions] for the
/// agentic kind.
///
/// Every action is a callback: the editor applies them to its live (unsaved)
/// state, the list writes straight through to the repository.
void showPresetOptions(
  BuildContext context, {
  /// Bundled featured presets ship with a fixed author and cover image — both
  /// are read-only. Cloning one produces a normal, fully editable preset.
  required bool isFeatured,
  required bool hasImage,
  required bool canDelete,
  required VoidCallback onRename,
  required VoidCallback onSetAuthor,
  required VoidCallback onPickImage,
  required VoidCallback onRemoveImage,
  required VoidCallback onClone,
  required VoidCallback onExport,
  required VoidCallback onDelete,
  VoidCallback? onAddToFolder,
}) {
  void run(VoidCallback action) {
    Navigator.of(context, rootNavigator: true).pop();
    action();
  }

  GlazeBottomSheet.show<void>(
    context,
    title: 'preset_options'.tr(),
    items: [
      BottomSheetItem(
        icon: Icons.drive_file_rename_outline,
        label: 'action_rename'.tr(),
        onTap: () => run(onRename),
      ),
      // Author and cover image are part of a bundled featured preset — the
      // user edits them on a clone, not on the original.
      if (!isFeatured)
        BottomSheetItem(
          icon: Icons.person_outline,
          label: 'action_set_author'.tr(),
          onTap: () => run(onSetAuthor),
        ),
      if (!isFeatured)
        BottomSheetItem(
          icon: Icons.image_outlined,
          label: 'change_image'.tr(),
          onTap: () => run(onPickImage),
        ),
      if (!isFeatured && hasImage)
        BottomSheetItem(
          icon: Icons.hide_image_outlined,
          label: 'action_remove_image'.tr(),
          onTap: () => run(onRemoveImage),
        ),
      BottomSheetItem(
        icon: Icons.copy_outlined,
        label: 'action_clone_block'.tr(),
        onTap: () => run(onClone),
      ),
      if (onAddToFolder != null)
        BottomSheetItem(
          icon: Icons.create_new_folder_outlined,
          label: 'action_add_to_folder'.tr(),
          onTap: () => run(onAddToFolder),
        ),
      BottomSheetItem(
        icon: Icons.upload_file_outlined,
        label: 'action_export_st'.tr(),
        onTap: () => run(onExport),
      ),
      if (canDelete)
        BottomSheetItem(
          icon: Icons.delete_outlined,
          iconColor: const Color(0xFFFF4444),
          label: 'action_delete_msg'.tr(),
          isDestructive: true,
          onTap: () => run(onDelete),
        ),
    ],
  );
}

/// Rename prompt for a plain preset. [onRename] receives the raw value the
/// user confirmed (the editor keeps empty names, falling back to "New Preset").
void showPresetRename(
  BuildContext context, {
  required String currentName,
  required ValueChanged<String> onRename,
}) {
  GlazeBottomSheet.show<void>(
    context,
    title: 'action_rename_preset'.tr(),
    input: BottomSheetInput(
      placeholder: 'Preset name',
      value: currentName,
      confirmLabel: 'Rename',
      onConfirm: (value) {
        Navigator.of(context, rootNavigator: true).pop();
        onRename(value);
      },
    ),
  );
}

/// Author prompt for a plain preset. [onSubmit] receives the trimmed value
/// (empty means "no author").
void showPresetAuthorDialog(
  BuildContext context, {
  required String currentAuthor,
  required ValueChanged<String> onSubmit,
}) {
  GlazeBottomSheet.show<void>(
    context,
    title: 'action_set_author'.tr(),
    input: BottomSheetInput(
      placeholder: 'Author (optional)',
      value: currentAuthor,
      confirmLabel: 'Save',
      onConfirm: (value) {
        Navigator.of(context, rootNavigator: true).pop();
        onSubmit(value.trim());
      },
    ),
  );
}
