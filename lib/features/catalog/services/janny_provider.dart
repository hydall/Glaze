import 'package:shared_preferences/shared_preferences.dart';

import 'catalog_http.dart';
import '../catalog_models.dart';

const _searchUrl = 'https://search.jannyai.com/multi-search';
const _baseUrl = 'https://jannyai.com';
const _tokenKey = 'gz_janny_token';
const _jannyImageCdn = 'https://image.jannyai.com/bot-avatars/';
const _fallbackToken = '88a6463b66e04fb07ba87ee3db06af337f492ce511d93df6e2d2968cb2ff2b30';

Future<String> _fetchSearchToken() async {
  try {
    final html = await catalogGetText('$_baseUrl/characters/search', {
      'Origin': _baseUrl,
      'Referer': '$_baseUrl/',
    });

    String? configPath;
    final configMatch = RegExp(r'client-config\.[a-zA-Z0-9_-]+\.js').firstMatch(html);
    if (configMatch != null) {
      configPath = '/_astro/${configMatch.group(0)}';
    } else {
      final spMatch = RegExp(r'SearchPage\.[a-zA-Z0-9_-]+\.js').firstMatch(html);
      if (spMatch != null) {
        final spJs = await catalogGetText('$_baseUrl/_astro/${spMatch.group(0)}', {
          'Referer': '$_baseUrl/',
        });
        final impMatch = RegExp(r'client-config\.[a-zA-Z0-9_-]+\.js').firstMatch(spJs);
        if (impMatch != null) configPath = '/_astro/${impMatch.group(0)}';
      }
    }

    if (configPath != null) {
      final configJs = await catalogGetText('$_baseUrl$configPath', {
        'Referer': '$_baseUrl/',
      });
      final tokenMatch = RegExp(r'"([a-f0-9]{64})"').firstMatch(configJs);
      if (tokenMatch != null) return tokenMatch.group(1)!;
    }

    return _fallbackToken;
  } catch (_) {
    return _fallbackToken;
  }
}

Future<String> _getSearchToken() async {
  final prefs = await SharedPreferences.getInstance();
  final cached = prefs.getString(_tokenKey);
  if (cached != null) return cached;

  final token = await _fetchSearchToken();
  await prefs.setString(_tokenKey, token);
  return token;
}

Future<void> _clearSearchToken() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_tokenKey);
}

Map<String, String> _jannyHeaders(String token) => {
      'Accept': '*/*',
      'Authorization': 'Bearer $token',
      'Origin': _baseUrl,
      'Referer': '$_baseUrl/',
      'x-meilisearch-client': 'Meilisearch instant-meilisearch (v0.19.0) ; Meilisearch JavaScript (v0.41.0)',
    };

String? _resolveJannyAvatar(String? url) {
  if (url == null) return null;
  if (url.startsWith('http')) return url;
  if (!url.contains('/')) return '$_jannyImageCdn$url';
  return url;
}

String _slugify(String text) {
  return text
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'[^\w-]+'), '')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-+'), '')
      .replaceAll(RegExp(r'-+$'), '');
}

String _stripHtml(String html) {
  return html
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&=quot;', '"')
      .replaceAll('&=#39;', "'")
      .replaceAll('&amp;', '&');
}

dynamic _decodeAstroValue(dynamic value) {
  if (value is! List) return value;
  if (value.length < 2) return value;
  final type = value[0];
  final data = value[1];
  if (type == 0) {
    if (data is Map) {
      final decoded = <String, dynamic>{};
      for (final entry in data.entries) {
        decoded[entry.key as String] = _decodeAstroValue(entry.value);
      }
      return decoded;
    }
    return data;
  } else if (type == 1 && data is List) {
    return data.map(_decodeAstroValue).toList();
  }
  return data;
}

