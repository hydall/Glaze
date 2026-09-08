import 'package:freezed_annotation/freezed_annotation.dart';

import 'cleaner_settings.dart';
import 'ledger_settings.dart';
import 'memory_book_api_settings.dart';
import 'memory_pipeline_settings.dart';
import 'studio_agent_settings.dart';

part 'pipeline_settings.freezed.dart';
part 'pipeline_settings.g.dart';

/// Global generation-pipeline LLM settings, separated from [MemoryBookSettings].
///
/// Organized as five nested sub-models, each owning a logical group of fields:
/// - [studioAgent] — Studio pre-gen trackers, final generator, post-processing
///   context sizes, and per-slot sampling/reasoning overrides.
/// - [cleaner] — POST-cleaner (anti-cliche rewrite + continuity/character
///   audit + prose-guardian style overrides).
/// - [ledger] — Studio Ledger cadence, temperature, and token limits.
/// - [memoryPipeline] — Memory dedup threshold, auxiliary LLM fallback config
///   (`aux*`), and consolidation LLM config.
/// - [memoryBookApi] — MemoryBook draft-generation LLM (model/endpoint/key).
///
/// Singleton global, persisted in SharedPreferences under the 'pipelineSettings'
/// key (see `pipeline_settings_provider.dart`). Previously per-session in the
/// `pipeline_settings_rows` Drift table; that table was dropped in schema v52
/// because pipeline settings are configured once via Build Studio and applied
/// uniformly across all chats.
///
/// Previously a flat 80-field freezed class; refactored into nested sub-models
/// in Phase 2 of the Studio Pipeline Separation refactor. The provider
/// migration handles flat→nested JSON conversion idempotently.
@freezed
abstract class PipelineSettings with _$PipelineSettings {
  const factory PipelineSettings({
    @Default(StudioAgentSettings()) StudioAgentSettings studioAgent,
    @Default(CleanerSettings()) CleanerSettings cleaner,
    @Default(LedgerSettings()) LedgerSettings ledger,
    @Default(MemoryPipelineSettings()) MemoryPipelineSettings memoryPipeline,
    @Default(MemoryBookApiSettings()) MemoryBookApiSettings memoryBookApi,
  }) = _PipelineSettings;

  factory PipelineSettings.fromJson(Map<String, dynamic> json) =>
      _$PipelineSettingsFromJson(json);
}
