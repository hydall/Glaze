import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/shared_prefs_provider.dart';
import '../widgets/magic_drawer_models.dart';

/// Persists magic drawer item order and deleted items in SharedPreferences.
class MagicDrawerLayoutService {
  static const itemsKey = 'magic_drawer_items';
  static const deletedItemsKey = 'magic_drawer_deleted_items';

  final WidgetRef _ref;

  MagicDrawerLayoutService(this._ref);

  /// Legacy item ids merged into the unified Prompt Inspector. Saved layouts
  /// from before the merge still reference these; map them to 'inspector'
  /// (deduped) so the card survives the upgrade instead of vanishing.
  static const _legacyToInspector = {'context', 'preview', 'coverage'};

  List<String> _migrateIds(List<String> ids) {
    final out = <String>[];
    for (final id in ids) {
      final mapped = _legacyToInspector.contains(id) ? 'inspector' : id;
      if (!out.contains(mapped)) out.add(mapped);
    }
    return out;
  }

  Future<({List<String> itemIds, Set<String> deletedIds})> loadLayout(
    List<MagicDrawerItemDef> allItems,
  ) async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final savedOrder = prefs.getStringList(itemsKey);
    final savedDeleted = prefs.getStringList(deletedItemsKey) ?? const [];

    // Inspector is treated as deleted only if every legacy id was deleted.
    final legacyDeleted = savedDeleted
        .where((id) => _legacyToInspector.contains(id))
        .toSet();
    final allLegacyDeleted =
        legacyDeleted.length == _legacyToInspector.length;

    final deletedIds = savedDeleted
        .where((id) => !_legacyToInspector.contains(id))
        .where((id) => allItems.any((item) => item.id == id))
        .toSet();
    if (allLegacyDeleted) deletedIds.add('inspector');

    final defaultIds = allItems.map((item) => item.id).toList();
    if (savedOrder == null || savedOrder.isEmpty) {
      return (itemIds: List<String>.from(defaultIds), deletedIds: deletedIds);
    }

    final migrated = _migrateIds(savedOrder);
    final filteredSaved =
        migrated.where((id) => allItems.any((item) => item.id == id)).toList();
    final missing = defaultIds
        .where((id) => !filteredSaved.contains(id) && !deletedIds.contains(id))
        .toList();

    return (
      itemIds: [...filteredSaved, ...missing],
      deletedIds: deletedIds,
    );
  }

  Future<void> saveLayout(List<String> itemIds, Set<String> deletedIds) async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setStringList(itemsKey, List<String>.from(itemIds));
    await prefs.setStringList(deletedItemsKey, deletedIds.toList());
  }
}
