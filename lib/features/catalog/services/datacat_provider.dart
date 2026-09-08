import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'catalog_http.dart';
import '../catalog_models.dart';

const _base = 'https://datacat.run';
const _keyDevice = 'gz_dc_device';
const _keyToken = 'gz_dc_token';
const _saucepanCdnBase = 'https://cdn.saucepan.ai';
const _imageBase = 'https://ella.janitorai.com/bot-avatars/';
const _minTokens = 889;

String _uuid() {
  final r = Random();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replaceAllMapped(
    RegExp('[xy]'),
    (m) {
      final v = r.nextInt(16);
      return (m.group(0) == 'x' ? v : (v & 0x3 | 0x8)).toRadixString(16);
    },
  );
}

Future<String> _getDeviceToken() async {
  final prefs = await SharedPreferences.getInstance();
  var token = prefs.getString(_keyDevice);
  if (token == null) {
    token = _uuid();
    await prefs.setString(_keyDevice, token);
  }
  return token;
}

Future<String?> _getSessionToken() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_keyToken);
}

Future<void> _setSessionToken(String token) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_keyToken, token);
}

Map<String, String> _authHeaders(String token) => {
      'X-Session-Token': token,
      'Origin': 'https://datacat.run',
      'Referer': 'https://datacat.run/',
    };

Future<String> datacatInit() async {
  final deviceToken = await _getDeviceToken();
  final data = await catalogPost(
    '$_base/api/liberator/identify',
    {'deviceToken': deviceToken},
    {
      'Origin': 'https://datacat.run',
      'Referer': 'https://datacat.run/',
    },
  );
  final sessionToken = data['sessionToken'] as String?;
  if (sessionToken == null) throw Exception('DataCat: no sessionToken');
  await _setSessionToken(sessionToken);
  return sessionToken;
}

Future<String> _getToken() async {
  var token = await _getSessionToken();
  token ??= await datacatInit();
  return token;
}

Future<bool> datacatValidate() async {
  final token = await _getSessionToken();
  if (token == null) return false;
  try {
    await catalogGet(
      '$_base/api/characters/recent-public?limit=1&summary=1',
      _authHeaders(token),
    );
    return true;
  } catch (e) {
    if (e.toString().contains('401') || e.toString().contains('403')) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyToken);
      return false;
    }
    return true;
  }
}

Future<void> datacatEnsureSession() async {
  final valid = await datacatValidate();
  if (!valid) await datacatInit();
}

String? _pickAvatarSource(Map<String, dynamic> raw, Map<String, dynamic> meta) {
  return (raw['avatar'] ?? raw['image'] ?? raw['image_url'] ??
          raw['avatar_url'] ?? raw['max_res_url'] ?? meta['image'] ??
          meta['image_url'] ?? meta['avatar'] ?? meta['avatar_url']) as String?;
}

String? _resolveAvatarUrl(String? url) {
  if (url == null) return null;
  if (url.startsWith('http')) return url;
  if (url.startsWith('//')) return 'https:$url';
  if (url.startsWith('/images/')) return '$_saucepanCdnBase$url';
  if (url.startsWith('images/')) return '$_saucepanCdnBase/$url';
  if (RegExp(r'^[0-9a-f-]+/highres$', caseSensitive: false).hasMatch(url)) {
    return '$_saucepanCdnBase/images/$url';
  }
  if (url.startsWith('/')) return 'https://ella.janitorai.com$url';
  if (!url.contains('/')) return '$_imageBase$url';
  return 'https://ella.janitorai.com/$url';
}

String _stripEmoji(String str) {
  return str.replaceAll(
    RegExp(r'[\u{1F300}-\u{1FFFF}\u{2600}-\u{27BF}\s\uFE0F\u200D]+',
        unicode: true),
    '',
  ).trim();
}

