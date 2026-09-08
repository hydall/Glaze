import 'package:freezed_annotation/freezed_annotation.dart';

import 'block_config.dart';
import 'connection_profiles.dart';
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
    @Default(ConnectionProfiles()) ConnectionProfiles connectionProfiles,
  }) = _ExtensionPreset;

  factory ExtensionPreset.fromJson(Map<String, dynamic> json) =>
      _$ExtensionPresetFromJson(_withBlockContextPolicies(json));
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
