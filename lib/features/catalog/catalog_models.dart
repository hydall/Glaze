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

class CatalogSearchResult {
  final List<CatalogItem> characters;
  final int total;
  final bool? hasMore;

  CatalogSearchResult({required this.characters, required this.total, this.hasMore});
}

class DownloadedCharacter {
  final CharacterData charData;
  final String? avatarUrl;

  DownloadedCharacter({required this.charData, this.avatarUrl});
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
