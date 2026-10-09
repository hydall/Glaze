import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../settings/api_settings_screen.dart';

/// Explains the "Max output tokens reached" chip under a reply: the model was
/// stopped by the output-token cap, not because it had finished. "Edit" opens
/// the API settings on the form that holds Max Tokens.
Future<void> showOutputLimitSheet(BuildContext context) {
  return GlazeBottomSheet.show<void>(
    context,
    title: 'output_limit_title'.tr(),
    bigInfo: BottomSheetBigInfo(
      icon: Icons.warning_amber_rounded,
      description: 'output_limit_desc'.tr(),
      buttonText: 'btn_edit'.tr(),
      buttonIcon: Icons.edit_outlined,
      onButtonTap: () {
        Navigator.of(context, rootNavigator: true).pop();
        unawaited(
          showApiSettingsSheet(
            context,
            focusSection: ApiSettingsSection.context,
          ),
        );
      },
    ),
  );
}
