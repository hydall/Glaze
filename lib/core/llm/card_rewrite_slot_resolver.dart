import 'package:flutter/foundation.dart';

import '../models/api_config.dart';
import '../models/extra_request_parameter.dart';
import 'aux_llm_client.dart';
import 'transport/extra_request_parameters.dart';

/// Typed failure for the dedicated card-rewrite model slot: the slot id is
/// empty (not configured yet) or matches no saved API config. The writer lane
/// maps this to the durable job failure `rewriteModelNotConfigured`.
final class CardRewriteModelNotConfigured implements Exception {
  const CardRewriteModelNotConfigured(this.message);

  final String message;

  @override
  String toString() => 'CardRewriteModelNotConfigured: $message';
}

/// Resolves the DEDICATED card-rewrite API-config slot to an [AuxApiConfig]
/// for the manual rewrite writer lane (`ManualRewriteService`).
///
/// Follows [StudioSlotResolver]'s fail-explicitness with one hardened rule:
/// there is NO silent fallback to the active chat config. A card rewrite is
/// durable, user-visible canon, so its model must be configured deliberately;
/// an unconfigured or unmatched slot throws [CardRewriteModelNotConfigured]
/// and the caller must fail the job without making any transport call.
///
/// Usage:
/// ```dart
/// await ref.read(apiListProvider.future);
/// final apiConfigs = ref.read(apiListProvider).value ?? const <ApiConfig>[];
/// final config = CardRewriteSlotResolver.resolve(
///   apiConfigs: apiConfigs,
///   apiConfigId: rewriteApiConfigId,
///   modelOverride: rewriteModelOverride,
/// );
/// ```
class CardRewriteSlotResolver {
  CardRewriteSlotResolver._();

  static const String errorLabel = 'card-rewrite';

  /// Resolves [apiConfigId] to an [AuxApiConfig]. Throws
  /// [CardRewriteModelNotConfigured] when the slot id is empty or not found —
  /// never falls back to the active chat API config.
  ///
  /// [modelOverride] — when non-empty, replaces the slot config's model.
  static AuxApiConfig resolve({
    required List<ApiConfig> apiConfigs,
    required String apiConfigId,
    String modelOverride = '',
    List<ExtraRequestParameter> extraRequestParameterOverrides = const [],
    bool? useResponsesApi,
  }) {
    if (apiConfigId.isEmpty) {
      debugPrint(
        '[CardRewriteSlotResolver] $errorLabel: apiConfigId is empty — the '
        'rewrite model slot is not configured; failing explicitly (no chat '
        'config fallback)',
      );
      throw const CardRewriteModelNotConfigured(
        'Card rewrite model slot not configured: apiConfigId is empty',
      );
    }
    final selected = apiConfigs.where((c) => c.id == apiConfigId).firstOrNull;
    if (selected == null) {
      debugPrint(
        '[CardRewriteSlotResolver] $errorLabel: apiConfigId "$apiConfigId" '
        'not found in API config list; failing explicitly',
      );
      throw CardRewriteModelNotConfigured(
        'Card rewrite model slot not found: apiConfigId "$apiConfigId" does '
        'not match any saved API config',
      );
    }
    final model = modelOverride.isNotEmpty ? modelOverride : selected.model;
    debugPrint(
      '[CardRewriteSlotResolver] resolved $errorLabel '
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
