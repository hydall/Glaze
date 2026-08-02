import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/models/studio_config.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';

/// Overflow menu behind the agentic preset dashboard's three-dot button —
/// the agentic counterpart of the plain preset editor's options sheet.
void showStudioPresetOptions(
  BuildContext context, {
  required StudioPreset preset,
  required VoidCallback onRename,
  required VoidCallback onClone,
  required VoidCallback onExport,
  required VoidCallback onDelete,

  /// Omitted where folders don't apply (e.g. the editor opened outside the
  /// preset list).
  VoidCallback? onAddToFolder,
}) {
  GlazeBottomSheet.show<void>(
    context,
    title: 'preset_options'.tr(),
    items: [
      BottomSheetItem(
        icon: Icons.drive_file_rename_outline,
        label: 'action_rename'.tr(),
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          onRename();
        },
      ),
      BottomSheetItem(
        icon: Icons.copy_outlined,
        label: 'action_clone_block'.tr(),
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          onClone();
        },
      ),
      if (onAddToFolder != null)
        BottomSheetItem(
          icon: Icons.create_new_folder_outlined,
          label: 'action_add_to_folder'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            onAddToFolder();
          },
        ),
      BottomSheetItem(
        icon: Icons.upload_file_outlined,
        label: 'action_export_st'.tr(),
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          onExport();
        },
      ),
      // The built-in `default` preset is re-seeded on demand, so deleting it
      // would only look like it worked.
      if (preset.id != 'default')
        BottomSheetItem(
          icon: Icons.delete_outlined,
          iconColor: const Color(0xFFFF4444),
          label: 'action_delete'.tr(),
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            onDelete();
          },
        ),
    ],
  );
}

/// Rename prompt for an agentic preset. [onRename] receives the trimmed,
/// non-empty name.
void showStudioPresetRename(
  BuildContext context, {
  required StudioPreset preset,
  required ValueChanged<String> onRename,
}) {
  GlazeBottomSheet.show<void>(
    context,
    title: 'action_rename_preset'.tr(),
    input: BottomSheetInput(
      placeholder: 'placeholder_preset_name'.tr(),
      value: preset.name,
      confirmLabel: 'action_rename'.tr(),
      onConfirm: (value) {
        Navigator.of(context, rootNavigator: true).pop();
        final name = value.trim();
        if (name.isNotEmpty) onRename(name);
      },
    ),
  );
}

/// Destructive confirmation shared by "delete preset" and "delete block".
/// Resolves to true only when the user taps Delete.
Future<bool> confirmStudioDelete(
  BuildContext context, {
  required String title,
  required String description,
}) async {
  final confirmed = await GlazeBottomSheet.show<bool>(
    context,
    title: title,
    bigInfo: BottomSheetBigInfo(
      icon: Icons.delete_outline,
      description: description,
    ),
    items: [
      BottomSheetItem(
        label: 'action_delete'.tr(),
        centered: true,
        isDestructive: true,
        onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
      ),
      BottomSheetItem(
        label: 'action_cancel'.tr(),
        centered: true,
        onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
      ),
    ],
  );
  return confirmed == true;
}
