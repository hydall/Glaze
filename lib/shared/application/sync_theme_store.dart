import '../theme/theme_preset.dart';

abstract class SyncThemePresetStore {
  Future<List<ThemePreset>> getAll();
  Future<void> putAll(List<ThemePreset> presets);
}
