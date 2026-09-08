import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../import/silly_tavern_preset_parser.dart';
import '../models/preset.dart';

/// A built-in "featured" preset shipped with the app, mirroring hydall/Glaze's
/// `userDefaultPresets`. The SillyTavern-format JSON and the cover image are
/// bundled assets under `assets/presets/`.
class FeaturedPreset {
  final String id;
  final String name;
  final String author;

  /// Bundled ST-format preset JSON.
  final String jsonAsset;

  /// Bundled cover image shown on the Tools preset card.
  final String imageAsset;
  final int createdAt;
  final bool reasoningEnabled;
  final String? reasoningStart;
  final String? reasoningEnd;

  const FeaturedPreset({
    required this.id,
    required this.name,
    required this.author,
    required this.jsonAsset,
    required this.imageAsset,
    required this.createdAt,
    this.reasoningEnabled = false,
    this.reasoningStart,
    this.reasoningEnd,
  });
}

/// The standard presets from hydall/Glaze, in display order.
const featuredPresets = <FeaturedPreset>[
  FeaturedPreset(
    id: 'default_shino',
    name: 'Shino',
    author: 'Shino',
    jsonAsset: 'assets/presets/shino.json',
    imageAsset: 'assets/presets/shino.jpg',
    createdAt: 1,
    reasoningEnabled: true,
    reasoningStart: '<thinking>',
    reasoningEnd: '</thinking>',
  ),
  FeaturedPreset(
    id: 'default_fawnie',
    name: 'Fawnie v3',
    author: 'fawn1e',
    jsonAsset: 'assets/presets/fawnie.json',
    imageAsset: 'assets/presets/fawnie.jpg',
    createdAt: 2,
  ),
  FeaturedPreset(
    id: 'default_microcot',
    name: 'MicroCot Talks Mini',
    author: 'MicroCoT',
    jsonAsset: 'assets/presets/microcot.json',
    imageAsset: 'assets/presets/mikrokot.jpg',
    createdAt: 3,
  ),
  FeaturedPreset(
    id: 'default_renri',
    name: 'Renri',
    author: 'nimda trashcan',
    jsonAsset: 'assets/presets/renri.json',
    imageAsset: 'assets/presets/renri.jpg',
    createdAt: 4,
  ),
];

/// Cover-image asset for a preset id, or `null` when the id is not one of the
/// bundled featured presets.
String? featuredPresetImageAsset(String? presetId) {
  if (presetId == null) return null;
  for (final f in featuredPresets) {
    if (f.id == presetId) return f.imageAsset;
  }
  return null;
}

/// Loads and parses a featured preset's bundled ST JSON into a [Preset],
/// stamping the fixed id/name/author/metadata so re-seeding is idempotent.
Future<Preset> loadFeaturedPreset(FeaturedPreset f) async {
  final raw = await rootBundle.loadString(f.jsonAsset);
  final json = jsonDecode(raw) as Map<String, dynamic>;
  final parsed = parseSillyTavernPreset(json, f.name);
  return parsed.copyWith(
    id: f.id,
    name: f.name,
    author: f.author,
    createdAt: f.createdAt,
    reasoningEnabled: f.reasoningEnabled || parsed.reasoningEnabled,
    reasoningStart: f.reasoningStart ?? parsed.reasoningStart,
    reasoningEnd: f.reasoningEnd ?? parsed.reasoningEnd,
  );
}
