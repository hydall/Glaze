import 'catalog_http.dart';
import 'greeting_normalizer.dart';
import '../catalog_models.dart';

const _apiBase = 'https://api.chub.ai';
const _avatarBase = 'https://avatars.charhub.io/avatars/';

/// Headers for a Chub API request. When [apiKey] is set the site's own
/// account key rides along as both `CH-API-KEY` and `samwise` — the two headers
/// chub.ai itself sends. Without a key the request stays anonymous, which is
/// all browsing needs; the key only unlocks account-scoped results (NSFL).
Map<String, String> chubHeaders({String? apiKey}) => {
  'Accept': 'application/json',
  'Origin': 'https://chub.ai',
  'Referer': 'https://chub.ai/',
  if (apiKey != null && apiKey.isNotEmpty) ...{
    'CH-API-KEY': apiKey,
    'samwise': apiKey,
  },
};

const _sortMap = <String, _SortEntry>{
  'popular': _SortEntry(sort: 'download_count'),
  'trending_week': _SortEntry(sort: 'download_count', maxDaysAgo: '7'),
  'trending_24h': _SortEntry(sort: 'download_count', maxDaysAgo: '1'),
  'latest': _SortEntry(sort: 'id'),
  'rating': _SortEntry(sort: 'star_count'),
  'updated': _SortEntry(sort: 'last_activity_at'),
};

List<CatalogTag> _cachedChubTags = [];
bool _chubTagsFetched = false;
List<CatalogTag> getCachedChubTags() => _cachedChubTags;

/// Drops the cached tag list so the next fetch runs — used when the account key
/// changes and the tag universe may differ.
void resetChubTagCache() {
  _cachedChubTags = [];
  _chubTagsFetched = false;
}

Future<List<CatalogTag>> fetchChubTags({String? apiKey}) async {
  if (_chubTagsFetched) return _cachedChubTags;

  try {
    final sortOrders = ['download_count', 'id', 'star_count', 'default'];
    const pagesPerSort = 2;

    final allChars = <Map<String, dynamic>>[];
    for (final sortOrder in sortOrders) {
      for (var page = 1; page <= pagesPerSort; page++) {
        try {
          final params = 'search=&first=200&page=$page&sort=$sortOrder&nsfw=true&nsfl=true&include_forks=false&min_tokens=50';
          final data = await catalogGet(
            '$_apiBase/search?$params',
            chubHeaders(apiKey: apiKey),
          );
          final nodes = ((data['nodes'] ?? data['data']?['nodes']) as List?)?.cast<Map<String, dynamic>>() ?? [];
          if (nodes.isEmpty) break;
          allChars.addAll(nodes);
        } catch (_) {
          break;
        }
      }
    }

    final tagCounts = <String, int>{};
    for (final char in allChars) {
      for (final tag in (char['topics'] as List?) ?? []) {
        final normalized = (tag as String).toLowerCase().trim();
        if (normalized.isNotEmpty && normalized.length > 1 && normalized.length < 40) {
          tagCounts[normalized] = (tagCounts[normalized] ?? 0) + 1;
        }
      }
    }

    _cachedChubTags = tagCounts.entries
        .toList()
        .sorted((a, b) => b.value.compareTo(a.value))
        .take(600)
        .map((e) => CatalogTag(name: e.key))
        .toList();

    _chubTagsFetched = true;
  } catch (_) {}

  return _cachedChubTags;
}

