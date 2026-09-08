import 'package:freezed_annotation/freezed_annotation.dart';

part 'memory_book.freezed.dart';
part 'memory_book.g.dart';

@freezed
abstract class MemoryDraft with _$MemoryDraft {
  const factory MemoryDraft({
    required String id,
    @Default('') String title,
    @Default('') String content,
    @Default([]) List<String> keys,
    @Default([]) List<String> glazeKeys,
    @Default(false) bool vectorSearch,
    @Default([]) List<String> messageIds,
    @Default(0) int sourceSwipeId,
    @Default(0) int sourceAgentSwipeId,
    MessageRange? messageRange,
    @Default('pending_generation') String status,
    @Default('') String source,
    @Default(0) int createdAt,
    @Default(0) int updatedAt,
    int? generatedAt,
    String? error,
  }) = _MemoryDraft;

  factory MemoryDraft.fromJson(Map<String, dynamic> json) =>
      _$MemoryDraftFromJson(json);
}

@freezed
abstract class MessageRange with _$MessageRange {
  const factory MessageRange({required int start, required int end}) =
      _MessageRange;

  factory MessageRange.fromJson(Map<String, dynamic> json) =>
      _$MessageRangeFromJson(json);
}

@freezed
abstract class MemoryEntry with _$MemoryEntry {
  const factory MemoryEntry({
    required String id,
    @Default('') String title,
    @Default([]) List<String> keys,
    @Default('') String content,
    @Default('active') String status,
    @Default(false) bool vectorSearch,
    @Default([]) List<String> messageIds,
    @Default(0) int sourceSwipeId,
    @Default(0) int sourceAgentSwipeId,
    int? createdAt,
    MessageRange? messageRange,
    @Default(0) double importance,
    @Default(false) bool temporallyBlind,
    @Default('') String arc,
    @Default('curated') String kind,
    @Default('') String sourceHash,

    /// Provenance marker. Empty for old/manual entries and `scan_chat` for
    /// entries promoted from a generated range-summary draft.
    @Default('') String source,

    /// User-controlled protection for manually curated entries.
    @Default(false) bool locked,

    /// When true, this entry is excluded from the embedding pipeline —
    /// `MemoryEmbeddingService` skips it, and `MessageRecallService` /
    /// memory vector search do not surface it. Useful for spoiler entries
    /// or entries that should only activate via explicit keyword match,
    /// never via semantic similarity. Mirrors Marinara's
    /// `excludeFromVectorization` flag. Rationale: spoiler entries or entries
    /// that should only activate via keyword are excluded from the embedding
    /// pipeline entirely — `MemoryEmbeddingService` skips them and
    /// `MessageRecallService` / memory vector search do not surface them
    /// (Marinara analog).
    @Default(false) bool excludeFromVectorization,
  }) = _MemoryEntry;

  factory MemoryEntry.fromJson(Map<String, dynamic> json) =>
      _$MemoryEntryFromJson(_migrateEntryInPlace(json));
}

@freezed
abstract class MemoryBookSettings with _$MemoryBookSettings {
  const factory MemoryBookSettings({
    @Default(true) bool enabled,
    @Default('fast') String memoryMode,
    @Default(true) bool autoCreateEnabled,
    @Default(false) bool autoGenerateEnabled,
    @Default(7) int maxInjectedEntries,
    @Default(true) bool memoryExcerptingEnabled,
    @Default('hybrid') String memoryPackingMode,
    @Default(500) int memoryExcerptTokensPerChunk,
    @Default(2) int memoryExcerptChunksPerEntry,

    /// Top-N entries (by entry score) that each receive at least one chunk in
    /// chunk_first mode. 0 disables the entry floor pass.
    @Default(3) int chunkFirstTopEntries,

    /// Best chunks reserved per guaranteed entry in chunk_first floor pass.
    @Default(1) int chunkFirstTopChunks,
    @Default(0.35) double maxInjectionBudgetPercent,
    int? maxInjectedTokens,
    @Default('auto') String memoryBudgetPreset,
    @Default(15) int autoCreateInterval,
    @Default(4) int autoCreateLagMessages,
    @Default(true) bool useDelayedAutomation,
    @Default('hard_block') String injectionTarget,
    @Default(3) int batchSize,
    @Default(false) bool vectorSearchEnabled,
    @Default('glaze') String keyMatchMode,
    @Default('detailed_beats') String promptPreset,
    @Default(true) bool diversityAware,
    @Default(0.15) double diversityPenalty,
    @Default(true) bool recencyBoost,
    @Default(100) double recencyHalfLifeDays,
    @Default(true) bool importanceBoost,
    @Default(0.5) double importanceWeight,
    @Default(true) bool sourceWindowExclusion,
    @Default(false) bool factualContinuityGuardEnabled,
    @Default(true) bool queryIncludeAssistant,
    @Default(6) int queryRecentTurns,
    @Default(1500) int queryMaxChars,
    @Default(3) int cadenceInterval,

    /// Enables the memory consolidation pass. The consolidation LLM config
    /// (model/endpoint/key/timeout) lives in [PipelineSettings]; this flag is
    /// the retrieval-side toggle that gates whether the post-turn pipeline
    /// triggers consolidation at all.
    @Default(false) bool consolidationEnabled,
    @Default(5) int consolidationThreshold,
  }) = _MemoryBookSettings;

