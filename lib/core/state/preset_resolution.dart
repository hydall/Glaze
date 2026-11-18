import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/preset.dart';
import 'active_selection_provider.dart';
import '../../features/presets/preset_list_provider.dart';

/// Returns the effective [Preset] for a given chat context.
///
/// Priority (mirrors JS Glaze):
///   1. Chat-level binding  (`connections.chat[sessionId]`)
///   2. Character-level binding (`connections.character[charId]`)
///   3. Global active preset (`activePresetId`)
///   4. First available preset
Preset? getEffectivePreset(
  List<Preset> presets,
  String? charId,
  String? sessionId,
  String? globalPresetId,
  PresetConnections connections,
) {
  if (sessionId != null) {
    final id = connections.chat[sessionId];
    if (id != null) {
      final p = presets.where((p) => p.id == id).firstOrNull;
      if (p != null) return p;
    }
  }
  if (charId != null) {
    final id = connections.character[charId];
    if (id != null) {
      final p = presets.where((p) => p.id == id).firstOrNull;
      if (p != null) return p;
    }
  }
  if (globalPresetId != null) {
    final p = presets.where((p) => p.id == globalPresetId).firstOrNull;
    if (p != null) return p;
  }
  return presets.isNotEmpty ? presets.first : null;
}

typedef EffectivePresetChatKey = ({String charId, String? sessionId});

/// Provider that reactively resolves the effective preset for a chat context.
///
/// Usage:
/// ```dart
/// final preset = ref.watch(
///   effectivePresetForChatProvider((charId: id, sessionId: sid)),
/// );
/// ```
final effectivePresetForChatProvider =
    Provider.family<Preset?, EffectivePresetChatKey>((ref, key) {
  final presetsAsync = ref.watch(presetListProvider);
  if (!presetsAsync.hasValue) return null;

  final globalPresetId = ref.watch(activePresetIdProvider);
  final connections = ref.watch(presetConnectionsProvider);
  return getEffectivePreset(
    presetsAsync.requireValue,
    key.charId,
    key.sessionId,
    globalPresetId,
    connections,
  );
});
