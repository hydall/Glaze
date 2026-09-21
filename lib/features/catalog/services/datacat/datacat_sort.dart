import '../../catalog_models.dart';

/// The time window a DataCat listing is scoped to.
///
/// The API splits what the app shows as one choice into two parameters: a sort
/// field, and — for the two rolling windows — a different endpoint that pages
/// each window on its own offset. Keeping the window as its own value is what
/// lets the picker stay five items long while covering all fifteen
/// combinations.
enum DatacatWindow {
  all('all'),
  thisWeek('week'),
  last24h('24h');

  const DatacatWindow(this.key);

  /// Persisted and passed around as this string.
  final String key;

  static DatacatWindow fromKey(String? key) => DatacatWindow.values.firstWhere(
    (w) => w.key == key,
    orElse: () => DatacatWindow.all,
  );
}

/// Every sort field the Client API accepts, in the order the picker shows them.
const datacatSortFields = <String>[
  'fresh',
  'score',
  'chat_count',
  'messages_per_chat',
  'first_published',
];

/// A resolved DataCat listing order: which field, over which window.
class DatacatSort {
  final String field;
  final DatacatWindow window;

  const DatacatSort(this.field, this.window);

  /// Reads [filters] as a listing order, migrating the pre-API sort keys.
  ///
  /// The old keys were UI labels that folded a field and a window together
  /// (`score_week`), and they are what a user's saved preference still holds.
  /// They are translated rather than reset, so nobody's catalog silently jumps
  /// back to the default after updating.
  ///
  /// A current field always wins over the legacy table. `fresh` appears in
  /// both — as today's sort field and as yesterday's windowless label — and
  /// reading it as the label would pin the feed to "all time" and quietly
  /// discard whichever window the user picked.
  static DatacatSort resolve(CatalogFilters filters) {
    if (datacatSortFields.contains(filters.sort)) {
      return DatacatSort(filters.sort, DatacatWindow.fromKey(filters.window));
    }
    return _legacy[filters.sort] ??
        DatacatSort(datacatSortFields.first, DatacatWindow.all);
  }

  /// Sort keys from before the Client API, and what each one meant.
  static const _legacy = <String, DatacatSort>{
    'recent': DatacatSort('fresh', DatacatWindow.all),
    'score_week': DatacatSort('score', DatacatWindow.thisWeek),
    'score_24h': DatacatSort('score', DatacatWindow.last24h),
    'chat_count_week': DatacatSort('chat_count', DatacatWindow.thisWeek),
    'chat_count_24h': DatacatSort('chat_count', DatacatWindow.last24h),
  };

  /// The filters a legacy sort key becomes once migrated, so the persisted
  /// value is rewritten the first time it is read rather than translated on
  /// every request.
  static CatalogFilters migrate(CatalogFilters filters) {
    if (datacatSortFields.contains(filters.sort)) return filters;
    final legacy = _legacy[filters.sort];
    if (legacy == null) return filters;
    return filters.copyWith(sort: legacy.field, window: legacy.window.key);
  }
}

/// Sort fields the creator endpoints accept. A creator's own listing is a
/// different set — no score, and a name sort the main feed has no use for.
const datacatCreatorSortFields = <String>[
  'creation_date',
  'chat_count',
  'message_count',
  'name',
];