  factory MemoryBookSettings.fromJson(Map<String, dynamic> json) =>
      _$MemoryBookSettingsFromJson(_migrateInjectionTargetInPlace(json));
}

/// Translates the legacy `summary_block` / `summary_macro` enum values
/// (pre-{{memory}}-split) to `hard_block` / `macro` in-place. The old
/// values were misleadingly named because the "summary" prefix was
/// about *where* memory goes, not about the summary feature itself.
///
/// Also migrates the removed `agentic` retrieval mode to `deep`. Old
/// MemoryBook JSON with `memoryMode: "agentic"` keeps the strongest local
/// retrieval mode without restoring removed hidden LLM retrieval calls.
Map<String, dynamic> _migrateInjectionTargetInPlace(Map<String, dynamic> json) {
  var result = json;
  final injectionTarget = result['injectionTarget'];
  if (injectionTarget == 'summary_block') {
    result = {...result, 'injectionTarget': 'hard_block'};
  } else if (injectionTarget == 'summary_macro') {
    result = {...result, 'injectionTarget': 'macro'};
  }
  if (result['memoryMode'] == 'agentic') {
    result = {...result, 'memoryMode': 'deep'};
  }
  return result;
}

/// Coerces new optional fields into safe defaults when reading older JSON
/// payloads written before the v2 selector schema.
Map<String, dynamic> _migrateEntryInPlace(Map<String, dynamic> json) {
  var out = json;
  if (out['messageRange'] != null && out['messageRange'] is! Map) {
    out = {...out, 'messageRange': null};
  }
  if (out['messageRange'] == null) {
    final range = _parseLegacyTitleRange(out['title']);
    if (range != null) {
      out = {...out, 'messageRange': range};
    }
  }
  if (out['importance'] is! num) {
    out = {...out, 'importance': 0.0};
  }
  if (out['temporallyBlind'] is! bool) {
    out = {...out, 'temporallyBlind': false};
  }
  if (out['arc'] is! String) {
    out = {...out, 'arc': ''};
  }
  if (out['kind'] is! String) {
    out = {...out, 'kind': 'curated'};
  }
  if (out['sourceHash'] is! String) {
    out = {...out, 'sourceHash': ''};
  }
  if (out['source'] is! String) {
    out = {...out, 'source': ''};
  }
  return out;
}

Map<String, int>? _parseLegacyTitleRange(Object? title) {
  if (title is! String) return null;
  final match = RegExp(r'^\s*(\d+)\s*-\s*(\d+)\s*$').firstMatch(title);
  if (match == null) return null;
  final start = int.tryParse(match.group(1)!);
  final end = int.tryParse(match.group(2)!);
  if (start == null || end == null || start <= 0 || end < start) return null;
  return {'start': start, 'end': end};
}

@freezed
abstract class MemoryBook with _$MemoryBook {
  const factory MemoryBook({
    required String id,
    required String sessionId,
    @Default([]) List<MemoryEntry> entries,
    @Default([]) List<MemoryDraft> pendingDrafts,
    @Default(MemoryBookSettings()) MemoryBookSettings settings,
    @Default(0) int lastProcessedMessageCount,
    @Default(0) int updatedAt,
  }) = _MemoryBook;

  factory MemoryBook.fromJson(Map<String, dynamic> json) =>
      _$MemoryBookFromJson(json);
}
