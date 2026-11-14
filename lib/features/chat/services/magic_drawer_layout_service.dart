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

  /// Same idea for the Memory sheet, which absorbed the separate Summary and
  /// Memory Books cards.
  static const _legacyToMemory = {'summary', 'memory-books'};

  static const _legacyGroups = {
    'inspector': _legacyToInspector,
    'memory': _legacyToMemory,
  };

  List<String> _migrateIds(List<String> ids) {
    final out = <String>[];
    for (final id in ids) {
      final mapped = _mergedIdFor(id) ?? id;
      if (!out.contains(mapped)) out.add(mapped);
    }
    return out;
  }

  /// The surviving id a legacy id was merged into, or null when [id] is not a
  /// legacy id.
  static String? _mergedIdFor(String id) {
    for (final entry in _legacyGroups.entries) {
      if (entry.value.contains(id)) return entry.key;
    }
    return null;
  }

  Future<({List<String> itemIds, Set<String> deletedIds})> loadLayout(
    List<MagicDrawerItemDef> allItems,
  ) async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final savedOrder = prefs.getStringList(itemsKey);
    final savedDeleted = prefs.getStringList(deletedItemsKey) ?? const [];

    // A merged card is treated as deleted only if every legacy id that fed
    // into it was deleted — losing one of two merged cards must not hide the
    // survivor.
    final deletedIds = savedDeleted
        .where((id) => _mergedIdFor(id) == null)
        .where((id) => allItems.any((item) => item.id == id))
        .toSet();
    for (final entry in _legacyGroups.entries) {
      final deletedLegacy = savedDeleted.where(entry.value.contains).toSet();
      if (deletedLegacy.length == entry.value.length) {
        deletedIds.add(entry.key);
      }
    }

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
