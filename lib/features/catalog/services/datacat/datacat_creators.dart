import '../../catalog_models.dart';
import 'datacat_client.dart';
import 'datacat_discovery.dart';
import 'datacat_models.dart';

/// Creator profiles and their character listings.
///
/// New ground: the app had no way to browse a creator at all, because the site
/// endpoints it scraped exposed none. `bootstrap` exists so opening a creator
/// is one request rather than two — profile and first page together — and the
/// paged endpoint takes over from the second page on.

/// A creator's profile together with the first page of their characters.
class DatacatCreatorPage {
  final DatacatCreatorProfile profile;
  final CatalogSearchResult characters;

  const DatacatCreatorPage({required this.profile, required this.characters});
}

/// Opens [creatorRef] — a UUID, or `saucepan:UUID` for a Saucepan creator.
///
/// [filters] is applied to the rows here, not sent. The creator endpoints do
/// take tag filters — as slugs, unlike `/characters`, which wants numeric ids
/// and ignores slugs — but adult content is not a tag on this API: a character
/// carries a boolean `nsfw`, and `blockedTagSlugs=nsfw` was measured to change
/// nothing. A reader who turned NSFW off would have been shown adult
/// characters on a creator's page and nowhere else.
Future<DatacatCreatorPage> datacatFetchCreator(
  String creatorRef, {
  CatalogFilters filters = const CatalogFilters(),
  List<String> tagSlugs = const [],
  List<String> blockedTagSlugs = const [],
  String sort = 'creation_date',
  String sortDir = 'desc',
  int? limit,
}) async {
  final data = await datacatGet(
    '/creators/${Uri.encodeComponent(creatorRef)}/bootstrap',
    query: {
      'tagSlugs': tagSlugs,
      'blockedTagSlugs': blockedTagSlugs,
      'sort': sort,
      'sortDir': sortDir,
      'limit': (limit ?? 24).clamp(1, datacatMaxCreatorLimit),
      'offset': 0,
    },
  );

  return DatacatCreatorPage(
    profile: DatacatCreatorProfile.fromJson(datacatMap(data['creator'])),
    characters: _characterPage(data, filters),
  );
}

/// The next page of [creatorRef]'s characters.
Future<CatalogSearchResult> datacatFetchCreatorCharacters(
  String creatorRef, {
  required int offset,
  CatalogFilters filters = const CatalogFilters(),
  List<String> tagSlugs = const [],
  List<String> blockedTagSlugs = const [],
  String sort = 'creation_date',
  String sortDir = 'desc',
  int? limit,
}) async {
  final data = await datacatGet(
    '/creators/${Uri.encodeComponent(creatorRef)}/characters',
    query: {
      'tagSlugs': tagSlugs,
      'blockedTagSlugs': blockedTagSlugs,
      'sort': sort,
      'sortDir': sortDir,
      'limit': (limit ?? 24).clamp(1, datacatMaxCreatorLimit),
      'offset': offset.clamp(0, datacatMaxOffset),
    },
  );
  return _characterPage(data, filters);
}

CatalogSearchResult _characterPage(
  Map<String, dynamic> data,
  CatalogFilters filters,
) {
  final paging = DatacatPaging.fromJson(datacatMap(data['paging']));
  final rows = datacatMaps(data['characters']);
  return datacatApplyClientFilters(
    CatalogSearchResult(
      characters: rows.map(datacatItemFromSummary).toList(),
      total: paging.total,
      hasMore: paging.hasMore,
      nextOffset: paging.nextOffset ?? paging.offset + rows.length,
    ),
    filters,
  );
}
