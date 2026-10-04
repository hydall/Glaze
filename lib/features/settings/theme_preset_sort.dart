import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/state/preset_sort.dart';
import '../../shared/theme/theme_preset.dart';

/// The user's own theme list runs on the shared preset sort, like every other
/// preset list. Built-in catalog themes have no stored order, so only the
/// "My Themes" tab offers a sort control.
final themePresetSortProvider =
    AsyncNotifierProvider<PresetSortNotifier, PresetSortState>(
      () => PresetSortNotifier(
        modeKey: 'themePresetListSortMode',
        orderKey: 'themePresetListManualOrder',
      ),
    );

/// Text a theme is sorted by.
String themePresetSortName(ThemePreset preset) => preset.name;

/// When a theme was added. A theme the user made carries its creation time in
/// its `custom_<millis>` id; imported and built-in ones bring ids of their own,
/// so they sort as the oldest, in the order the source returned them.
int themePresetCreatedAt(ThemePreset preset) {
  final id = preset.id;
  if (!id.startsWith('custom_')) return 0;
  return int.tryParse(id.substring('custom_'.length)) ?? 0;
}

List<ThemePreset> sortThemePresets(
  List<ThemePreset> presets,
  PresetSortState state,
) => sortPresetItems(
  presets,
  state,
  idOf: (p) => p.id,
  nameOf: themePresetSortName,
  createdAtOf: themePresetCreatedAt,
);
