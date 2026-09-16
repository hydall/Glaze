import 'package:freezed_annotation/freezed_annotation.dart';

import 'block_config.dart';
import 'extension_context_policy.dart';
import 'preset_permissions.dart';

part 'extension_preset.freezed.dart';
part 'extension_preset.g.dart';

@freezed
abstract class ExtensionPreset with _$ExtensionPreset {
  const factory ExtensionPreset({
    required String id,
    required String name,
    required List<BlockConfig> blocks,
    @Default(0) int createdAt,
    @Default(PresetPermissions()) PresetPermissions permissions,

    /// The connection every LLM call this preset makes runs on, including
    /// `glaze.generateText`. Empty means "whatever the chat is on".
    @Default('') String apiConfigId,

    /// Model override for that connection. Empty means the connection's own.
    @Default('') String apiModel,
  }) = _ExtensionPreset;

  factory ExtensionPreset.fromJson(Map<String, dynamic> json) =>
      _$ExtensionPresetFromJson(
        _withSingleConnection(_withBlockContextPolicies(json)),
      );
}

/// Collapses the old three-way `connectionProfiles` mapping onto the single
/// connection that replaced it.
///
/// Presets stored before the change carry `{big, medium, small}`; the first
/// one that names a connection becomes the preset's connection, which is what
/// a single-connection setup — nearly all of them — already had in `big`.
Map<String, dynamic> _withSingleConnection(Map<String, dynamic> json) {
  final profiles = json['connectionProfiles'];
  final next = {...json}..remove('connectionProfiles');
  final current = json['apiConfigId'];
  if (profiles is! Map || (current is String && current.isNotEmpty)) {
    return next;
  }
  for (final key in const ['big', 'medium', 'small']) {
    final id = profiles[key];
    if (id is String && id.isNotEmpty) return {...next, 'apiConfigId': id};
  }
  return next;
}

Map<String, dynamic> _withBlockContextPolicies(Map<String, dynamic> json) {
  final presetPolicy = json['contextPolicy'];
  final fallbackPolicy = presetPolicy is Map
      ? (Map<String, dynamic>.from(presetPolicy)..remove('messageCount'))
      : const ExtensionContextPolicy(legacyPromptSemantics: true).toJson();
  final presetMessageCount = presetPolicy is Map
      ? (presetPolicy['messageCount'] as num?)?.toInt()
      : null;
  final blocks = (json['blocks'] as List? ?? const [])
      .map((raw) {
        final block = Map<String, dynamic>.from(raw as Map);
        final blockPolicy = block['contextPolicy'];
        final blockMessageCount = blockPolicy is Map
            ? (blockPolicy['messageCount'] as num?)?.toInt()
            : null;
        if (blockPolicy is Map) {
          block['contextPolicy'] = Map<String, dynamic>.from(blockPolicy)
            ..remove('messageCount');
        }
        if (block.containsKey('contextPolicy')) {
          return {...block, 'contextMessageCount': ?blockMessageCount};
        }
        return {
          ...block,
          'contextMessageCount': ?presetMessageCount,
          'contextPolicy': fallbackPolicy,
        };
      })
      .toList(growable: false);
  return {...json, 'blocks': blocks}..remove('contextPolicy');
}
