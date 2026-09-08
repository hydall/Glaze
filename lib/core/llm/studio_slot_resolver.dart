import 'package:flutter/foundation.dart';

import '../models/api_config.dart';
import '../models/extra_request_parameter.dart';
import 'aux_llm_client.dart';
import 'transport/extra_request_parameters.dart';

/// Resolves a Studio API-config slot to an [AuxApiConfig] for auxiliary LLM
/// calls (cleaner, fact-checker, Ledger).
///
/// **Fail-explicit:** throws when [apiConfigId] is empty or not found in the
/// API config list. No silent fallback to the active chat config — Studio
/// slots must be configured deliberately.
///
/// Usage:
/// ```dart
/// await ref.read(apiListProvider.future);
/// final apiConfigs = ref.read(apiListProvider).value ?? const <ApiConfig>[];
/// final config = StudioSlotResolver.resolve(
///   apiConfigs: apiConfigs,
///   apiConfigId: studioConfig.cleanerApiConfigId,
///   errorLabel: 'post-cleaner',
///   modelOverride: pipeline.cleaner.postCleanerModel,
/// );
/// ```
class StudioSlotResolver {
  StudioSlotResolver._();

  /// Resolves [apiConfigId] to an [AuxApiConfig]. Throws if the id is empty
  /// or not found.
  ///
  /// [modelOverride] — when non-empty, replaces the config's model. Used for
  /// per-service model overrides (e.g. `postCleanerModel`,
  /// `studioLedgerModel`).
  static AuxApiConfig resolve({
    required List<ApiConfig> apiConfigs,
    required String apiConfigId,
    ApiConfig? fallback,
    String errorLabel = 'studio-slot',
    String modelOverride = '',
    List<ExtraRequestParameter> extraRequestParameterOverrides = const [],
    bool? useResponsesApi,
  }) {
    if (apiConfigId.isEmpty) {
      if (fallback != null) {
        final model = modelOverride.isNotEmpty ? modelOverride : fallback.model;
        debugPrint(
          '[StudioSlotResolver] $errorLabel: apiConfigId is empty — '
          'falling back to active chat API config (model=$model)',
        );
        return AuxApiConfig(
          endpoint: fallback.endpoint,
          apiKey: fallback.apiKey,
          model: model,
          protocol: fallback.protocol,
          useResponsesApi: useResponsesApi ?? fallback.useResponsesApi,
          extraRequestParameters: mergeExtraRequestParameters(
            fallback.extraRequestParameters,
            extraRequestParameterOverrides,
          ),
        );
      }
      debugPrint(
        '[StudioSlotResolver] $errorLabel: apiConfigId is empty and no '
        'fallback available — configure the Studio slot or set an active '
        'chat API config',
      );
      throw Exception(
        'Studio slot "$errorLabel" not configured: apiConfigId is empty and '
        'no active chat API config available as fallback',
      );
    }
    final selected = apiConfigs.where((c) => c.id == apiConfigId).firstOrNull;
    if (selected == null) {
      debugPrint(
        '[StudioSlotResolver] $errorLabel: apiConfigId "$apiConfigId" '
        'not found in API config list',
      );
      throw Exception(
        'Studio slot "$errorLabel" not found: apiConfigId "$apiConfigId" '
        'does not match any saved API config',
      );
    }
    final model = modelOverride.isNotEmpty ? modelOverride : selected.model;
    debugPrint(
      '[StudioSlotResolver] resolved $errorLabel '
      'model=$model endpoint=${selected.endpoint}',
    );
    return AuxApiConfig(
      endpoint: selected.endpoint,
      apiKey: selected.apiKey,
      model: model,
      protocol: selected.protocol,
      useResponsesApi: useResponsesApi ?? selected.useResponsesApi,
      extraRequestParameters: mergeExtraRequestParameters(
        selected.extraRequestParameters,
        extraRequestParameterOverrides,
      ),
    );
  }
}
