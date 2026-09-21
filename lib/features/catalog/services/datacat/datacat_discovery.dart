import '../../catalog_models.dart';
import 'datacat_client.dart';
import 'datacat_models.dart';
import 'datacat_sort.dart';

/// Browsing, searching and tag discovery over the DataCat Client API.
///
/// Replaces the undocumented site endpoints the provider used to scrape: the
/// anonymous session token is gone (the client id identifies the integration),
/// rows arrive normalized instead of source-shaped, and paging is driven by the
/// server's own cursor rather than by multiplying a page number.

/// The server's declared limits, read once per launch.
///
/// Page sizes and offsets used to be constants in the app, which meant a
/// server-side change could only be found out about by getting a 400. Cached
/// rather than re-read: it is configuration, not data, and a failure to read it
/// falls back to the documented defaults instead of blocking the catalog.
DatacatCapabilities? _capabilities;

Future<DatacatCapabilities> datacatCapabilities() async {
  final cached = _capabilities;
  if (cached != null) return cached;
  try {
    final data = await datacatGet('/capabilities');
    return _capabilities = DatacatCapabilities.fromJson(data);
  } catch (_) {
    return _capabilities = const DatacatCapabilities();
  }
}

/// Forgets the cached capabilities. Tests only — the app reads them once.
void resetDatacatCapabilities() => _capabilities = null;

/// The tag id DataCat marks adult content with. `blockedTagIds=2` is how the
/// API expresses what the app calls "NSFW off".
const _nsfwTagId = 2;

List<int> _blockedTagIds(CatalogFilters filters) =>
    filters.nsfw ? const [] : const [_nsfwTagId];

/// Maps one `CharacterSummary` onto the app's catalog row.
///
/// The old mapper had to guess which of eight fields held the avatar and hand-
/// resolve half-URLs against two CDNs, because it was reading a raw database
/// row. A summary states its own avatar and its own NSFW flag, so the guessing
/// is gone — the `SFW`/`NSFW` chip is derived from the flag rather than
/// prepended from a tag the row may or may not carry.
CatalogItem datacatItemFromSummary(Map<String, dynamic> json) {
  final creator = DatacatCreatorRef.fromJson(datacatMap(json['creator']));
  final stats = DatacatStats.fromJson(datacatMap(json['stats']));
  final nsfw = json['nsfw'] == true;
  final tags = <String>[
    nsfw ? 'NSFW' : 'SFW',
    ...(json['tags'] as List? ?? const []).map((t) {
      if (t is String) return t;
      final map = datacatMap(t);
      return datacatString(map['name'] ?? map['slug']);
    }).where((t) => t.isNotEmpty),
  ];

  final name = datacatString(json['name']);
  final chatName = datacatString(json['chatName']);

  return CatalogItem(
    id: datacatString(json['id']),
    name: name.isNotEmpty ? name : (chatName.isNotEmpty ? chatName : 'Unknown'),
    avatarUrl:
        json['avatarUrl'] as String? ??
        datacatMap(json['image'])['url'] as String?,
    description: json['description'] as String?,
    tags: tags.toSet().toList(),
    tokens: datacatInt(json['totalTokens']) ?? 0,
    chatCount: stats.chats,
    messageCount: stats.messages,
    creator: creator.name,
    creatorId: creator.id,
    creatorRef: creator.ref,
    sourceKind: datacatString(json['sourceKind']),
    nsfw: nsfw,
    source: 'datacat',
  );
}

CatalogSearchResult _resultFrom(
  Map<String, dynamic> data, {
  String charactersKey = 'characters',
}) {
  final paging = DatacatPaging.fromJson(datacatMap(data['paging']));
  final rows = datacatMaps(data[charactersKey]);
  return CatalogSearchResult(
    characters: rows.map(datacatItemFromSummary).toList(),
    total: paging.total,
    hasMore: paging.hasMore,
    nextOffset: paging.nextOffset ?? paging.offset + rows.length,
  );
}

/// One page of characters for [filters], starting at [offset].
///
/// [query] empty is plain browsing — the API answers both through the same
/// endpoint, so search and browse are no longer two code paths that drifted
/// apart. A time-windowed sort goes to `/fresh` instead, which is the only
/// place the API expresses "this week" and "last 24 hours".
Future<CatalogSearchResult> datacatFetchCharacters({
  String query = '',
  int offset = 0,
  int? limit,
  CatalogFilters filters = const CatalogFilters(),
}) async {
  final caps = await datacatCapabilities();
  final pageSize = (limit ?? caps.defaultPageSize).clamp(1, caps.maxPageSize);
  final sort = DatacatSort.resolve(filters);

  if (sort.window != DatacatWindow.all) {
    return _fetchFresh(
      sort: sort,
      offset: offset,
      limit: pageSize,
      filters: filters,
    );
  }

  final data = await datacatGet(
    '/characters',
    query: {
      'search': query.isEmpty ? null : query,
      'tagIds': filters.tagIds.take(24),
      'blockedTagIds': _blockedTagIds(filters),
      'sort': sort.field,
      'limit': pageSize,
      'offset': offset.clamp(0, datacatMaxOffset),
    },
  );
  return _resultFrom(data);
}