Future<CatalogSearchResult> chubSearch({
  String query = '',
  int page = 1,
  int limit = 24,
  CatalogFilters filters = const CatalogFilters(),
  String? apiKey,
  bool accountNsfl = false,
}) async {
  // "Timeline" is chub.ai's account-scoped recommendation feed, served from a
  // separate endpoint that pages by number and ignores the free-text query and
  // tags. The account key personalizes it; `nsfw`/`nsfl` still narrow the
  // result set. It is exposed as a Chub sort option, mirroring the site's own
  // sort dropdown (`special_mode=timeline`).
  if (filters.sort == 'timeline') {
    return _chubTimeline(
      page: page,
      filters: filters,
      apiKey: apiKey,
      accountNsfl: accountNsfl,
    );
  }

  final sortEntry = _sortMap[filters.sort] ?? _sortMap['popular']!;
  final nsfw = filters.nsfw;
  // NSFL is account-scoped on chub.ai: the public API ignores the flag, and the
  // site only ever sets it while signed in. The account toggle is therefore a
  // second, persistent opt-in alongside the per-search filter toggle.
  final nsfl = filters.nsfl || accountNsfl;
  final minTokens = filters.minTokens > 0 ? filters.minTokens : 50;

  final params = StringBuffer(
    'first=$limit&page=$page&sort=${sortEntry.sort}&nsfw=$nsfw&nsfl=$nsfl&include_forks=true&min_tokens=$minTokens&venus=false',
  );
  if (sortEntry.maxDaysAgo != null) params.write('&max_days_ago=${sortEntry.maxDaysAgo}');
  if (query.isNotEmpty) params.write('&search=${Uri.encodeComponent(query)}');
  if (filters.maxTokens < 100000) params.write('&max_tokens=${filters.maxTokens}');

  final includeTags = filters.tagNames;
  final excludeTags = filters.excludeTagNames;
  if (includeTags.isNotEmpty) params.write('&topics=${includeTags.map(Uri.encodeComponent).join(',')}');
  if (excludeTags.isNotEmpty) params.write('&excludetopics=${excludeTags.map(Uri.encodeComponent).join(',')}');

  // Chub-only content flags, mapped straight onto the site's own parameters.
  if (filters.nsfwOnly) params.write('&nsfw_only=true');
  if (filters.requireImages) params.write('&require_images=true');
  if (filters.requireLore) params.write('&require_lore=true');
  if (filters.requireCustomPrompt) params.write('&require_custom_prompt=true');
  if (filters.requireExampleDialogues) params.write('&require_example_dialogues=true');
  if (filters.requireAlternateGreetings) params.write('&require_alternate_greetings=true');
  if (filters.recommendedVerified) params.write('&recommended_verified=true');
  if (filters.excludeMine) params.write('&exclude_mine=true');
  if (filters.inclusiveOr) params.write('&inclusive_or=true');
  if (filters.minAiRating > 0) params.write('&min_ai_rating=${filters.minAiRating}');
  if (filters.minTags > 0) params.write('&min_tags=${filters.minTags}');

  final data = await catalogGet(
    '$_apiBase/search?$params',
    chubHeaders(apiKey: apiKey),
  );
  final container = data['data'] as Map<String, dynamic>?;
  final nodes = ((data['nodes'] ?? container?['nodes']) as List?)?.cast<Map<String, dynamic>>() ?? [];

  return CatalogSearchResult(
    characters: nodes.map(_normalizeNode).toList(),
    // The site's own response nests the running total under `data.count`; it is
    // capped at 100000 for very broad queries.
    total: (container?['count'] as int?) ?? (data['total'] as int?) ?? nodes.length,
    hasMore: (container?['cursor'] ?? data['cursor']) != null,
  );
}

/// One page of Chub's "Timeline" recommendation feed.
///
/// The endpoint is `/api/timeline/v1`, not `/search`: it takes only `page`
/// (fixed page size, no cursor in the anonymous response), uses the account key
/// to personalize, and returns the same node shape as search — so
/// [_normalizeNode] maps it unchanged. A page that comes back empty ends the
/// feed; that is the same stop condition chub.ai uses (`nodes == 0`).
Future<CatalogSearchResult> _chubTimeline({
  required int page,
  required CatalogFilters filters,
  String? apiKey,
  bool accountNsfl = false,
}) async {
  final nsfw = filters.nsfw;
  final nsfl = filters.nsfl || accountNsfl;

  final data = await catalogGet(
    '$_apiBase/api/timeline/v1?page=$page&count=false&nsfw=$nsfw&nsfl=$nsfl',
    chubHeaders(apiKey: apiKey),
  );
  final container = data['data'] as Map<String, dynamic>?;
  final nodes =
      ((container?['nodes'] ?? data['nodes']) as List?)
          ?.cast<Map<String, dynamic>>() ??
      [];

  return CatalogSearchResult(
    characters: nodes.map(_normalizeNode).toList(),
    total: nodes.length,
    hasMore: nodes.isNotEmpty,
  );
}

