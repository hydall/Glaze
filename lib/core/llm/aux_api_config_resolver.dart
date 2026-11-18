import 'package:flutter/foundation.dart';

import '../models/api_config.dart';
import '../models/extra_request_parameter.dart';
import 'aux_llm_client.dart';
import 'transport/extra_request_parameters.dart';

/// Resolves the connection an auxiliary engine runs on (Post Clean, its
/// fact-checker, the Tracker, Card Rewriter) to an [AuxApiConfig].
///
/// An empty [apiConfigId] falls back to the active chat connection when one is
/// given; an id that matches no saved connection throws.
class AuxApiConfigResolver {
  AuxApiConfigResolver._();

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
    String errorLabel = 'aux-connection',
    String modelOverride = '',
    List<ExtraRequestParameter> extraRequestParameterOverrides = const [],
    bool? useResponsesApi,
  }) {
    if (apiConfigId.isEmpty) {
      if (fallback != null) {
        final model = modelOverride.isNotEmpty ? modelOverride : fallback.model;
        debugPrint(
          '[AuxApiConfigResolver] $errorLabel: apiConfigId is empty — '
          'falling back to active chat API config (model=$model)',
        );
        return AuxApiConfig(
          endpoint: fallback.endpoint,
          apiKey: fallback.apiKey,
          model: model,
          protocol: fallback.protocol,
          maxTokens: fallback.maxTokens,
          useResponsesApi: useResponsesApi ?? fallback.useResponsesApi,
          omitTemperature: fallback.omitTemperature,
          extraRequestParameters: mergeExtraRequestParameters(
            fallback.extraRequestParameters,
            extraRequestParameterOverrides,
          ),
        );
      }
      debugPrint(
        '[AuxApiConfigResolver] $errorLabel: apiConfigId is empty and no '
        'fallback available — pick a connection or set an active chat '
        'API config',
      );
      throw Exception(
        'Connection "$errorLabel" not configured: apiConfigId is empty and '
        'no active chat API config available as fallback',
      );
    }
    final selected = apiConfigs.where((c) => c.id == apiConfigId).firstOrNull;
    if (selected == null) {
      debugPrint(
        '[AuxApiConfigResolver] $errorLabel: apiConfigId "$apiConfigId" '
        'not found in API config list',
      );
      throw Exception(
        'Connection "$errorLabel" not found: apiConfigId "$apiConfigId" '
        'does not match any saved API config',
      );
    }
    final model = modelOverride.isNotEmpty ? modelOverride : selected.model;
    debugPrint(
      '[AuxApiConfigResolver] resolved $errorLabel '
      'model=$model endpoint=${selected.endpoint}',
    );
    return AuxApiConfig(
      endpoint: selected.endpoint,
      apiKey: selected.apiKey,
      model: model,
      protocol: selected.protocol,
      maxTokens: selected.maxTokens,
      useResponsesApi: useResponsesApi ?? selected.useResponsesApi,
      omitTemperature: selected.omitTemperature,
      extraRequestParameters: mergeExtraRequestParameters(
        selected.extraRequestParameters,
        extraRequestParameterOverrides,
      ),
    );
  }
}
