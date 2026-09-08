import 'package:freezed_annotation/freezed_annotation.dart';

part 'memory_pipeline_settings.freezed.dart';
part 'memory_pipeline_settings.g.dart';

/// Memory pipeline settings — dedup threshold and shared auxiliary LLM
/// timeout.
///
/// Nested inside [PipelineSettings] under the `memoryPipeline` field.
///
/// `auxTimeoutMs` is a shared default timeout for auxiliary LLM calls
/// (cleaner, Ledger, dedup) when no service-specific timeout is
/// configured. MemoryBook retrieval does not use this; it is local/vector-only.
@freezed
abstract class MemoryPipelineSettings with _$MemoryPipelineSettings {
  const factory MemoryPipelineSettings({
    // ── Memory dedup ──────────────────────────────────────────────────────
    // memoryDedupAutoEnabled is hardcoded to false — dedup only runs when the
    // user clicks the "Dedup" button (manual only). Cosine similarity
    // threshold for candidate pairs (0.0-1.0). Pairs with cosine >= this
    // value are sent to the LLM for merge/drop/keep.
    @Default(0.85) double memoryDedupThreshold,

    // ── Shared auxiliary LLM timeout ──────────────────────────────────────
    // Default timeout (ms) for auxiliary LLM calls when no service-specific
    // timeout is configured (postCleanerTimeoutMs, studioLedgerTimeoutMs).
    @Default(60000) int auxTimeoutMs,
  }) = _MemoryPipelineSettings;

  factory MemoryPipelineSettings.fromJson(Map<String, dynamic> json) =>
      _$MemoryPipelineSettingsFromJson(json);
}
