import 'package:freezed_annotation/freezed_annotation.dart';

part 'memory_graph.freezed.dart';
part 'memory_graph.g.dart';

@freezed
abstract class MemoryEntity with _$MemoryEntity {
  const factory MemoryEntity({
    required String id,
    required String chatSessionId,
    required String memoryEntryId,
    @Default('') String name,
    @Default('character') String entityType,
    @Default([]) List<String> aliases,
    @Default('') String description,
    @Default(0.0) double salienceAvg,
    @Default(0.0) double saliencePeak,
    @Default('active') String status,
    @Default([]) List<String> facts,
    @Default({}) Map<String, double> emotionalValence,
    @Default(0) int mentionCount,
    @Default(0) int lastSeenMessageIndex,
    @Default('') String sourceHash,
    @Default(0) int createdAt,
    @Default(0) int updatedAt,
  }) = _MemoryEntity;

  factory MemoryEntity.fromJson(Map<String, dynamic> json) =>
      _$MemoryEntityFromJson(json);
}

@freezed
abstract class MemorySalience with _$MemorySalience {
  const factory MemorySalience({
    required String id,
    required String chatSessionId,
    required String memoryEntryId,
    @Default(0.0) double score,
    @Default([]) List<String> emotionalTags,
    @Default([]) List<String> narrativeFlags,
    @Default(false) bool hasDialogue,
    @Default(false) bool hasAction,
    @Default(0) int wordCount,
    @Default('heuristic') String scoreSource,
    @Default(0) int scoredAt,
    @Default(0) int createdAt,
  }) = _MemorySalience;

  factory MemorySalience.fromJson(Map<String, dynamic> json) =>
      _$MemorySalienceFromJson(json);
}

@freezed
abstract class MemoryCadence with _$MemoryCadence {
  const factory MemoryCadence({
    required String chatSessionId,
    @Default(0) int assistantMessagesSinceLastRun,
    @Default(0) int lastRunMessageIndex,
    @Default(0) int lastRunAt,
    @Default('graph') String lastRunKind,
  }) = _MemoryCadence;

  factory MemoryCadence.fromJson(Map<String, dynamic> json) =>
      _$MemoryCadenceFromJson(json);
}

@freezed
abstract class MemoryConsolidation with _$MemoryConsolidation {
  const factory MemoryConsolidation({
    required String id,
    required String chatSessionId,
    @Default(1) int tier,
    @Default('') String title,
    @Default('') String summary,
    @Default([]) List<String> sourceEntryIds,
    @Default([]) List<String> entityIds,
    @Default(0) int messageRangeStart,
    @Default(0) int messageRangeEnd,
    @Default(0.0) double salienceAvg,
    @Default([]) List<String> emotionalTags,
    @Default(0) int tokenCount,
    @Default('') String sourceModel,
    @Default('pending') String status,
    @Default('') String errorMessage,
    @Default(0) int createdAt,
    @Default(0) int updatedAt,
  }) = _MemoryConsolidation;

  factory MemoryConsolidation.fromJson(Map<String, dynamic> json) =>
      _$MemoryConsolidationFromJson(json);
}
