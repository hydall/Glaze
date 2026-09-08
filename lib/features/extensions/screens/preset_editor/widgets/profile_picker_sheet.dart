import 'package:flutter/material.dart';

import '../../../../../core/models/api_config.dart';
import '../../../../../shared/theme/app_colors.dart';
import '../../../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../models/connection_profiles.dart';

class ProfilePickerSheet {
  const ProfilePickerSheet._();

  static Future<String?> pick(
    BuildContext context, {
    required ConnectionProfile profile,
    required List<ApiConfig> configs,
    required String current,
  }) async {
    String? pendingSelection = current;
    await GlazeBottomSheet.show<void>(
      context,
      title: 'Профиль "${profile.name}"',
      items: [
        BottomSheetItem(
          label: 'Использовать основной',
          icon: current.isEmpty
              ? Icons.radio_button_checked
              : Icons.radio_button_off,
          iconColor: current.isEmpty
              ? context.cs.primary
              : context.cs.onSurfaceVariant,
          onTap: () {
            pendingSelection = '';
            Navigator.of(context, rootNavigator: true).pop();
          },
        ),
        ...configs.map((cfg) {
          final name = cfg.name.isNotEmpty ? cfg.name : 'Без имени';
          return BottomSheetItem(
            label: name,
            icon: cfg.id == current
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            iconColor: cfg.id == current
                ? context.cs.primary
                : context.cs.onSurfaceVariant,
            onTap: () {
              pendingSelection = cfg.id;
              Navigator.of(context, rootNavigator: true).pop();
            },
          );
        }),
      ],
    );
    return pendingSelection;
  }
}
