import 'package:freezed_annotation/freezed_annotation.dart';

part 'studio_ledger_export.freezed.dart';
part 'studio_ledger_export.g.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Studio Ledger Export models
//
// These represent the machine-readable <glaze_memory_export> JSON that the
// Studio Ledger LLM emits after each final assistant response. The ledger
// produces a structured "ops" patch list and optional human-readable sections
// (sceneState, entities, arcState) for diagnostics.
//
// See docs/rules/database.md for the tracker namespace schema.
// The export produces a structured "ops" patch list (authoritative for state
// writes) and optional human-readable sections (sceneState, entities, arcState)
// for diagnostics. Persistence prefers validated patch operations
// so the model cannot accidentally rewrite or drop the whole state tree.
// ─────────────────────────────────────────────────────────────────────────────

/// Allowed op codes in the patch list.
/// Only these ops are accepted; others are rejected by validation.
enum LedgerOpCode { set, delete }

/// One patch operation produced by the Studio Ledger.
///
/// Validated fields:
/// - [op] must be in [LedgerOpCode].
/// - [key] must start with a known namespace prefix (npc:, relationship:,
///   arc:, world:, scene.).
/// - [value] must be non-empty for set.
/// - [eventState] (optional) must be one of the known event-state tokens.
@freezed
abstract class LedgerOp with _$LedgerOp {
  const factory LedgerOp({
    required String op,
    required String key,
    @Default('') String value,
    @Default('') String evidence,
    @Default('') String eventState,
  }) = _LedgerOp;

  factory LedgerOp.fromJson(Map<String, dynamic> json) =>
      _$LedgerOpFromJson(json);
}

/// Compact present/absent entity entry in sceneState.
@freezed
abstract class LedgerPresentEntity with _$LedgerPresentEntity {
  const factory LedgerPresentEntity({
    required String name,
    @Default('present') String status,
    @Default('') String reason,
    @Default('high') String confidence,
  }) = _LedgerPresentEntity;

  factory LedgerPresentEntity.fromJson(Map<String, dynamic> json) =>
      _$LedgerPresentEntityFromJson(json);
}

/// Scene-state section of the ledger export (diagnostics + prompt readability).
@freezed
abstract class LedgerSceneState with _$LedgerSceneState {
  const factory LedgerSceneState({
    @Default('') String time,
    @Default('') String date,
    @Default('') String location,
    @Default('') String immediateThread,
    @Default([]) List<LedgerPresentEntity> presentEntities,
    @Default([]) List<String> activeTensions,
  }) = _LedgerSceneState;

  factory LedgerSceneState.fromJson(Map<String, dynamic> json) =>
      _$LedgerSceneStateFromJson(json);
}

/// One entity entry in the entities section (diagnostics).
@freezed
abstract class LedgerEntity with _$LedgerEntity {
  const factory LedgerEntity({
    required String name,
    @Default([]) List<String> aliases,
    @Default('') String type,
    @Default('') String relationshipToUser,
    @Default('') String attitudeToUser,
    @Default([]) List<String> knowledge,
    @Default([]) List<String> boundaries,
    @Default([]) List<String> cardOverrides,
  }) = _LedgerEntity;

  factory LedgerEntity.fromJson(Map<String, dynamic> json) =>
      _$LedgerEntityFromJson(json);
}

/// One arc-state entry (diagnostics + card-hook suppression).
@freezed
abstract class LedgerArcState with _$LedgerArcState {
  const factory LedgerArcState({
    required String id,
    @Default('') String title,
    @Default('seeded') String status,
    @Default('') String summary,
    @Default(false) bool doNotReopen,
    @Default('') String cardOverride,
    @Default([]) List<String> entities,
    @Default([]) List<String> topics,
  }) = _LedgerArcState;

  factory LedgerArcState.fromJson(Map<String, dynamic> json) =>
      _$LedgerArcStateFromJson(json);
}

/// One atomic character-state delta emitted by the existing Studio Ledger.
/// IDs and provenance are assigned from the assistant-swipe anchor at write time.
@freezed
abstract class LedgerKnowledgeFact with _$LedgerKnowledgeFact {
  const factory LedgerKnowledgeFact({
    required String knowerKey,
    @Default('') String knowerName,
    required String subjectKey,
    @Default('') String subjectName,
    @Default('knowledge') String factClass,
    @Default('') String scopeKey,
    required String predicate,
    required String object,
    @Default('observed') String epistemicState,
    @Default(0.5) double confidence,
    @Default(0.5) double importance,
    @Default([]) List<String> entities,
    @Default([]) List<String> topics,
    String? supersedesId,
  }) = _LedgerKnowledgeFact;

  factory LedgerKnowledgeFact.fromJson(Map<String, dynamic> json) =>
      _$LedgerKnowledgeFactFromJson(json);
}

/// The full machine-readable export from Studio Ledger.
///
/// [ops] is the authoritative patch list — persistence uses only ops.
/// Other sections (sceneState, entities, arcState) are
/// diagnostic / prompt-readability aids.
@freezed
abstract class StudioLedgerExport with _$StudioLedgerExport {
  const factory StudioLedgerExport({
    LedgerSceneState? sceneState,
    @Default([]) List<LedgerEntity> entities,
    @Default([]) List<LedgerArcState> arcState,
    @Default([]) List<LedgerKnowledgeFact> knowledgeFacts,
    @Default([]) List<LedgerOp> ops,
  }) = _StudioLedgerExport;

  factory StudioLedgerExport.fromJson(Map<String, dynamic> json) =>
      _$StudioLedgerExportFromJson(json);
}
