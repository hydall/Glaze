import 'package:freezed_annotation/freezed_annotation.dart';

part 'memory_pipeline_settings.freezed.dart';
part 'memory_pipeline_settings.g.dart';

/// Shared memory-pipeline auxiliary LLM settings.
///
/// Nested inside [PipelineSettings] under the `memoryPipeline` field.
///
/// `auxTimeoutMs` is a shared default timeout for auxiliary LLM calls
/// (cleaner and Ledger) when no service-specific timeout is
/// configured. MemoryBook retrieval does not use this; it is local/vector-only.
@freezed
abstract class MemoryPipelineSettings with _$MemoryPipelineSettings {
  const factory MemoryPipelineSettings({
    // ── Shared auxiliary LLM timeout ──────────────────────────────────────
    // Default timeout (ms) for auxiliary LLM calls when no service-specific
    // timeout is configured (postCleanerTimeoutMs, studioLedgerTimeoutMs).
    @Default(60000) int auxTimeoutMs,
  }) = _MemoryPipelineSettings;

  factory MemoryPipelineSettings.fromJson(Map<String, dynamic> json) =>
      _$MemoryPipelineSettingsFromJson(json);
}