Future<DownloadedCharacter> chubGetCharacter(
  String fullPath, {
  String? apiKey,
}) async {
  final data = await catalogGet(
    '$_apiBase/api/characters/$fullPath?full=true',
    chubHeaders(apiKey: apiKey),
  );
  final node = (data['node'] ?? data) as Map<String, dynamic>;
  return DownloadedCharacter(
    charData: chubCharacterData(node),
    avatarUrl: '$_avatarBase$fullPath/avatar.webp',
  );
}

CatalogItem _normalizeNode(Map<String, dynamic> node) {
  final fullPath = (node['fullPath'] ?? node['full_path'] ?? '') as String;
  final creator = fullPath.split('/').first;
  final isNsfw = (node['nsfw'] ?? node['is_nsfw']) as bool? ?? false;
  final topics = (node['topics'] as List?)?.cast<String>() ?? [];
  final isTopicNsfw = topics.any((t) => t.toLowerCase() == 'nsfw');
  final cleanTopics = topics.where((t) {
    final lower = t.toLowerCase();
    return lower != 'nsfw' && lower != 'sfw';
  }).toList();

  return CatalogItem(
    id: fullPath,
    name: (node['name'] ?? 'Unknown') as String,
    avatarUrl: ((node['avatar_url'] ?? node['max_res_url'] ?? '$_avatarBase$fullPath/avatar.webp') as String?),
    description: (node['tagline'] ?? '') as String,
    tags: [isTopicNsfw ? 'NSFW' : 'SFW', ...cleanTopics],
    tokens: (node['nTokens'] ?? node['n_tokens'] ?? 0) as int,
    chatCount: ((node['nChats'] ?? node['n_chats']) ?? 0) as int,
    creator: creator,
    creatorId: creator,
    nsfw: isNsfw || isTopicNsfw,
    source: 'chub',
    fullPath: fullPath,
  );
}

/// Maps one Chub node onto a Glaze card. Public for the same reason as
/// [datacatCharacterData].
CharacterData chubCharacterData(Map<String, dynamic> node) {
  final def = (node['definition'] ?? <String, dynamic>{}) as Map<String, dynamic>;
  final fullPath = (node['fullPath'] ?? node['full_path'] ?? '') as String;
  final creator = fullPath.split('/').first;
  final topics = (node['topics'] as List?)?.cast<String>() ?? [];
  final isTopicNsfw = topics.any((t) => t.toLowerCase() == 'nsfw');
  final cleanTopics = topics.where((t) {
    final lower = t.toLowerCase();
    return lower != 'nsfw' && lower != 'sfw';
  }).toList();

  final greetings = normalizeGreetings(
    primary: def['first_message'] as String?,
    others: greetingList(def['alternate_greetings']),
  );

  return CharacterData(
    name: (def['name'] ?? node['name'] ?? 'Unknown') as String,
    // Chub's `personality` IS the card body, `tavern_personality` is the V2
    // personality field, and `description` is the storefront tagline (kept in
    // creatorNotes below).
    description: (def['personality'] ?? '') as String,
    personality: (def['tavern_personality'] ?? '') as String,
    scenario: (def['scenario'] ?? '') as String,
    firstMes: greetings.firstMes,
    mesExample: (def['example_dialogs'] ?? '') as String,
    creatorNotes: (def['description'] ?? node['tagline'] ?? '') as String,
    systemPrompt: (def['system_prompt'] ?? '') as String,
    postHistoryInstructions: (def['post_history_instructions'] ?? '') as String,
    alternateGreetings: greetings.alternates,
    tags: [isTopicNsfw ? 'NSFW' : 'SFW', ...cleanTopics],
    creator: creator,
    creatorId: creator,
    characterBook: def['embedded_lorebook'],
  );
}

class _SortEntry {
  final String sort;
  final String? maxDaysAgo;
  const _SortEntry({required this.sort, this.maxDaysAgo});
}

extension _SortedExtension<T> on List<T> {
  List<T> sorted(int Function(T, T) compare) {
    final copy = List<T>.from(this);
    copy.sort(compare);
    return copy;
  }
}
