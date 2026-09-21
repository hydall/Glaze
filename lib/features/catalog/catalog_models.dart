import 'package:freezed_annotation/freezed_annotation.dart';

part 'catalog_models.freezed.dart';

@freezed
abstract class CatalogItem with _$CatalogItem {
  const factory CatalogItem({
    required String id,
    required String name,
    String? avatarUrl,
    String? description,
    @Default([]) List<String> tags,
    @Default(0) int tokens,
    @Default(0) int chatCount,
    @Default(0) int messageCount,
    String? creator,
    String? creatorId,
    @Default(false) bool nsfw,
    String? slug,
    String? source,
    String? fullPath,

    /// How the character's creator is addressed on their own source. DataCat's
    /// creator screens are opened by this, not by [creatorId] — a Saucepan
    /// creator's ref carries a `saucepan:` prefix its raw id does not.
    String? creatorRef,

    /// Which library the row was scraped from (`janitor`, `saucepan`,
    /// `direct_upload`…). Disambiguates a character id that is only unique
    /// within one source.
    String? sourceKind,
  }) = _CatalogItem;
}

@freezed
abstract class CatalogFilters with _$CatalogFilters {
  const factory CatalogFilters({
    @Default('trending') String sort,
    @Default(false) bool nsfw,
    @Default(false) bool nsfl,
    @Default([]) List<int> tagIds,
    @Default([]) List<String> tagNames,
    @Default([]) List<String> excludeTagNames,
    @Default(29) int minTokens,
    @Default(100000) int maxTokens,

    // Chub-only search flags, mapped 1:1 onto the site's own `/search`
    // parameters. Other providers ignore them. `nsfl` is deliberately not here —
    // it is account-scoped and driven by [ChubAccount].
    @Default(false) bool nsfwOnly,
    @Default(false) bool requireImages,
    @Default(false) bool requireLore,
    @Default(false) bool requireCustomPrompt,
    @Default(false) bool requireExampleDialogues,
    @Default(false) bool requireAlternateGreetings,
    @Default(false) bool recommendedVerified,
    @Default(false) bool excludeMine,
    @Default(false) bool inclusiveOr,
    @Default(0) int minAiRating,
    @Default(0) int minTags,

    /// Time window the listing is scoped to (`all`, `week`, `24h`). Only
    /// DataCat expresses one; every other provider folds the window into its
    /// sort key and leaves this at the default.
    @Default('all') String window,
  }) = _CatalogFilters;
}

@freezed
abstract class CatalogTag with _$CatalogTag {
  const factory CatalogTag({
    int? id,
    required String name,
    String? slug,
  }) = _CatalogTag;
}

enum CatalogProvider { janitor, janny, datacat, chub }

/// What the Import button pulls in. The character and its lorebooks are
/// separate jobs — a lorebook may need a prompt capture and an LLM rebuild the
/// user did not ask for — so the import sheet lets them pick.
enum CatalogImportMode {
  /// The character card only.
  character,

  /// The lorebooks only; nothing is added to the character library.
  lorebooks,

  /// The character, then its lorebooks scoped to it.
  characterAndLorebooks;

  bool get importsCharacter => this != CatalogImportMode.lorebooks;
  bool get importsLorebooks => this != CatalogImportMode.character;
}

class CatalogSearchResult {
  final List<CatalogItem> characters;
  final int total;
  final bool? hasMore;

  /// Where the next page starts, when the server said so.
  ///
  /// A page number multiplied by a page size only lands on the next unseen row
  /// while the server returns exactly what was asked for. DataCat filters after
  /// paging and hands back the authoritative cursor, so a result that carries
  /// one is paged by it instead.
  final int? nextOffset;

  CatalogSearchResult({
    required this.characters,
    required this.total,
    this.hasMore,
    this.nextOffset,
  });
}

class DownloadedCharacter {
  final CharacterData charData;
  final String? avatarUrl;

  /// The avatar itself, for a source whose image endpoint needs the same
  /// credentials as the card and so cannot be re-fetched from a bare URL
  /// later. When set, the import saves these bytes and never looks at
  /// [avatarUrl].
  final List<int>? avatarBytes;

  DownloadedCharacter({
    required this.charData,
    this.avatarUrl,
    this.avatarBytes,
  });
}

class CharacterData {
  final String name;
  final String description;
  final String personality;
  final String scenario;
  final String firstMes;
  final String mesExample;
  final String creatorNotes;
  final String systemPrompt;
  final String postHistoryInstructions;
  final List<String> alternateGreetings;
  final List<String> tags;
  final String creator;
  final String creatorId;
  final dynamic characterBook;

  CharacterData({
    required this.name,
    this.description = '',
    this.personality = '',
    this.scenario = '',
    this.firstMes = '',
    this.mesExample = '',
    this.creatorNotes = '',
    this.systemPrompt = '',
    this.postHistoryInstructions = '',
    this.alternateGreetings = const [],
    this.tags = const [],
    this.creator = '',
    this.creatorId = '',
    this.characterBook,
  });
}

/// One user comment on a catalog character.
///
/// Shared by every source that exposes comments: JanitorAI's reviews endpoint
/// and DataCat's community endpoint both normalize onto this, so one view
/// renders both. Fields a source does not carry keep their defaults —
/// [likeCount] drives JanitorAI's default `sortBy=likes` order and is simply 0
/// for a source that does not rank comments.
class CatalogComment {
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

  const CatalogComment({
    required this.id,
    required this.content,
    required this.authorName,
    this.authorUserName = '',
    this.avatarUrl,
    this.likeCount = 0,
    this.replyCount = 0,
    this.isPinned = false,
    this.isVerified = false,
    this.hasPlus = false,
    this.createdAt,
  });
}
