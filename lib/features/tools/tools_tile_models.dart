import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// How much of the 2-column grid a tile occupies.
///
/// Mirrors the three Windows Phone tile footprints that make sense on a
/// phone-width screen: `small` is half a row, `wide` a full row at the height
/// the old preset hero used, `large` a full-width square (the persona avatar's
/// footprint).
enum ToolsTileSize {
  small(1, 116),
  wide(2, 140),
  large(2, 0);

  const ToolsTileSize(this.columns, this.height);

  /// Columns of the grid this tile spans (1 or 2).
  final int columns;

  /// Fixed height of the tile in logical pixels. Zero for [large], whose height
  /// follows its width (a square — see [isSquare]).
  final double height;

  /// Whether the tile is a square that tracks its own width (the avatar hero).
  bool get isSquare => this == large;

  /// The next size in the resize cycle — small → wide → large → small.
  ToolsTileSize get next => switch (this) {
    ToolsTileSize.small => ToolsTileSize.wide,
    ToolsTileSize.wide => ToolsTileSize.large,
    ToolsTileSize.large => ToolsTileSize.small,
  };
}

/// One tool the Tools screen can show, independent of its current placement.
///
/// The catalog is the single source of truth for what a tile opens and how it
/// is labelled; the layout (order, size, visibility) is persisted separately
/// by [ToolsLayoutService]. A def carries either an SVG path or an [IconData],
/// mirroring the icon split the old hardcoded grid already had.
class ToolsTileDef {
  final String id;
  final String titleKey;
  final String subtitleKey;
  final String? svgPath;
  final IconData? icon;
  final ToolsTileSize defaultSize;

  /// True for the two hero tiles — personas and presets — which keep the old
  /// full-bleed-artwork look and adapt it to whatever size they are given,
  /// instead of the generic icon layout.
  final bool hero;

  /// True for the avatar hero (personas): no icon box in the label row, and an
  /// avatar-gradient placeholder when there is no avatar image.
  final bool isAvatar;

  /// Feature-gated tiles are hidden unless their experimental master switch is
  /// on — same gating as chat Quick Access (External Blocks).
  final bool featureGated;

  const ToolsTileDef({
    required this.id,
    required this.titleKey,
    required this.subtitleKey,
    this.svgPath,
    this.icon,
    required this.defaultSize,
    this.hero = false,
    this.isAvatar = false,
    this.featureGated = false,
  }) : assert(
         svgPath != null || icon != null,
         'Provide an SVG path or an icon',
       );

  String get title => titleKey.tr();
  String get subtitle => subtitleKey.tr();
}

// SVG paths matching ToolsView.vue.
const _kIconPersonas =
    'M19 3H5c-1.11 0-2 .9-2 2v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 3c1.66 0 3 1.34 3 3s-1.34 3-3 3-3-1.34-3-3 1.34-3 3-3zm6 12H6v-1c0-2 4-3.1 6-3.1s6 1.1 6 3.1v1z';
const _kIconPresets =
    'M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6h-6V2zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z';
const _kIconApi =
    'M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z';
const _kIconLorebook =
    'M4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6zm16-4H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-1 9H9V9h10v2zm-4 4H9v-2h6v2zm4-8H9V5h10v2z';
const _kIconRegex =
    'M9.4 16.6L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z';
const _kIconStats =
    'M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zM9 17H7v-7h2v7zm4 0h-2V7h2v10zm4 0h-2v-4h2v4z';
const _kIconImageGen =
    'M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z';

/// Every tool the Tools screen can show, in the order a fresh install gets
/// them. Built on demand so labels follow the active locale, matching
/// `buildMagicDrawerItems()` for the chat drawer.
List<ToolsTileDef> buildToolsTileCatalog() => [
  ToolsTileDef(
    id: 'personas',
    titleKey: 'menu_personas',
    subtitleKey: 'user',
    svgPath: _kIconPersonas,
    defaultSize: ToolsTileSize.large,
    hero: true,
    isAvatar: true,
  ),
  ToolsTileDef(
    id: 'presets',
    titleKey: 'tab_presets',
    subtitleKey: 'label_default',
    svgPath: _kIconPresets,
    defaultSize: ToolsTileSize.wide,
    hero: true,
  ),
  ToolsTileDef(
    id: 'api',
    titleKey: 'tab_api',
    subtitleKey: 'tools_api_subtitle',
    svgPath: _kIconApi,
    defaultSize: ToolsTileSize.small,
  ),
  ToolsTileDef(
    id: 'lorebooks',
    titleKey: 'menu_lorebooks',
    subtitleKey: 'tools_lorebooks_subtitle',
    svgPath: _kIconLorebook,
    defaultSize: ToolsTileSize.small,
  ),
  ToolsTileDef(
    id: 'regex',
    titleKey: 'menu_regex',
    subtitleKey: 'tools_regex_subtitle',
    svgPath: _kIconRegex,
    defaultSize: ToolsTileSize.small,
  ),
  ToolsTileDef(
    id: 'stats',
    titleKey: 'stats_title',
    subtitleKey: 'stats_subtitle',
    svgPath: _kIconStats,
    defaultSize: ToolsTileSize.small,
  ),
  ToolsTileDef(
    id: 'image-gen',
    titleKey: 'imggen_title',
    subtitleKey: 'imggen_subtitle',
    svgPath: _kIconImageGen,
    defaultSize: ToolsTileSize.small,
  ),
  ToolsTileDef(
    id: 'ext-blocks',
    titleKey: 'ext_blocks_title',
    subtitleKey: 'tools_ext_blocks_subtitle',
    icon: Icons.extension_outlined,
    defaultSize: ToolsTileSize.small,
    featureGated: true,
  ),
];

/// The catalog entry for [id], or null when a stored layout still names a tile
/// this build has dropped.
ToolsTileDef? toolsTileById(String id) {
  for (final tile in buildToolsTileCatalog()) {
    if (tile.id == id) return tile;
  }
  return null;
}
