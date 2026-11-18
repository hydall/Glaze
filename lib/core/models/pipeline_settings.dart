import 'package:freezed_annotation/freezed_annotation.dart';

import 'card_rewriter_settings.dart';
import 'cleaner_settings.dart';
import 'ledger_settings.dart';
import 'memory_book_api_settings.dart';
import 'memory_pipeline_settings.dart';
import 'translation_settings.dart';
import 'agents_settings.dart';

part 'pipeline_settings.freezed.dart';
part 'pipeline_settings.g.dart';

/// Global generation-pipeline LLM settings, separated from [MemoryBookSettings].
///
/// Organized as six nested sub-models, each owning a logical group of fields:
/// - [cleaner] — POST-cleaner (anti-cliche rewrite + continuity/character
///   audit + prose-guardian style overrides).
/// - [ledger] — Tracker (Ledger) cadence, temperature, and token limits.
/// - [memoryPipeline] — shared auxiliary LLM fallback configuration.
/// - [memoryBookApi] — MemoryBook draft-generation LLM (model/endpoint/key).
/// - [cardRewriter] — review-only card-evolution enablement and dedicated LLM.
/// - [translation] — display-only message / composer translation connection.
/// - [agents] — the shared helper connection and limits of the agents.
///
/// Singleton global, persisted in SharedPreferences under the 'pipelineSettings'
/// key (see `pipeline_settings_provider.dart`). Previously per-session in the
/// `pipeline_settings_rows` Drift table; that table was dropped in schema v52
/// because pipeline settings are applied uniformly across all chats.
///
/// Previously a flat 80-field freezed class; refactored into nested sub-models
/// in Phase 2 of the Studio Pipeline Separation refactor. The provider
/// migration handles flat→nested JSON conversion idempotently.
@freezed
abstract class PipelineSettings with _$PipelineSettings {
  const factory PipelineSettings({
    @Default(CleanerSettings()) CleanerSettings cleaner,
    @Default(LedgerSettings()) LedgerSettings ledger,
    @Default(MemoryPipelineSettings()) MemoryPipelineSettings memoryPipeline,
    @Default(MemoryBookApiSettings()) MemoryBookApiSettings memoryBookApi,
    @Default(CardRewriterSettings()) CardRewriterSettings cardRewriter,
    @Default(TranslationSettings()) TranslationSettings translation,
    @Default(AgentsSettings()) AgentsSettings agents,
  }) = _PipelineSettings;

  factory PipelineSettings.fromJson(Map<String, dynamic> json) =>
      _$PipelineSettingsFromJson(json);
}
