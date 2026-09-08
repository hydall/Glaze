import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'janitor_webview_proxy.dart';
import '../catalog_models.dart';

/// The signed-in account's block list (`/hampter/profiles/mine/blocked-content`).
///
/// [bots] and [creators] are kept as opaque JSON so they survive a round-trip
/// when we PATCH only [tags] back — the API replaces the whole `block_list`.
/// [keywords] are arbitrary strings; [tags] are JanitorAI tag ids (see
/// [fetchJanitorTags]).
class JanitorBlockList {
  final List<dynamic> bots;
  final List<dynamic> creators;
  final List<String> keywords;
  final List<int> tags;

  const JanitorBlockList({
    this.bots = const [],
    this.creators = const [],
    this.keywords = const [],
    this.tags = const [],
  });

  JanitorBlockList copyWith({List<int>? tags, List<String>? keywords}) =>
      JanitorBlockList(
        bots: bots,
        creators: creators,
        keywords: keywords ?? this.keywords,
        tags: tags ?? this.tags,
      );
}

const _blockedContentUrl =
    'https://janitorai.com/hampter/profiles/mine/blocked-content';
const _profileUrl = 'https://janitorai.com/hampter/profiles/mine';

/// Reads the signed-in account's current block list. Requires a logged-in
/// JanitorAI session (the bearer token is attached in-page by the proxy).
Future<JanitorBlockList> fetchJanitorBlockedContent() async {
  final data = await _janitorFetch(_blockedContentUrl) as Map<String, dynamic>;
  return JanitorBlockList(
    bots: (data['bots'] as List?)?.toList() ?? const [],
    creators: (data['creators'] as List?)?.toList() ?? const [],
    keywords: ((data['keywords'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    tags: ((data['tags'] as List?) ?? const [])
        .whereType<num>()
        .map((e) => e.toInt())
        .toList(),
  );
}

/// Keyword autocomplete for the block-list input. Mirrors the site's
/// `/hampter/characters/tags/suggest?prefix=…` — returns free-text suggestions
/// the user can block as keywords. Empty on error / empty prefix.
Future<List<String>> fetchJanitorTagSuggestions(String prefix) async {
  final p = prefix.trim();
  if (p.isEmpty) return const [];
  try {
    final url =
        'https://janitorai.com/hampter/characters/tags/suggest?prefix=${Uri.encodeQueryComponent(p)}';
    final data = await _janitorFetch(url) as Map<String, dynamic>;
    return ((data['suggestions'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Persists [list] via `PATCH /hampter/profiles/mine`. Sends the full
/// `block_list` (bots/creators preserved from the prior fetch) so blocked bots
/// and creators are not wiped when only tags change.
Future<void> saveJanitorBlockList(JanitorBlockList list) async {
  final payload = jsonEncode({
    'block_list': {
      'bots': list.bots,
      'creators': list.creators,
      'keywords': list.keywords,
      'tags': list.tags,
    },
  });
  await JanitorWebViewProxy.instance
      .fetch(_profileUrl, method: 'PATCH', body: payload);
}

const _hampterUrl = 'https://janitorai.com/hampter/characters';
const _imageBase = 'https://ella.janitorai.com/bot-avatars/';

const _fallbackTagMap = <int, String>{
  1: 'Male',
  2: 'Female',
  3: 'Non-binary',
  4: 'Celebrity',
  5: 'OC',
  6: 'Fictional',
  7: 'Real',
  8: 'Game',
  9: 'Anime',
  10: 'Historical',
  11: 'Royalty',
  12: 'Detective',
  13: 'Hero',
  14: 'Villain',
  15: 'Magical',
  16: 'Non-human',
  17: 'Monster',
  18: 'Monster Girl',
  19: 'Alien',
  20: 'Robot',
  21: 'Politics',
  22: 'Vampire',
  23: 'Giant',
  24: 'OpenAI',
  25: 'Elf',
  26: 'Multiple',
  27: 'VTuber',
  28: 'Dominant',
  29: 'Submissive',
  30: 'Scenario',
  31: 'Pokemon',
  32: 'Assistant',
  34: 'Non-English',
  36: 'Philosophy',
  38: 'RPG',
  39: 'Religion',
  41: 'Books',
  42: 'AnyPOV',
  43: 'Angst',
  44: 'Demi-Human',
  45: 'Enemies to Lovers',
  46: 'Smut',
  47: 'MLM',
  48: 'WLW',
  49: 'Action',
  50: 'Romance',
  51: 'Horror',
  52: 'Slice of Life',
  53: 'Fantasy',
  54: 'Drama',
  55: 'Comedy',
  56: 'Mystery',
  57: 'Sci-Fi',
  59: 'Yandere',
  60: 'Furry',
  61: 'Movies/TV',
};

List<CatalogTag> _cachedJanitorTags = [];
Map<int, String> _janitorTagMap = Map.from(_fallbackTagMap);
bool _tagsFetched = false;
List<CatalogTag> getCachedJanitorTags() => _cachedJanitorTags;

Future<List<CatalogTag>> fetchJanitorTags() async {
  if (_tagsFetched) return _cachedJanitorTags;
  try {
    const tagsUrl = 'https://janitorai.com/hampter/tags';
    final data = (await _janitorFetch(tagsUrl) as List).cast<dynamic>();
    if (data.isNotEmpty) {
      _cachedJanitorTags = data
          .map((t) => CatalogTag(
                id: t['id'] as int?,
                name: (t['name'] ?? '') as String,
                slug: (t['slug'] ?? '') as String?,
              ))
          .toList();
      final map = <int, String>{};
      for (final t in data) {
        if (t['id'] != null) map[t['id'] as int] = (t['name'] ?? '') as String;
      }
      _janitorTagMap = map;
    } else {
      _cachedJanitorTags = _fallbackTagMap.entries
          .map((e) => CatalogTag(id: e.key, name: e.value))
          .toList();
    }
    _tagsFetched = true;
  } catch (_) {
    if (_cachedJanitorTags.isEmpty) {
      _cachedJanitorTags = _fallbackTagMap.entries
          .map((e) => CatalogTag(id: e.key, name: e.value))
          .toList();
    }
  }
  return _cachedJanitorTags;
}

Future<dynamic> _janitorFetch(String url) async {
  debugPrint('[CF] janitorFetch: ${url.length > 80 ? url.substring(0, 80) : url}');
  final body = await JanitorWebViewProxy.instance.fetch(url);
  return jsonDecode(body);
}

Future<CatalogSearchResult> janitorSearch({
  String query = '',
  int page = 1,
  CatalogFilters filters = const CatalogFilters(),
}) async {
  final activeSort = filters.sort;
  String sortMode = activeSort;
  if (activeSort == 'trending_24h') {
    sortMode = 'trending24';
  } else if (activeSort == 'newest' || activeSort == 'latest') {
    sortMode = 'latest';
  }

  final params = StringBuffer(
    'page=$page&mode=${filters.nsfw ? 'all' : 'sfw'}&sort=$sortMode',
  );
  if (query.isNotEmpty) params.write('&search=${Uri.encodeComponent(query)}');

  for (final tagId in filters.tagIds) {
    params.write('&tag_id[]=$tagId');
  }
  for (final tagName in filters.tagNames) {
    params.write('&custom_tags[]=${Uri.encodeComponent(tagName)}');
  }

  final searchUrl = '$_hampterUrl?$params';
  final data = await _janitorFetch(searchUrl);

  List<dynamic> hits;
  if (data is List) {
    hits = data;
  } else {
    hits = (data['characters'] as List?) ?? (data['data'] as List?) ?? [];
  }

  return CatalogSearchResult(
    characters: hits.map(_normalizeHit).toList(),
    total: data is Map ? (data['total'] as int?) ?? 0 : hits.length,
  );
}

/// Fetches the raw `/hampter/characters/{id}` metadata map. Exposed so callers
/// (catalog preview, lorebook tab) can read `scripts`, `showdefinition`, etc.
/// without a second request.
Future<Map<String, dynamic>> janitorFetchCharacterMeta(String id) async {
  final charUrl = '$_hampterUrl/$id';
  return await _janitorFetch(charUrl) as Map<String, dynamic>;
}

/// Builds a [DownloadedCharacter] from already-fetched [meta].
DownloadedCharacter janitorCharacterFromMeta(Map<String, dynamic> meta) =>
    _convertToGlaze(meta);

/// Whether the creator left the character definition PUBLIC (`showdefinition`).
/// When true, `/hampter/characters/{id}` returns the real card fields, so the
/// card can be taken verbatim with NO generateAlpha extraction. Mirrors JAR's
/// `isCardPublic`.
bool janitorDefinitionPublic(Map<String, dynamic> meta) {
  final shows = meta['showdefinition'] == true;
  if (!shows) return false;
  final personality = (meta['personality'] ?? '').toString().trim();
  final scenario = (meta['scenario'] ?? '').toString().trim();
  return personality.isNotEmpty || scenario.isNotEmpty;
}

Future<DownloadedCharacter> janitorFetchCharacter(String id) async {
  final data = await janitorFetchCharacterMeta(id);
  return _convertToGlaze(data);
}

String? resolveJanitorAvatar(String? url) {
  if (url == null) return null;
  if (url.startsWith('http')) return url;
  if (url.startsWith('/')) return 'https://ella.janitorai.com$url?width=400';
  if (!url.contains('/')) return '$_imageBase$url?width=400';
  return 'https://ella.janitorai.com/$url?width=400';
}

const _userImageBase = 'https://ella.janitorai.com/user-avatars/';

/// Resolves a commenter's profile-avatar id (from `user_profiles.avatar`) to a
/// full CDN URL. User avatars live under a different prefix than bot avatars
/// (see [resolveJanitorAvatar]); a bare filename is served from
/// `/user-avatars/`. Returns null when the profile has no avatar.
String? resolveJanitorUserAvatar(String? url) {
  if (url == null || url.isEmpty) return null;
  if (url.startsWith('http')) return url;
  if (url.startsWith('/')) return 'https://ella.janitorai.com$url?width=100';
  if (!url.contains('/')) return '$_userImageBase$url?width=100';
  return 'https://ella.janitorai.com/$url?width=100';
}

/// Page size used for the reviews endpoint, mirroring the JanitorAI web client
/// (`size=20`). A full page is the signal there *may* be more — see
/// [janitorFetchReviews].
const kJanitorReviewsPageSize = 20;

/// A single user comment ("review") on a JanitorAI character, returned by
/// `/hampter/reviews/{characterId}`. [replyCount] is the API's `comment_count`
/// (replies to this comment); [likeCount] drives the default `sortBy=likes`
/// order. Pinned comments come first in the response.
class JanitorReview {
  final String id;
  final String content;
  final String authorName;
  final String authorUserName;
  final String? avatarUrl;
  final int likeCount;
  final int replyCount;
  final bool isPinned;
  final bool isVerified;
  final bool hasPlus;
  final DateTime? createdAt;

  const JanitorReview({
    required this.id,
    required this.content,
    required this.authorName,
    required this.authorUserName,
    this.avatarUrl,
    this.likeCount = 0,
    this.replyCount = 0,
    this.isPinned = false,
    this.isVerified = false,
    this.hasPlus = false,
    this.createdAt,
  });
}

/// Fetches one page of comments for [characterId]. The endpoint paginates and
/// returns a bare JSON array (no total/`hasMore`), so callers detect the end by
/// a short page: fewer than [size] items means there are no further pages.
/// Defaults match the web client (`size=20&sortBy=likes`).
Future<List<JanitorReview>> janitorFetchReviews(
  String characterId, {
  int page = 1,
  int size = kJanitorReviewsPageSize,
  String sortBy = 'likes',
}) async {
  final url =
      'https://janitorai.com/hampter/reviews/$characterId?page=$page&size=$size&sortBy=$sortBy';
  final data = await _janitorFetch(url);
  if (data is! List) return const [];
  return data
      .whereType<Map<String, dynamic>>()
      .map(_normalizeReview)
      .toList();
}

JanitorReview _normalizeReview(Map<String, dynamic> m) {
  final profile = (m['user_profiles'] as Map<String, dynamic>?) ?? const {};
  final name = (profile['name'] ?? profile['user_name'] ?? 'Anonymous')
      .toString()
      .trim();
  return JanitorReview(
    id: (m['id'] ?? '') as String,
    content: (m['content'] ?? '') as String,
    authorName: name.isEmpty ? 'Anonymous' : name,
    authorUserName: (profile['user_name'] ?? '').toString(),
    avatarUrl: resolveJanitorUserAvatar(profile['avatar'] as String?),
    likeCount: (m['like_count'] as num?)?.toInt() ?? 0,
    replyCount: (m['comment_count'] as num?)?.toInt() ?? 0,
    isPinned: (m['is_pinned'] as bool?) ?? false,
    isVerified: (profile['is_verified'] as bool?) ?? false,
    hasPlus: (profile['plusbadge'] as bool?) ?? false,
    createdAt: DateTime.tryParse((m['created_at'] ?? '').toString()),
  );
}

List<String> _tagIdsToNames(List<dynamic> tagIds) {
  return tagIds
      .map((id) => _janitorTagMap[id])
      .where((name) => name != null)
      .cast<String>()
      .toList();
}

CatalogItem _normalizeHit(dynamic hit) {
  final m = hit as Map<String, dynamic>;
  List<String> standardTags;
  if (m['tags'] is List) {
    standardTags = (m['tags'] as List)
        .map((t) => t is String ? t : (t['name'] ?? t['slug'] ?? '') as String)
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty && t.toLowerCase() != 'limitless')
        .toList();
  } else {
    standardTags = _tagIdsToNames(m['tagIds'] as List? ?? [])
        .where((t) => t.toLowerCase() != 'limitless')
        .toList();
  }

  final isNsfw = (m['isNsfw'] as bool?) ?? (m['is_nsfw'] as bool?) ?? false;
  final tags = [isNsfw ? 'NSFW' : 'SFW', ...standardTags];
  if (m['custom_tags'] is List) {
    tags.addAll((m['custom_tags'] as List).map((t) => '#$t'));
  }

  return CatalogItem(
    id: (m['id'] ?? '') as String,
    name: (m['name'] ?? m['bot_name'] ?? 'Unknown') as String,
    avatarUrl: resolveJanitorAvatar(
        (m['avatar'] ?? m['image']) as String?),
    description: (m['description'] ?? m['short_description'] ?? '') as String,
    tags: tags.toSet().toList(),
    tokens: (m['totalToken'] ?? m['total_tokens'] ?? 0) as int,
    chatCount: (m['stats']?['chat'] ?? m['public_chat_count'] ?? 0) as int,
    messageCount:
        (m['stats']?['message'] ?? m['public_message_count'] ?? 0) as int,
    creator: (m['creatorUsername'] ?? m['creator'] ?? '') as String,
    creatorId: (m['creator_id'] ?? m['creatorId'] ?? '') as String?,
    nsfw: isNsfw,
    slug: (m['slug'] ?? m['id'] ?? '') as String?,
    source: 'janitor',
  );
}

DownloadedCharacter _convertToGlaze(Map<String, dynamic> m) {
  List<String> standardTags;
  if (m['tags'] is List) {
    standardTags = (m['tags'] as List)
        .map((t) => t is String ? t : (t['name'] ?? t['slug'] ?? '') as String)
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty && t.toLowerCase() != 'limitless')
        .toList();
  } else {
    standardTags = _tagIdsToNames(m['tagIds'] as List? ?? [])
        .where((t) => t.toLowerCase() != 'limitless')
        .toList();
  }

  final isNsfw = (m['is_nsfw'] ?? m['isNsfw']) as bool? ?? false;
  final tags = [isNsfw ? 'NSFW' : 'SFW', ...standardTags];
  if (m['custom_tags'] is List) {
    tags.addAll((m['custom_tags'] as List).map((t) => '#$t'));
  }

  return DownloadedCharacter(
    charData: CharacterData(
      name: (m['name'] ?? m['chat_name'] ?? 'Unknown') as String,
      description: '',
      personality: (m['personality'] ?? m['description'] ?? '') as String,
      scenario: (m['scenario'] ?? '') as String,
      firstMes: (m['first_message'] ?? m['first_mes'] ?? '') as String,
      mesExample:
          (m['example_dialogs'] ?? m['mes_example'] ?? m['example_dialogs'] ?? '')
              as String,
      creatorNotes: (m['description'] ?? m['creator_notes'] ?? '') as String,
      systemPrompt: '',
      postHistoryInstructions: '',
      alternateGreetings: m['first_messages'] is List
          ? (m['first_messages'] as List).whereType<String>().toList()
          : <String>[],
      tags: tags.toSet().toList(),
      creator: (m['creator_name'] ?? m['creator'] ?? '') as String,
      creatorId: (m['creator_id'] ?? '') as String,
      characterBook: null,
    ),
    avatarUrl: resolveJanitorAvatar(
        (m['avatar'] ?? m['image']) as String?),
  );
}