CatalogItem _normalizeListItem(Map<String, dynamic> c) {
  final stdTags = (c['tags'] as List?)
          ?.map((t) => _stripEmoji(t is String ? t : (t['name'] ?? '') as String))
          .where((t) => t.isNotEmpty)
          .toList() ??
      [];
  final isNsfw = (c['is_nsfw'] ?? c['isNsfw']) as bool? ?? false;
  final tags = [isNsfw ? 'NSFW' : 'SFW', ...stdTags];

  return CatalogItem(
    id: (c['character_id'] ?? c['characterId'] ?? c['uuid'] ?? c['id'] ?? '') as String,
    name: (c['name'] ?? c['chat_name'] ?? c['chatName'] ?? 'Unknown') as String,
    avatarUrl: _resolveAvatarUrl(_pickAvatarSource(c, {})),
    tags: tags.toSet().toList(),
    tokens: (c['total_tokens'] ?? c['totalTokens'] ?? 0) as int,
    chatCount: (c['chat_count'] ?? 0) as int,
    messageCount: (c['message_count'] ?? 0) as int,
    creator: (c['creator_name'] ?? c['creatorName'] ?? '') as String,
    creatorId: (c['creator_id'] ?? c['creatorId'] ?? '') as String?,
    nsfw: isNsfw,
    source: 'datacat',
  );
}

Future<CatalogSearchResult> datacatBrowse({
  int page = 1,
  int limit = 24,
  CatalogFilters filters = const CatalogFilters(),
}) async {
  final sort = filters.sort;

  if (sort != 'recent') {
    final sortMap = <String, _FreshParams>{
      'fresh': _FreshParams(sortBy: 'fresh', window: 'all'),
      'score_week': _FreshParams(sortBy: 'score', window: 'thisWeek'),
      'score_24h': _FreshParams(sortBy: 'score', window: 'last24h'),
      'chat_count_week': _FreshParams(sortBy: 'chat_count', window: 'thisWeek'),
      'chat_count_24h': _FreshParams(sortBy: 'chat_count', window: 'last24h'),
    };
    final mapped = sortMap[sort] ?? const _FreshParams(sortBy: 'fresh', window: 'all');
    final res = await _datacatFresh(
      sortBy: mapped.sortBy,
      window: mapped.window,
      nsfw: filters.nsfw,
    );
    return CatalogSearchResult(characters: res, total: res.length, hasMore: false);
  }

  final token = await _getToken();
  final offset = (page - 1) * limit;
  final minTok = filters.minTokens > 0 ? filters.minTokens : _minTokens;

  final params = StringBuffer('limit=$limit&offset=$offset&summary=1&minTotalTokens=$minTok');
  if (filters.maxTokens < 100000) params.write('&maxTotalTokens=${filters.maxTokens}');
  if (filters.tagIds.isNotEmpty) params.write('&tagIds=${filters.tagIds.join(',')}');
  if (!filters.nsfw) params.write('&blockedTagIds=2');

  final data = await catalogGet(
    '$_base/api/characters/recent-public?$params',
    _authHeaders(token),
  );
  final chars = ((data['characters'] as List?) ?? []).cast<Map<String, dynamic>>();
  return CatalogSearchResult(
    characters: chars.map(_normalizeListItem).toList(),
    total: (data['totalCount'] as int?) ?? 0,
  );
}

Future<List<CatalogItem>> _datacatFresh({
  String sortBy = 'score',
  String window = 'all',
  int limit24 = 80,
  int limitWeek = 40,
  bool nsfw = true,
}) async {
  final token = await _getToken();
  var url = '$_base/api/characters/fresh?summary=1&sortBy=$sortBy&limit24=$limit24&limitWeek=$limitWeek';
  if (!nsfw) url += '&blockedTagIds=2';

  final data = await catalogGet(url, _authHeaders(token));
  final windows = data['windows'] as Map<String, dynamic>? ?? {};
  final last24h = ((windows['last24h']?['characters'] as List?) ?? []).cast<Map<String, dynamic>>();
  final thisWeek = ((windows['thisWeek']?['characters'] as List?) ?? []).cast<Map<String, dynamic>>();

  List<CatalogItem> result;
  if (window == 'last24h') {
    result = last24h.map(_normalizeListItem).toList();
  } else if (window == 'thisWeek') {
    result = thisWeek.map(_normalizeListItem).toList();
  } else {
    final seen = <String>{};
    result = [];
    for (final c in [...thisWeek.map(_normalizeListItem), ...last24h.map(_normalizeListItem)]) {
      if (seen.add(c.id)) result.add(c);
    }
  }
  return result;
}