CatalogItem _normalizeJannyHit(Map<String, dynamic> hit) {
  final isNsfw = hit['isNsfw'] as bool? ?? false;
  var slug = _slugify((hit['slug'] ?? hit['name'] ?? hit['id'] ?? '') as String);
  if (slug.isNotEmpty && !slug.startsWith('character-')) {
    slug = 'character-$slug';
  }

  return CatalogItem(
    id: (hit['id'] ?? '') as String,
    name: (hit['name'] ?? 'Unknown') as String,
    avatarUrl: _resolveJannyAvatar(hit['avatar'] as String?),
    description: (hit['description'] ?? '') as String,
    tags: [isNsfw ? 'NSFW' : 'SFW'],
    tokens: (hit['totalToken'] ?? 0) as int,
    creator: (hit['creatorUsername'] ?? '') as String,
    creatorId: (hit['creatorId'] ?? '') as String?,
    nsfw: isNsfw,
    slug: slug,
    source: 'janny',
  );
}

Future<CatalogSearchResult> jannySearch({
  String query = '',
  int page = 1,
  CatalogFilters filters = const CatalogFilters(),
}) async {
  var token = await _getSearchToken();

  final meiliFilters = <String>[];
  final minTok = filters.minTokens > 0 ? filters.minTokens : 29;
  meiliFilters.add('totalToken >= $minTok');
  if (filters.maxTokens < 100000) meiliFilters.add('totalToken <= ${filters.maxTokens}');
  if (!filters.nsfw) meiliFilters.add('isNsfw = false');
  if (filters.tagIds.isNotEmpty) {
    meiliFilters.addAll(filters.tagIds.map((id) => 'tagIds = $id'));
  }

  final activeSort = filters.sort;
  final sortMap = <String, List<String>>{
    'newest': ['createdAtStamp:desc'],
    'oldest': ['createdAtStamp:asc'],
    'tokens_desc': ['totalToken:desc'],
    'tokens_asc': ['totalToken:asc'],
    'relevant': [],
  };
  final sortArr = sortMap[activeSort] ?? sortMap['newest']!;

  final body = {
    'queries': [
      {
        'indexUid': 'janny-characters',
        'q': query,
        'facets': ['isLowQuality', 'isNsfw', 'tagIds', 'totalToken'],
        'attributesToCrop': ['description:300'],
        'cropMarker': '...',
        if (meiliFilters.isNotEmpty) 'filter': meiliFilters.join(' AND '),
        'attributesToHighlight': ['name', 'description'],
        'hitsPerPage': 40,
        'page': page,
        if (sortArr.isNotEmpty) 'sort': sortArr,
      }
    ],
  };

  try {
    final data = await catalogPost(_searchUrl, body, _jannyHeaders(token));
    final result = (data['results'] as List?)?.firstOrNull as Map<String, dynamic>? ?? {};
    return CatalogSearchResult(
      characters: ((result['hits'] as List?) ?? []).cast<Map<String, dynamic>>().map(_normalizeJannyHit).toList(),
      total: (result['totalHits'] as int?) ?? 0,
    );
  } catch (e) {
    if (e.toString().contains('401') || e.toString().contains('403')) {
      await _clearSearchToken();
      token = _fallbackToken;
      final data = await catalogPost(_searchUrl, body, _jannyHeaders(token));
      final result = (data['results'] as List?)?.firstOrNull as Map<String, dynamic>? ?? {};
      return CatalogSearchResult(
        characters: ((result['hits'] as List?) ?? []).cast<Map<String, dynamic>>().map(_normalizeJannyHit).toList(),
        total: (result['totalHits'] as int?) ?? 0,
      );
    }
    rethrow;
  }
}

