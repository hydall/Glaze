import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/misc.dart';

import '../../../core/models/character.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/db_provider.dart';
import '../models/block_config.dart';
import '../models/extension_preset.dart';
import '../providers/extension_presets_provider.dart';
import '../providers/extensions_settings_provider.dart';
import 'upstream_block_codec.dart';

/// Where the original keeps a character's own blocks: `data.extensions` of the
/// card, under the extension's name.
const cardBlocksKey = 'ExtBlocks';

/// Glaze's own copy of a card block, next to the original's fields. It keeps
/// the settings the original has no field for; it is used only while those
/// fields still match it, so an edit made in the original wins.
const _glazeKey = 'glaze';

/// `ref.read` of either a [Ref] or a [WidgetRef].
typedef ProviderRead = T Function<T>(ProviderListenable<T> provider);

/// The blocks embedded in [character]'s card, in the original's order.
///
/// An entry without an id gets one from its place and name, so the block
/// keeps the same id from one read to the next and its saved results stay
/// its own.
List<BlockConfig> cardBlocksOf(Character? character) =>
    decodeCardBlocks(character?.extensions[cardBlocksKey]);

List<BlockConfig> decodeCardBlocks(Object? raw) {
  if (raw is! List) return const [];
  final blocks = <BlockConfig>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final json = Map<String, dynamic>.from(entry);
    final id = json['id'];
    if (id is! String || id.trim().isEmpty) {
      json['id'] = 'card-${blocks.length}-${json['name'] ?? ''}';
    }
    final own = _ownCopy(json);
    blocks.add(
      own?.copyWith(order: blocks.length) ??
          decodeUpstreamBlock(json, order: blocks.length),
    );
  }
  return blocks;
}

BlockConfig? _ownCopy(Map<String, dynamic> json) {
  final raw = json.remove(_glazeKey);
  if (raw is! Map) return null;
  try {
    final block = BlockConfig.fromJson(Map<String, dynamic>.from(raw));
    final upstream = jsonDecode(jsonEncode(encodeUpstreamBlock(block)));
    return const DeepCollectionEquality().equals(upstream, json) ? block : null;
  } catch (_) {
    return null;
  }
}

List<Map<String, dynamic>> encodeCardBlocks(List<BlockConfig> blocks) => [
  for (final block in blocks.sortedBy<num>((b) => b.order))
    {
      ...encodeUpstreamBlock(block),
      _glazeKey: jsonDecode(jsonEncode(block.toJson())),
    },
];

/// [preset] with [cardBlocks] in it, as the original's
/// `BlockService.getAllBlocks` combines them: a card block replaces the
/// preset's block of the same name, and the card's blocks come first.
///
/// The card's blocks run on the preset's connection, profiles and
/// permissions, which is what the original does with the active set.
ExtensionPreset withCardBlocks(
  ExtensionPreset preset,
  List<BlockConfig> cardBlocks,
) {
  if (cardBlocks.isEmpty) return preset;
  final byName = <String, BlockConfig>{};
  for (final block in cardBlocks) {
    byName[block.name] = block;
  }
  for (final block in preset.blocks.sortedBy<num>((b) => b.order)) {
    byName.putIfAbsent(block.name, () => block);
  }
  final combined = byName.values.toList();
  return preset.copyWith(
    blocks: [
      for (var i = 0; i < combined.length; i++) combined[i].copyWith(order: i),
    ],
  );
}

/// The active ExtBlocks preset, or null when none is picked.
ExtensionPreset? activeExtBlocksPresetOf(ProviderRead read) {
  final id = read(extensionsSettingsProvider).activePresetId;
  if (id == null || id.isEmpty) return null;
  return read(extensionPresetsProvider).firstWhereOrNull((p) => p.id == id);
}

/// What runs for [charId]'s chat: the active preset with that character's
/// card blocks in it. Null without an active preset — ExtBlocks is off then,
/// card blocks included, as when the original extension is switched off.
ExtensionPreset? effectiveExtBlocksPreset(ProviderRead read, String? charId) {
  final preset = activeExtBlocksPresetOf(read);
  if (preset == null || charId == null || charId.isEmpty) return preset;
  return withCardBlocks(
    preset,
    cardBlocksOf(read(characterByIdProvider(charId))),
  );
}

/// Writes [blocks] into [charId]'s card, where the original keeps them; an
/// empty list removes the key.
Future<void> saveCardBlocks(
  ProviderRead read,
  String charId,
  List<BlockConfig> blocks,
) async {
  final ordered = [
    for (var i = 0; i < blocks.length; i++) blocks[i].copyWith(order: i),
  ];
  await read(characterRepoProvider).updateExtensionsJson(charId, (extensions) {
    if (ordered.isEmpty) {
      extensions.remove(cardBlocksKey);
    } else {
      extensions[cardBlocksKey] = encodeCardBlocks(ordered);
    }
    return extensions;
  });
}
