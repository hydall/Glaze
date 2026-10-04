import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/shared_prefs_provider.dart';
import 'tools_tile_models.dart';

/// Persists the Tools screen layout — tile order, per-tile size and hidden
/// tiles — in SharedPreferences.
///
/// Mirrors [MagicDrawerLayoutService] for the chat drawer, with one addition:
/// a size map, because Windows-Phone-style tiles carry a footprint as well as a
/// position.
class ToolsLayoutService {
  static const orderKey = 'tools_layout_order';
  static const sizesKey = 'tools_layout_sizes';
  static const deletedKey = 'tools_layout_deleted';

  final WidgetRef _ref;

  ToolsLayoutService(this._ref);

  Future<
    ({
      List<String> itemIds,
      Map<String, ToolsTileSize> sizes,
      Set<String> deletedIds,
    })
  >
  loadLayout(List<ToolsTileDef> allTiles) async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final savedOrder = prefs.getStringList(orderKey);
    final savedSizes = prefs.getStringList(sizesKey) ?? const [];
    final savedDeleted = prefs.getStringList(deletedKey) ?? const [];

    final sizes = <String, ToolsTileSize>{};
    for (final entry in savedSizes) {
      final sep = entry.indexOf(':');
      if (sep < 0) continue;
      final id = entry.substring(0, sep);
      final name = entry.substring(sep + 1);
      final size = ToolsTileSize.values
          .where((s) => s.name == name)
          .firstOrNull;
      if (size != null) sizes[id] = size;
    }

    final deletedIds = savedDeleted
        .where((id) => allTiles.any((t) => t.id == id))
        .toSet();

    final defaultIds = allTiles
        .map((t) => t.id)
        .where((id) => !deletedIds.contains(id))
        .toList();
    if (savedOrder == null || savedOrder.isEmpty) {
      return (
        itemIds: List<String>.from(defaultIds),
        sizes: sizes,
        deletedIds: deletedIds,
      );
    }

    final filtered = savedOrder
        .where((id) => allTiles.any((t) => t.id == id))
        .toList();
    // Tiles a new build introduces land after the saved order, unless the user
    // already hid them.
    final missing = defaultIds
        .where((id) => !filtered.contains(id) && !deletedIds.contains(id))
        .toList();
    return (
      itemIds: [...filtered, ...missing],
      sizes: sizes,
      deletedIds: deletedIds,
    );
  }

  Future<void> saveLayout(
    List<String> itemIds,
    Map<String, ToolsTileSize> sizes,
    Set<String> deletedIds,
  ) async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setStringList(orderKey, List<String>.from(itemIds));
    await prefs.setStringList(sizesKey, [
      for (final e in sizes.entries) '${e.key}:${e.value.name}',
    ]);
    await prefs.setStringList(deletedKey, deletedIds.toList());
  }
}
