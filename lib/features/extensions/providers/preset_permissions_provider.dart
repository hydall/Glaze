import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/preset_permissions.dart';
import '../providers/extension_presets_provider.dart';
import '../providers/extensions_settings_provider.dart';

/// Resolved permissions for the currently active preset.
///
/// Falls back to a fully default-deny (no capabilities) [PresetPermissions]
/// when:
///   - extensions are disabled in [ExtensionsSettings],
///   - the active preset id is null/empty,
///   - the preset cannot be found,
///   - or the preset has no permissions field yet (older saves).
///
/// This guarantees that the bridge cannot accidentally gain capabilities
/// for an unknown preset. The user has to opt in explicitly.
final activePresetPermissionsProvider = Provider<PresetPermissions>((ref) {
  final settings = ref.watch(extensionsSettingsProvider);
  if (!settings.enabled) {
    return const PresetPermissions();
  }
  final activeId = settings.activePresetId;
  if (activeId == null || activeId.isEmpty) {
    return const PresetPermissions();
  }
  final presets = ref.watch(extensionPresetsProvider);
  final preset = presets.where((p) => p.id == activeId).firstOrNull;
  return preset?.permissions ?? const PresetPermissions();
});

/// Permissions for a single preset by id. Used by background scripts
/// (afterAssistant, periodic) that always run a specific preset's blocks
/// regardless of the user's current "active" preset selection.
final presetPermissionsByIdProvider =
    Provider.family<PresetPermissions, String>((ref, presetId) {
  final presets = ref.watch(extensionPresetsProvider);
  final preset = presets.where((p) => p.id == presetId).firstOrNull;
  return preset?.permissions ?? const PresetPermissions();
});