Future<CatalogSearchResult> datacatSearch({
  String query = '',
  int page = 1,
  int limit = 24,
  CatalogFilters filters = const CatalogFilters(),
}) async {
  final token = await _getToken();
  final offset = (page - 1) * limit;
  final minTok = filters.minTokens > 0 ? filters.minTokens : _minTokens;

  final params = StringBuffer('limit=$limit&offset=$offset&summary=1&minTotalTokens=$minTok');
  if (filters.maxTokens < 100000) params.write('&maxTotalTokens=${filters.maxTokens}');
  if (!filters.nsfw) params.write('&blockedTagIds=2');
  if (filters.tagIds.isNotEmpty) params.write('&tagIds=${filters.tagIds.join(',')}');
  if (query.isNotEmpty) params.write('&search=${Uri.encodeComponent(query)}');

  final data = await catalogGet(
    '$_base/api/characters/recent-public?$params',
    _authHeaders(token),
  );
  final chars = ((data['characters'] as List?) ?? []).cast<Map<String, dynamic>>();
  return CatalogSearchResult(
    characters: chars.map(_normalizeListItem).toList(),
    total: (data['totalCount'] as int?) ?? 0,
  );
}

Future<DownloadedCharacter> datacatGetCharacter(String uuid) async {
  final token = await _getToken();
  final ts = DateTime.now().millisecondsSinceEpoch;
  final data = await catalogGet(
    '$_base/api/characters/$uuid/download?t=$ts&variant=janitor_core',
    _authHeaders(token),
  );
  final raw = (data['data'] ?? data) as Map<String, dynamic>;
  final meta = (data['metadata'] ?? <String, dynamic>{}) as Map<String, dynamic>;
  return DownloadedCharacter(
    charData: CharacterData(
      name: (raw['name'] ?? raw['chatName'] ?? raw['chat_name'] ?? 'Unknown') as String,
      description: (raw['description'] ?? '') as String,
      personality: (raw['personality'] ?? '') as String,
      scenario: (raw['scenario'] ?? '') as String,
      firstMes: (raw['first_mes'] ?? raw['first_message'] ?? '') as String,
      mesExample: (raw['mes_example'] ?? '') as String,
      creatorNotes: (raw['creator_notes'] ?? meta['raw_description_html'] ?? '') as String,
      systemPrompt: (raw['system_prompt'] ?? '') as String,
      postHistoryInstructions: (raw['post_history_instructions'] ?? '') as String,
      alternateGreetings: raw['alternate_greetings'] is List
          ? (raw['alternate_greetings'] as List).whereType<String>().toList()
          : <String>[],
      tags: [],
      creator: (meta['janitor_creator_name'] ?? raw['creator'] ?? '') as String,
      creatorId: (meta['janitor_creator_id'] ?? raw['creator_id'] ?? raw['creatorId'] ?? '') as String,
      characterBook: raw['character_book'],
    ),
    avatarUrl: _resolveAvatarUrl(_pickAvatarSource(raw, meta)),
  );
}

String _detectExtractionSource(String url) {
  if (RegExp(r'^https?://(?:www\.)?saucepan\.ai/companion/', caseSensitive: false).hasMatch(url)) {
    return 'saucepan';
  }
  return 'janitor';
}

Future<Map<String, dynamic>> _datacatExtract(String url, {bool publicFeed = true}) async {
  final token = await _getToken();
  final idempotencyKey = _uuid();
  final source = _detectExtractionSource(url);

  if (source == 'saucepan') {
    return catalogPost(
      '$_base/api/saucepan-extract/run',
      {
        'companion': url,
        'extractHidden': false,
        'includeSearch': true,
        'alwaysReextract': false,
        'netnsRole': 'general_scraper',
        'sourceKind': 'one_off',
        'sourceRef': idempotencyKey,
        'vpnNamespace': 'general_scraper',
        'idempotencyKey': idempotencyKey,
      },
      _authHeaders(token),
    );
  }

  return catalogPost(
    '$_base/api/character/smart-extract-v2',
    {
      'url': url,
      'appearOnPublicFeed': publicFeed,
      'useSeparateWorkerServer': true,
      'inlinePostExtractCreatorProfile': true,
      'idempotencyKey': idempotencyKey,
    },
    _authHeaders(token),
  );
}

Future<Map<String, dynamic>> _datacatExtractionStatus() async {
  final token = await _getToken();
  return catalogGet(
    '$_base/api/extraction/status?t=${DateTime.now().millisecondsSinceEpoch}',
    _authHeaders(token),
  );
}

Future<String?> datacatGetCharacterAvatar(String uuid) async {
  final token = await _getToken();
  final ts = DateTime.now().millisecondsSinceEpoch;
  final data = await catalogGet(
    '$_base/api/characters/$uuid?t=$ts',
    _authHeaders(token),
  );
  final char = (data['character'] ?? data) as Map<String, dynamic>;
  final meta = (data['metadata'] ?? <String, dynamic>{}) as Map<String, dynamic>;
  return _resolveAvatarUrl(_pickAvatarSource(char, meta));
}

