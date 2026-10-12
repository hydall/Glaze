import 'package:flutter/foundation.dart';

import '../catalog_models.dart';
import 'chub_provider.dart';
import 'datacat/datacat_creators.dart';
import 'janitor_provider.dart';

/// A creator's profile as the creator screen draws it, whichever source it
/// came from. A figure the source does not report is null and is not shown.
class CatalogCreatorProfile {
  final String name;
  final String handle;
  final String? avatarUrl;
  final String about;
  final bool verified;
  final int? characterCount;
  final int? chatCount;
  final int? messageCount;
  final int? followerCount;

  const CatalogCreatorProfile({
    required this.name,
    this.handle = '',
    this.avatarUrl,
    this.about = '',
    this.verified = false,
    this.characterCount,
    this.chatCount,
    this.messageCount,
    this.followerCount,
  });
}

/// The profile together with the first page of the creator's characters.
class CatalogCreatorFirstPage {
  final CatalogCreatorProfile profile;
  final CatalogSearchResult characters;

  const CatalogCreatorFirstPage({
    required this.profile,
    required this.characters,
  });
}

/// One creator's characters on one source, paged.
///
/// Stateful: each source pages its own way (DataCat by server cursor, the
/// others by page number), so the feed keeps its own place and the screen only
/// asks for "the first page" and "the next one".
abstract class CatalogCreatorFeed {
  /// Which provider the listed characters belong to — the preview opened from
  /// the grid reads the card through it.
  CatalogProvider get provider;

  Future<CatalogCreatorFirstPage> first(CatalogFilters filters);

  Future<CatalogSearchResult> next(CatalogFilters filters);
}

/// The feed for [item]'s creator on [provider], or null when the source has no
/// creator pages or the row does not say who the creator is.
///
/// JannyAI has none: it mirrors JanitorAI cards and keeps no per-creator
/// listing of its own.
CatalogCreatorFeed? catalogCreatorFeedFor(
  CatalogItem item,
  CatalogProvider provider, {
  String? chubApiKey,
  bool chubAccountNsfl = false,
}) {
  String? nonEmpty(String? s) => s == null || s.isEmpty ? null : s;
  switch (provider) {
    case CatalogProvider.datacat:
      // DataCat addresses creators by `ref`, not by the raw id — a Saucepan
      // creator's ref carries a `saucepan:` prefix.
      final ref = nonEmpty(item.creatorRef);
      return ref == null ? null : DatacatCreatorFeed(ref);
    case CatalogProvider.janitor:
      final id = nonEmpty(item.creatorId);
      return id == null
          ? null
          : JanitorCreatorFeed(id, name: item.creator ?? '');
    case CatalogProvider.chub:
      final username = nonEmpty(item.creatorId) ?? nonEmpty(item.creator);
      return username == null
          ? null
          : ChubCreatorFeed(
              username,
              apiKey: chubApiKey,
              accountNsfl: chubAccountNsfl,
            );
    case CatalogProvider.janny:
      return null;
  }
}

class DatacatCreatorFeed implements CatalogCreatorFeed {
  final String creatorRef;
  int _nextOffset = 0;

  DatacatCreatorFeed(this.creatorRef);

  @override
  CatalogProvider get provider => CatalogProvider.datacat;

  @override
  Future<CatalogCreatorFirstPage> first(CatalogFilters filters) async {
    final page = await datacatFetchCreator(creatorRef, filters: filters);
    final characters = page.characters;
    _nextOffset = characters.nextOffset ?? characters.characters.length;
    final p = page.profile;
    return CatalogCreatorFirstPage(
      profile: CatalogCreatorProfile(
        name: p.name,
        handle: p.handle,
        avatarUrl: p.avatarUrl,
        about: p.about,
        verified: p.verified,
        characterCount: p.characterCount,
        chatCount: p.chatCount,
        messageCount: p.messageCount,
      ),
      characters: characters,
    );
  }

  @override
  Future<CatalogSearchResult> next(CatalogFilters filters) async {
    final page = await datacatFetchCreatorCharacters(
      creatorRef,
      offset: _nextOffset,
      filters: filters,
    );
    _nextOffset = page.nextOffset ?? _nextOffset + page.characters.length;
    return page;
  }
}

class JanitorCreatorFeed implements CatalogCreatorFeed {
  final String creatorId;
  final String name;
  int _page = 1;

