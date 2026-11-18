import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import 'glaze_bottom_sheet.dart';

/// Destructive confirmation: a sheet with [title], [description] and a
/// Delete / Cancel pair. Resolves to true only when the user taps Delete.
Future<bool> confirmDeleteSheet(
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