Future<DownloadedCharacter> jannyFetchCharacter(String characterId, String? slug) async {
  var effectiveSlug = _slugify(slug ?? 'character');
  if (!effectiveSlug.startsWith('character-')) {
    effectiveSlug = 'character-$effectiveSlug';
  }

  final html = await catalogGetText(
    '$_baseUrl/characters/${characterId}_$effectiveSlug',
    {
      'Origin': 'https://jannyai.com',
      'Referer': 'https://jannyai.com/',
      'Accept': 'text/html',
    },
  );

  var astroMatch = RegExp(r'astro-island[^>]*component-export="CharacterButtons"[^>]*props="([^"]+)"').firstMatch(html);
  astroMatch ??= RegExp(r'astro-island[^>]*props="([^"]*character[^"]*)"').firstMatch(html);

  if (astroMatch == null) {
    throw Exception('Could not parse JannyAI character page');
  }

  final propsDecoded = astroMatch
      .group(1)!
      .replaceAll('&quot;', '"')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&#39;', "'");

  final propsJson = Map<String, dynamic>.from(
    (await _parseJson(propsDecoded)) as Map,
  );
  final character = _decodeAstroValue(propsJson['character']) as Map<String, dynamic>;
  final imageUrl = _decodeAstroValue(propsJson['imageUrl']) as String?;

  String? creatorUsername;
  final creatorMatch = RegExp(r'Creator:\s*(?:</[^>]+>\s*)?<a[^>]*>@?([^<]+)</a>').firstMatch(html);
  if (creatorMatch != null) creatorUsername = creatorMatch.group(1)?.trim();

  return DownloadedCharacter(
    charData: CharacterData(
      name: (character['name'] ?? 'Unnamed') as String,
      description: '',
      personality: (character['personality'] ?? '') as String,
      scenario: (character['scenario'] ?? '') as String,
      firstMes: (character['firstMessage'] ?? '') as String,
      mesExample: (character['exampleDialogs'] ?? '') as String,
      creatorNotes: _stripHtml((character['description'] ?? '') as String),
      systemPrompt: '',
      postHistoryInstructions: '',
      alternateGreetings: const [],
      tags: [],
      creator: creatorUsername ?? (character['creatorId'] ?? '') as String,
      creatorId: (character['creatorId'] ?? '') as String,
      characterBook: null,
    ),
    avatarUrl: imageUrl != null ? _resolveJannyAvatar(imageUrl) : null,
  );
}

Future<dynamic> _parseJson(String text) async {
  return _simpleJsonDecode(text);
}

dynamic _simpleJsonDecode(String s) {
  return _JsonParser(s).parseValue();
}

class _JsonParser {
  final String s;
  int i = 0;
  _JsonParser(this.s);

  dynamic parseValue() {
    _ws();
    if (i >= s.length) throw FormatException('Unexpected end');
    switch (s[i]) {
      case '{':
        return parseObject();
      case '[':
        return parseArray();
      case '"':
        return parseString();
      case 't':
        i += 4;
        return true;
      case 'f':
        i += 5;
        return false;
      case 'n':
        i += 4;
        return null;
      default:
        return parseNumber();
    }
  }

  Map<String, dynamic> parseObject() {
    i++;
    final result = <String, dynamic>{};
    _ws();
    if (i < s.length && s[i] == '}') {
      i++;
      return result;
    }
    while (i < s.length) {
      _ws();
      final key = parseString();
      _ws();
      i++;
      final value = parseValue();
      result[key] = value;
      _ws();
      if (i < s.length && s[i] == '}') {
        i++;
        break;
      }
      i++;
    }
    return result;
  }

  List<dynamic> parseArray() {
    i++;
    final result = <dynamic>[];
    _ws();
    if (i < s.length && s[i] == ']') {
      i++;
      return result;
    }
    while (i < s.length) {
      result.add(parseValue());
      _ws();
      if (i < s.length && s[i] == ']') {
        i++;
        break;
      }
      i++;
    }
    return result;
  }

  String parseString() {
    i++;
    final buf = StringBuffer();
    while (i < s.length && s[i] != '"') {
      if (s[i] == '\\' && i + 1 < s.length) {
        i++;
        switch (s[i]) {
          case 'n':
            buf.write('\n');
          case 't':
            buf.write('\t');
          case 'r':
            buf.write('\r');
          case '\\':
            buf.write('\\');
          case '"':
            buf.write('"');
          case 'u':
            final hex = s.substring(i + 1, i + 5);
            buf.write(String.fromCharCode(int.parse(hex, radix: 16)));
            i += 4;
          default:
            buf.write(s[i]);
        }
      } else {
        buf.write(s[i]);
      }
      i++;
    }
    i++;
    return buf.toString();
  }

  num parseNumber() {
    final start = i;
    if (i < s.length && s[i] == '-') i++;
    while (i < s.length && (s[i].isDigit || s[i] == '.' || s[i] == 'e' || s[i] == 'E' || s[i] == '+' || s[i] == '-')) {
      i++;
    }
    return num.parse(s.substring(start, i));
  }

  void _ws() {
    while (i < s.length && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t')) {
      i++;
    }
  }
}

extension on String {
  bool get isDigit => codeUnitAt(0) >= 48 && codeUnitAt(0) <= 57;
}
