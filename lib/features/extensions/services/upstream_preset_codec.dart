/// Reads and writes whole block sets in the format used by the original
/// ExtBlocks extension.
///
/// A set there is just a name and an array of blocks; everything else that
/// belongs to one of our presets — permissions, connection profiles — has no
/// counterpart and is left at its defaults on the way in, and dropped on the
/// way out. That asymmetry is deliberate: a set exported from here should still
/// load in the original, so it must not carry keys the original will not read.
library;

import '../../../core/utils/id_generator.dart';
import '../models/block_config.dart';
import '../models/extension_preset.dart';
import 'upstream_block_codec.dart';
import 'upstream_json.dart';

/// Whether [json] is a set exported by the original extension.
bool looksLikeUpstreamPreset(Map<String, dynamic> json) =>
    json['global_blocks'] is List;

/// Builds a preset from a set exported by the original extension.
///
/// Blocks keep their file order, which is the only ordering the original has.
ExtensionPreset decodeUpstreamPreset(
  Map<String, dynamic> json, {
  String? fallbackName,
}) {
  final rawBlocks = json['global_blocks'];
  final blocks = <BlockConfig>[];
  if (rawBlocks is List) {
    var order = 0;
    for (final raw in rawBlocks) {
      if (raw is! Map) continue;
      blocks.add(
        decodeUpstreamBlock(Map<String, dynamic>.from(raw), order: order),
      );
      order++;
    }
  }

  final name = upstreamString(json['name']).trim();

  return ExtensionPreset(
    id: generateId(),
    name: name.isNotEmpty ? name : (fallbackName ?? 'Imported set'),
    blocks: blocks,
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );
}

/// Writes [preset] out as a set the original extension can load.
Map<String, dynamic> encodeUpstreamPreset(ExtensionPreset preset) => {
  'name': preset.name,
  'global_blocks': (preset.blocks.toList()..sort((a, b) => a.order.compareTo(b.order)))
      .map(encodeUpstreamBlock)
      .toList(growable: false),
};
