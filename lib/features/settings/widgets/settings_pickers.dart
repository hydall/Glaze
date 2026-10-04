import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/theme_provider.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../app_settings_provider.dart';
import 'chat_layout_picker.dart';

/// The bottom-sheet pickers behind the settings rows that carry a value rather
/// than a switch. Extracted from the screen so it stays a thin orchestrator.

String themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.dark => 'theme_dark'.tr(),
  ThemeMode.light => 'theme_light'.tr(),
  ThemeMode.system => 'theme_system'.tr(),
};

void showThemeModePicker(BuildContext context, WidgetRef ref) {
  final current = ref.read(themeProvider).mode;
  GlazeBottomSheet.show<void>(
    context,
    title: 'theme_title'.tr(),
    items: ThemeMode.values
        .map(
          (mode) => BottomSheetItem(
            label: themeModeLabel(mode),
            icon: mode == current
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            iconColor: mode == current
                ? context.cs.primary
                : context.cs.onSurfaceVariant,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              ref.read(themeProvider.notifier).setMode(mode);
            },
          ),
        )
        .toList(),
  );
}

String batterySaverModeLabel(BatterySaverMode mode) => switch (mode) {
  BatterySaverMode.system => 'battery_saver_system'.tr(),
  BatterySaverMode.on => 'battery_saver_on'.tr(),
  BatterySaverMode.off => 'battery_saver_off'.tr(),
};

void showBatterySaverModePicker(
  BuildContext context,
  WidgetRef ref,
  AppSettings s,
) {
  GlazeBottomSheet.show<void>(
    context,
    title: 'menu_battery_saver_ui'.tr(),
    items: BatterySaverMode.values
        .map(
          (mode) => BottomSheetItem(
            label: batterySaverModeLabel(mode),
            icon: mode == s.batterySaverMode
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            iconColor: mode == s.batterySaverMode
                ? context.cs.primary
                : context.cs.onSurfaceVariant,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              ref
                  .read(appSettingsProvider.notifier)
                  .setBatterySaverMode(mode);
            },
          ),
        )
        .toList(),
  );
}

void showLanguagePicker(BuildContext context, WidgetRef ref, AppSettings s) {
  BottomSheetItem languageItem(String code, String label) => BottomSheetItem(
    label: label,
    icon: s.language == code
        ? Icons.radio_button_checked
        : Icons.radio_button_off,
    iconColor: s.language == code
        ? context.cs.primary
        : context.cs.onSurfaceVariant,
    onTap: () {
      Navigator.of(context, rootNavigator: true).pop();
      ref.read(appSettingsProvider.notifier).save(s.copyWith(language: code));
    },
  );

  GlazeBottomSheet.show<void>(
    context,
    title: 'menu_language'.tr(),
    items: [languageItem('en', 'English'), languageItem('ru', 'Русский')],
  );
}

void showLayoutPicker(BuildContext context, WidgetRef ref) {
  final preset = ref.read(themeProvider).activePreset;
  showChatLayoutPicker(
    context,
    current: preset.chatLayout,
    onSelect: (layout) => ref
        .read(themeProvider.notifier)
        .updatePreset(preset.copyWith(chatLayout: layout)),
  );
}