  JanitorCreatorFeed(this.creatorId, {required this.name});

  @override
  CatalogProvider get provider => CatalogProvider.janitor;

  @override
  Future<CatalogCreatorFirstPage> first(CatalogFilters filters) async {
    _page = 1;
    final profileFuture = _profile();
    final characters = await janitorFetchCreatorCharacters(
      creatorId,
      filters: filters,
    );
    final row = await profileFuture;
    final avatar = row?['avatar'];
    return CatalogCreatorFirstPage(
      profile: CatalogCreatorProfile(
        name: _str(row?['name']).isNotEmpty
            ? _str(row?['name'])
            : (_str(row?['user_name']).isNotEmpty
                  ? _str(row?['user_name'])
                  : name),
        handle: _str(row?['user_name']),
        avatarUrl: resolveJanitorUserAvatar(avatar is String ? avatar : null),
        about: _str(row?['about_me']),
        verified: row?['is_verified'] == true,
        characterCount:
            (row?['character_count'] as num?)?.toInt() ?? characters.total,
        followerCount: (row?['followers_count'] as num?)?.toInt(),
      ),
      characters: characters,
    );
  }

  /// Best effort: the grid is what the screen is for, and a profile that
  /// cannot be found leaves the header with the name the row already had.
  Future<Map<String, dynamic>?> _profile() async {
    try {
      return await janitorFetchCreatorProfile(creatorId, name: name);
    } catch (e) {
      debugPrint('[janitor] creator profile failed: $e');
      return null;
    }
  }

  @override
  Future<CatalogSearchResult> next(CatalogFilters filters) async {
    final page = await janitorFetchCreatorCharacters(
      creatorId,
      page: _page + 1,
      filters: filters,
    );
    _page++;
    return page;
  }
}

class ChubCreatorFeed implements CatalogCreatorFeed {
  final String username;
  final String? apiKey;
  final bool accountNsfl;
  int _page = 1;
  int _loaded = 0;

  ChubCreatorFeed(this.username, {this.apiKey, this.accountNsfl = false});

  @override
  CatalogProvider get provider => CatalogProvider.chub;

  /// Newest first, with only the reader's content toggles carried over: the
  /// catalog's tags and token bounds narrow a whole-site search, not a look at
  /// one creator's shelf.
  CatalogFilters _creatorFilters(CatalogFilters filters) =>
      CatalogFilters(sort: 'latest', nsfw: filters.nsfw, nsfl: filters.nsfl);

  Future<CatalogSearchResult> _fetchPage(
    int page,
    CatalogFilters filters,
  ) async {
    final result = await chubSearch(
      page: page,
      filters: _creatorFilters(filters),
      apiKey: apiKey,
      accountNsfl: accountNsfl,
      username: username,
    );
    _loaded += result.characters.length;
    // chub.ai hands back a cursor even on the last page, so the end is where
    // the running count reaches the total.
    return CatalogSearchResult(
      characters: result.characters,
      total: result.total,
      hasMore: result.characters.isNotEmpty && _loaded < result.total,
    );
  }

  @override
  Future<CatalogCreatorFirstPage> first(CatalogFilters filters) async {
    _page = 1;
    _loaded = 0;
    final userFuture = _user();
    final characters = await _fetchPage(1, filters);
    final user = await userFuture;
    final name = _str(user?['name']);
    return CatalogCreatorFirstPage(
      profile: CatalogCreatorProfile(
        name: name.isNotEmpty ? name : username,
        handle: username,
        avatarUrl: _str(user?['avatar_url']).isEmpty
            ? null
            : _str(user?['avatar_url']),
        about: _str(user?['bio']),
        characterCount: characters.total,
        followerCount: (user?['n_followers'] as num?)?.toInt(),
      ),
      characters: characters,
    );
  }

  /// Best effort, as for JanitorAI.
  Future<Map<String, dynamic>?> _user() async {
    try {
      return await chubFetchUser(username, apiKey: apiKey);
    } catch (e) {
      debugPrint('[chub] creator profile failed: $e');
      return null;
    }
  }

  @override
  Future<CatalogSearchResult> next(CatalogFilters filters) async {
    final page = await _fetchPage(_page + 1, filters);
    _page++;
    return page;
  }
}

String _str(Object? v) => v is String ? v.trim() : '';
