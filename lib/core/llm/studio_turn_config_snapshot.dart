import '../models/api_config.dart';
import '../models/pipeline_settings.dart';
import '../models/studio_config.dart';
import 'aux_llm_client.dart';
import 'studio_slot_resolver.dart';

/// Immutable Studio configuration captured once for a chat generation turn.
class StudioTurnConfigSnapshot {
  final StudioConfig? config;
  final StudioPreset? preset;
  final PipelineSettings pipelineSettings;
  final List<ApiConfig> apiConfigs;
  final ApiConfig? activeApiConfig;

  const StudioTurnConfigSnapshot({
    required this.config,
    required this.preset,
    required this.pipelineSettings,
    required this.apiConfigs,
    required this.activeApiConfig,
  });

  bool get enabled => config != null && preset != null;

  AuxApiConfig resolveCleanerConfig({
    required String errorLabel,
    bool? useResponsesApi,
  }) {
    return StudioSlotResolver.resolve(
      apiConfigs: apiConfigs,
      apiConfigId: config?.cleanerApiConfigId ?? '',
      fallback: activeApiConfig,
      errorLabel: errorLabel,
      modelOverride: pipelineSettings.cleaner.postCleanerModel,
      extraRequestParameterOverrides:
          pipelineSettings.cleaner.postCleanerExtraRequestParameters,
      useResponsesApi: useResponsesApi,
    );
  }
}
