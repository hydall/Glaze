import 'package:freezed_annotation/freezed_annotation.dart';

part 'lorebook.freezed.dart';
part 'lorebook.g.dart';

@freezed
abstract class LorebookEntry with _$LorebookEntry {
  const factory LorebookEntry({
    required String id,
    @Default('') String comment,
    @Default(true) bool enabled,
    @Default(false) bool constant,
    @Default([]) List<String> keys,
    @Default([]) List<String> secondaryKeys,
    @Default(5) int selectiveLogic,
    @Default('') String content,
    @Default('matchGlobal') String position,
    @Default(100) int order,
    int? scanDepth,
    bool? caseSensitive,
    bool? matchWholeWords,
    @Default(100) int probability,
    @Default(false) bool preventRecursion,
    @Default(0) int sticky,
    @Default(0) int cooldown,
    @Default(0) int delay,
    @Default('') String group,
    @Default(0) int groupProminence,
    LorebookCharacterFilter? characterFilter,
    @Default(false) bool ignoreBudget,
    @Default(false) bool vectorSearch,
    @Default(true) bool useKeywordSearch,
    @Default(false) bool delayUntilRecursion,
    @Default(false) bool useGroupScoring,
    @Default('') String lorebookId,
    @Default('') String lorebookName,

    /// When true, this entry is excluded from the embedding pipeline —
    /// `LorebookEmbeddingService` skips it (deletes any existing embedding
    /// row), and the semantic-fallback path in `LorebookVectorSearch`
    /// never activates it. Useful for spoiler entries or entries that
    /// should only activate via explicit keyword match, never via
    /// semantic similarity. Mirrors Marinara's `excludeFromVectorization`
    /// flag. Rationale: spoiler entries or entries that should only activate
    /// via keyword are excluded from the embedding pipeline entirely — the
    /// semantic-fallback path in `LorebookVectorSearch` never activates them
    /// either (Marinara analog). Semantic activation for keyless entries was
    /// added so they can activate via cosine instead of being dead weight.
    @Default(false) bool excludeFromVectorization,
  }) = _LorebookEntry;

  factory LorebookEntry.fromJson(Map<String, dynamic> json) =>
      _$LorebookEntryFromJson(json);
}

@freezed
abstract class LorebookCharacterFilter with _$LorebookCharacterFilter {
  const factory LorebookCharacterFilter({
    @Default([]) List<String> names,
    @Default(false) bool isExclude,
  }) = _LorebookCharacterFilter;

  factory LorebookCharacterFilter.fromJson(Map<String, dynamic> json) =>
      _$LorebookCharacterFilterFromJson(json);
}

@freezed
abstract class Lorebook with _$Lorebook {
  const factory Lorebook({
    required String id,
    required String name,
    @Default(true) bool enabled,
    @Default('global') String activationScope,
    String? activationTargetId,
    @Default([]) List<LorebookEntry> entries,
    LorebookSettings? settings,
    @Default('') String description,
    @Default(0) int updatedAt,
  }) = _Lorebook;

  factory Lorebook.fromJson(Map<String, dynamic> json) =>
      _$LorebookFromJson(json);
}

@freezed
abstract class LorebookGlobalSettings with _$LorebookGlobalSettings {
  const factory LorebookGlobalSettings({
    @Default('keyword') String searchType,
    @Default('tavern') String keySearchMode,
    @Default(false) bool caseSensitive,
    @Default(false) bool matchWholeWords,
    @Default(true) bool recursiveScan,
    @Default(10) int scanDepth,
    @Default(5) int maxInjectedEntries,
    @Default('worldInfoBefore') String injectionPosition,
    @Default('tokens') String reserveMode,
    @Default(0) int reserveValue,
    @Default(50) int keywordVectorSplit,
    @Default(0.45) double vectorThreshold,
    @Default(10) int vectorTopK,

    /// Semantic fallback for keyless entries (Marinara analog). Entries
    /// with no `keys` and no `secondaryKeys` cannot activate via keyword
    /// scan; this fallback activates them via cosine similarity against
    /// the current chat text. Threshold is lower than `vectorThreshold`
    /// (default 0.3, Marinara-matching) and top-K is smaller (default 3)
    /// to avoid flooding the prompt with weakly-similar entries.
    /// Rationale: keyless entries (no keys AND no secondaryKeys) cannot
    /// activate via keyword scan; this fallback activates them via cosine
    /// similarity against the current chat text (Marinara supplementary
    /// system 4 analog).
    @Default(0.3) double fallbackThreshold,
    @Default(3) int fallbackTopK,
  }) = _LorebookGlobalSettings;

  factory LorebookGlobalSettings.fromJson(Map<String, dynamic> json) =>
      _$LorebookGlobalSettingsFromJson(json);
}

@freezed
abstract class LorebookSettings with _$LorebookSettings {
  const factory LorebookSettings({
    int? scanDepth,
    int? maxInjectedEntries,
    @Default(100) int contextPercent,
    @Default(0) int budgetCap,
    @Default('tokens') String reserveMode,
    @Default(10000) int reserveValue,
    @Default(0) int minActivations,
    @Default(0) int maxDepth,
    @Default(0) int maxRecursionSteps,
    @Default('character_first') String insertionStrategy,
    @Default('lorebooksMacro') String injectionPosition,
    @Default(true) bool includeNames,
    @Default(false) bool recursiveScan,
    @Default(false) bool caseSensitive,
    String? matchWholeWords,
    @Default(false) bool useGroupScoring,
    @Default(false) bool alertOnOverflow,
    @Default('both') String searchType,
    @Default('content') String embeddingTarget,
    @Default(0.45) double vectorThreshold,
    @Default(10) int vectorTopK,
    @Default(65) int keywordVectorSplit,
    @Default(5) int vectorScanDepth,
    @Default(true) bool vectorSearchEnabled,
    @Default(true) bool keySearchEnabled,
  }) = _LorebookSettings;

  factory LorebookSettings.fromJson(Map<String, dynamic> json) =>
      _$LorebookSettingsFromJson(json);
}

@freezed
abstract class LorebookActivations with _$LorebookActivations {
  const factory LorebookActivations({
    @Default({}) Map<String, List<String>> character,
    @Default({}) Map<String, List<String>> chat,
  }) = _LorebookActivations;

  factory LorebookActivations.fromJson(Map<String, dynamic> json) =>
      _$LorebookActivationsFromJson(json);
}
