import 'catalog_http.dart';
import '../catalog_models.dart';

const _apiBase = 'https://api.chub.ai';
const _avatarBase = 'https://avatars.charhub.io/avatars/';

const _chubHeaders = {
  'Accept': 'application/json',
  'Origin': 'https://chub.ai',
  'Referer': 'https://chub.ai/',
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

Future<List<CatalogTag>> fetchChubTags() async {
  if (_chubTagsFetched) return _cachedChubTags;

  try {
    final sortOrders = ['download_count', 'id', 'star_count', 'default'];
    const pagesPerSort = 2;

    final allChars = <Map<String, dynamic>>[];
    for (final sortOrder in sortOrders) {
      for (var page = 1; page <= pagesPerSort; page++) {
        try {
          final params = 'search=&first=200&page=$page&sort=$sortOrder&nsfw=true&nsfl=true&include_forks=false&min_tokens=50';
          final data = await catalogGet('$_apiBase/search?$params', _chubHeaders);
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
}) async {
  final sortEntry = _sortMap[filters.sort] ?? _sortMap['popular']!;
  final nsfw = filters.nsfw;
  final minTokens = filters.minTokens > 0 ? filters.minTokens : 50;

  final params = StringBuffer(
    'first=$limit&page=$page&sort=${sortEntry.sort}&nsfw=$nsfw&nsfl=${filters.nsfl}&include_forks=true&min_tokens=$minTokens&venus=false',
  );
  if (sortEntry.maxDaysAgo != null) params.write('&max_days_ago=${sortEntry.maxDaysAgo}');
  if (query.isNotEmpty) params.write('&search=${Uri.encodeComponent(query)}');
  if (filters.maxTokens < 100000) params.write('&max_tokens=${filters.maxTokens}');

  final includeTags = filters.tagNames;
  final excludeTags = filters.excludeTagNames;
  if (includeTags.isNotEmpty) params.write('&topics=${includeTags.map(Uri.encodeComponent).join(',')}');
  if (excludeTags.isNotEmpty) params.write('&excludetopics=${excludeTags.map(Uri.encodeComponent).join(',')}');

  final data = await catalogGet('$_apiBase/search?$params', _chubHeaders);
  final nodes = ((data['nodes'] ?? data['data']?['nodes']) as List?)?.cast<Map<String, dynamic>>() ?? [];

  return CatalogSearchResult(
    characters: nodes.map(_normalizeNode).toList(),
    total: (data['total'] as int?) ?? nodes.length,
    hasMore: (data['data']?['cursor'] ?? data['cursor']) != null,
  );
}

Future<DownloadedCharacter> chubGetCharacter(String fullPath) async {
  final data = await catalogGet(
    '$_apiBase/api/characters/$fullPath?full=true',
    _chubHeaders,
  );
  final node = (data['node'] ?? data) as Map<String, dynamic>;
  return DownloadedCharacter(
    charData: _convertToGlaze(node),
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
    chatCount: (node['nDownloads'] ?? 0) as int,
    creator: creator,
    creatorId: creator,
    nsfw: isNsfw,
    source: 'chub',
    fullPath: fullPath,
  );
}

CharacterData _convertToGlaze(Map<String, dynamic> node) {
  final def = (node['definition'] ?? <String, dynamic>{}) as Map<String, dynamic>;
  final fullPath = (node['fullPath'] ?? node['full_path'] ?? '') as String;
  final creator = fullPath.split('/').first;
  final topics = (node['topics'] as List?)?.cast<String>() ?? [];
  final isTopicNsfw = topics.any((t) => t.toLowerCase() == 'nsfw');
  final cleanTopics = topics.where((t) {
    final lower = t.toLowerCase();
    return lower != 'nsfw' && lower != 'sfw';
  }).toList();

  return CharacterData(
    name: (def['name'] ?? node['name'] ?? 'Unknown') as String,
    description: '',
    personality: (def['personality'] ?? '') as String,
    scenario: (def['scenario'] ?? '') as String,
    firstMes: (def['first_message'] ?? '') as String,
    mesExample: (def['example_dialogs'] ?? '') as String,
    creatorNotes: (def['description'] ?? node['tagline'] ?? '') as String,
    systemPrompt: (def['system_prompt'] ?? '') as String,
    postHistoryInstructions: (def['post_history_instructions'] ?? '') as String,
    alternateGreetings: def['alternate_greetings'] is List
        ? (def['alternate_greetings'] as List).whereType<String>().toList()
        : <String>[],
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