/// The `/fresh` feed, which pages its two windows independently: the caller's
/// single cursor is sent as whichever offset the chosen window reads.
///
/// This endpoint takes a sort and the two offsets — and nothing else. There is
/// no tag or NSFW parameter on it, so the filters are applied to the rows it
/// returns instead of being sent and silently ignored. That makes a windowed
/// page shorter than the unwindowed one, which is the honest outcome: the
/// alternative is showing a reader the adult characters they switched off.
Future<CatalogSearchResult> _fetchFresh({
  required DatacatSort sort,
  required int offset,
  required int limit,
  required CatalogFilters filters,
}) async {
  final is24h = sort.window == DatacatWindow.last24h;
  final data = await datacatGet(
    '/fresh',
    query: {
      'sort': sort.field,
      'limit': limit,
      'offset24': is24h ? offset.clamp(0, datacatMaxOffset) : 0,
      'offsetWeek': is24h ? 0 : offset.clamp(0, datacatMaxOffset),
    },
  );

  // Both windows come back whichever one was paged; read the one that was
  // asked for.
  final window = datacatMap(
    datacatMap(data['windows'])[is24h ? 'last24h' : 'thisWeek'],
  );
  return _applyFilters(_resultFrom(window), filters);
}

/// Drops rows the reader asked not to see, for a listing the server could not
/// filter.
///
/// Only ever removes: adult rows when NSFW is off, and rows missing a required
/// tag. The paging cursor is left as the server set it, so the next page still
/// starts where it said — a page that comes back short is short, not finished.
CatalogSearchResult _applyFilters(
  CatalogSearchResult result,
  CatalogFilters filters,
) {
  final names = _requiredTagNames(filters);
  if (filters.nsfw && names.isEmpty) return result;

  final kept = result.characters.where((c) {
    if (!filters.nsfw && c.nsfw) return false;
    if (names.isEmpty) return true;
    final tags = c.tags.map((t) => t.toLowerCase()).toSet();
    return names.every(tags.contains);
  }).toList();

  if (kept.length == result.characters.length) return result;
  return CatalogSearchResult(
    characters: kept,
    total: result.total,
    hasMore: result.hasMore,
    nextOffset: result.nextOffset,
  );
}

/// The selected tag ids, as the lowercase names a summary carries.
///
/// A summary's tags are plain strings, so a tag chosen by id has to be matched
/// by name — and a tag whose name is not in the cached vocabulary cannot be
/// matched at all, so it is not used to exclude anything.
Set<String> _requiredTagNames(CatalogFilters filters) {
  if (filters.tagIds.isEmpty) return const {};
  final byId = {for (final tag in _cachedTags) tag.id: tag.name};
  return filters.tagIds
      .map((id) => byId[id]?.toLowerCase())
      .whereType<String>()
      .toSet();
}

/// The full public profile behind a summary: long description, the complete tag
/// list, custom tags and creator notes.
Future<Map<String, dynamic>> datacatFetchProfile(
  String characterId, {
  String? sourceKind,
}) async {
  final data = await datacatGet(
    '/characters/$characterId',
    query: {'sourceKind': sourceKind},
  );
  final character = data['character'];
  return character is Map ? character.cast<String, dynamic>() : data;
}

List<CatalogTag> _cachedTags = [];
bool _tagsFetched = false;

List<CatalogTag> getCachedDatacatTags() => _cachedTags;

/// The faceted tag list, flattened.
///
/// The API groups tags and counts them; the filter sheet renders one flat,
/// count-ordered list, so the groups are folded away here rather than in the
/// UI. Read once per launch — the tag vocabulary does not move during a
/// session.
Future<List<CatalogTag>> fetchDatacatTags() async {
  if (_tagsFetched) return _cachedTags;
  if (!datacatConfigured) return const [];
  try {
    final data = await datacatGet(
      '/tags',
      query: {'sort': 'count', 'limit': datacatMaxTagLimit, 'offset': 0},
    );

    // The response carries the groups separately from the rows; the filter
    // sheet renders one flat, count-ordered list, so the grouping is dropped
    // here rather than in the UI.
    _cachedTags = datacatMaps(data['tags'])
        .map(
          (t) => CatalogTag(
            id: datacatInt(t['id']),
            name: datacatString(t['name']),
            slug: t['slug'] as String?,
          ),
        )
        .where((t) => t.name.isNotEmpty)
        .toList();
    _tagsFetched = true;
  } catch (_) {
    // A tag list that will not load leaves the sheet's other filters usable.
  }
  return _cachedTags;
}

/// Forgets the cached tags. Tests only.
void resetDatacatTags() {
  _cachedTags = [];
  _tagsFetched = false;
}