class ExtractionResult {
  final CharacterData? charData;
  final String? avatarUrl;
  final String? characterId;
  final String? error;
  final String? phase;

  ExtractionResult({this.charData, this.avatarUrl, this.characterId, this.error, this.phase});
}

Future<ExtractionResult> datacatExtractAndPoll(
  String url, {
  void Function(String phase)? onPhaseChange,
}) async {
  try {
    final extractRes = await _datacatExtract(url);

    if (extractRes['characterId'] != null) {
      final charId = extractRes['characterId'] as String;
      final result = await datacatGetCharacter(charId);
      return ExtractionResult(
        charData: result.charData,
        avatarUrl: result.avatarUrl,
        characterId: charId,
      );
    }

    final myRequestId = extractRes['requestId'] as String?;
    final preStatus = await _datacatExtractionStatus();
    final prevRunId = (preStatus['run']?['requestId'] ?? '') as String;
    final uuidMatch = RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', caseSensitive: false)
        .firstMatch(url);
    final targetUuid = uuidMatch?.group(0);

    const maxAttempts = 60;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 3));

      try {
        final status = await _datacatExtractionStatus();
        final run = status['run'] as Map<String, dynamic>?;
        onPhaseChange?.call((status['inProgress']?['phase'] ?? run?['phase'] ?? '') as String);

        String? characterId;

        if (myRequestId != null) {
          if (run?['requestId'] == myRequestId && run?['lifecycle'] == 'terminal') {
            characterId = (run?['characterId'] ?? run?['targetId']) as String?;
          }
          if (characterId == null) {
            final taskHistory = (status['taskHistory'] as List?) ?? [];
            for (final h in taskHistory) {
              if (h['id'] == myRequestId && h['status'] == 'terminal') {
                characterId = h['target']?['id'] as String?;
                break;
              }
            }
          }
          if (characterId == null) {
            final history = (status['history'] as List?) ?? [];
            for (final h in history) {
              if (h['requestId'] == myRequestId) {
                characterId = h['characterId'] as String?;
                break;
              }
            }
          }
        }

        if (characterId == null && run?['lifecycle'] == 'terminal' && run?['requestId'] != prevRunId) {
          if (targetUuid == null || run?['targetId'] == targetUuid) {
            characterId = (run?['characterId'] ?? run?['targetId']) as String?;
          }
        }

        if (characterId == null && targetUuid != null) {
          final history = (status['history'] as List?) ?? [];
          for (final h in history) {
            if ((h['url'] as String?)?.contains(targetUuid) == true && h['characterId'] != null) {
              characterId = h['characterId'] as String;
              break;
            }
          }
        }

        if (characterId != null) {
          final result = await datacatGetCharacter(characterId);
          String? avatarUrl = result.avatarUrl;
          if (avatarUrl == null && _detectExtractionSource(url) == 'saucepan') {
            avatarUrl = await datacatGetCharacterAvatar(characterId);
          }
          return ExtractionResult(
            charData: result.charData,
            avatarUrl: avatarUrl,
            characterId: characterId,
          );
        }
      } catch (_) {}
    }

    return ExtractionResult(error: 'Extraction timed out');
  } catch (e) {
    return ExtractionResult(error: e.toString());
  }
}

List<CatalogTag> _cachedDatacatTags = [];
bool _datacatTagsFetched = false;
List<CatalogTag> getCachedDatacatTags() => _cachedDatacatTags;

Future<List<CatalogTag>> fetchDatacatTags() async {
  if (_datacatTagsFetched) return _cachedDatacatTags;
  try {
    final token = await _getToken();
    final data = await catalogGet(
      '$_base/api/tags/faceted?mode=recent&blockedTagIds=2&limit=250&offset=0&sort=count&includeTagIds=2',
      _authHeaders(token),
    );
    final tags = (data['tags'] as List?) ?? [];
    _cachedDatacatTags = tags
        .map((t) => CatalogTag(
              id: t['id'] as int?,
              name: (t['name'] ?? '') as String,
              slug: (t['slug'] ?? '') as String?,
            ))
        .toList();
    _datacatTagsFetched = true;
  } catch (_) {}
  return _cachedDatacatTags;
}

class _FreshParams {
  final String sortBy;
  final String window;
  const _FreshParams({required this.sortBy, required this.window});
}
