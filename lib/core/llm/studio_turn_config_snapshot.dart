import '../models/api_config.dart';
import '../models/pipeline_settings.dart';
import '../models/ledger_prompt_injection_mode.dart';
import '../models/ledger_prompt_injection_policy.dart';
import '../models/studio_config.dart';
import '../models/studio_pipeline_overrides.dart';
import 'aux_llm_client.dart';
import 'studio_slot_resolver.dart';

/// Immutable Studio configuration captured once for a chat generation turn.
class StudioTurnConfigSnapshot {
  final StudioConfig? config;
  final StudioPreset? preset;
  final PipelineSettings pipelineSettings;
  final List<ApiConfig> apiConfigs;
  final ApiConfig? activeApiConfig;
  final LedgerPromptInjectionPolicy ledgerPromptInjectionPolicy;

  StudioTurnConfigSnapshot({
    required this.config,
    required this.preset,
    required PipelineSettings pipelineSettings,
    required this.apiConfigs,
    required this.activeApiConfig,
    LedgerPromptInjectionPolicy? ledgerPromptInjectionPolicy,
  }) : ledgerPromptInjectionPolicy =
           ledgerPromptInjectionPolicy ??
           (preset == null
               ? const LedgerPromptInjectionPolicy(
                   presetOptIn: true,
                   mode: LedgerPromptInjectionMode.legacy,
                 )
               : deriveLedgerPromptInjectionPolicy(preset)),
       pipelineSettings = _resolvePipelineSettings(
         globals: pipelineSettings,
         config: config,
         preset: preset,
       );

  /// The settings this turn actually runs on: the preset's own Post Clean /
  /// Ledger / Card Rewriter settings folded over the globals, and then the
  /// preset's agent toggles folded over that.
  ///
  /// Order matters. The toggle is what the preset editor's switch writes, so it
  /// has to win over the lane's own `postCleanerEnabled` — otherwise turning
  /// Post Clean off in the pipeline list would be undone by the preset's stored
  /// cleaner settings.
  static PipelineSettings _resolvePipelineSettings({
    required PipelineSettings globals,
    required StudioConfig? config,
    required StudioPreset? preset,
  }) {
    final resolved = applyStudioPresetOverrides(globals, preset);
    if (config?.enabled != true || preset == null) return resolved;
    if (preset.agentEnabled['post_clean'] != false) return resolved;
    return resolved.copyWith(
      cleaner: resolved.cleaner.copyWith(postCleanerEnabled: false),
    );
  }

  bool get enabled => config != null && preset != null;

  bool get ledgerEnabled => enabled && preset!.agentEnabled['ledger'] != false;

  AuxApiConfig resolveCleanerConfig({
    required String errorLabel,
    bool? useResponsesApi,
  }) {
    return StudioSlotResolver.resolve(
      apiConfigs: apiConfigs,
      apiConfigId: preset?.cleanerApiConfigId ?? '',
      fallback: activeApiConfig,
      errorLabel: errorLabel,
      modelOverride: pipelineSettings.cleaner.postCleanerModel,
      extraRequestParameterOverrides:
          pipelineSettings.cleaner.postCleanerExtraRequestParameters,
      useResponsesApi: useResponsesApi,
    );
  }

  /// The Ledger's own API slot, falling back to the post-processing (cleaner)
  /// slot when neither the slot nor the model override is set — which is where
  /// the Ledger ran before it had a slot of its own, so an untouched install
  /// behaves exactly as before.
  AuxApiConfig resolveLedgerConfig({
    required String errorLabel,
    bool? useResponsesApi,
  }) {
    final slotId = preset?.ledgerApiConfigId ?? '';
    final model = pipelineSettings.ledger.studioLedgerModel;
    if (slotId.isEmpty && model.isEmpty) {
      return resolveCleanerConfig(
        errorLabel: errorLabel,
        useResponsesApi: useResponsesApi,
      );
    }
    return StudioSlotResolver.resolve(
      apiConfigs: apiConfigs,
      apiConfigId: slotId.isNotEmpty
          ? slotId
          : (preset?.cleanerApiConfigId ?? ''),
      fallback: activeApiConfig,
      errorLabel: errorLabel,
      // A configured Ledger route is independent from cleaner tuning. The
      // cleaner model/extra parameters are inherited only by the complete
      // legacy fallback above (neither a Ledger slot nor model is configured).
      modelOverride: model,
      extraRequestParameterOverrides: const [],
      useResponsesApi: useResponsesApi,
    );
  }
}
