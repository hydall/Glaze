import '../../models/api_config.dart';
import '../../models/extra_request_parameter.dart';
import '../../models/pipeline_settings.dart';
import '../../models/studio_config.dart';
import '../agent_runner.dart' show ResolvedAgentConfig;
import '../studio_api_config_resolver.dart';
import '../studio_controller_ontology.dart';
import '../studio_turn_config_snapshot.dart';
import '../transport/extra_request_parameters.dart';

/// Resolves which API config an agent uses.
///
/// With the 3-slot model (v55):
/// - [apiConfigId] — the explicit Studio API slot. Callers pass
///   `cheapApiConfigId` for trackers,
///   `expensiveApiConfigId` for the final generator, `cleanerApiConfigId`
///   for post-processing agents. An empty slot uses the active chat config.
/// - Model overrides are global PipelineSettings values configured from the
///   Studio menu: studioFinalModelOverride for the final generator,
///   postCleanerModel for post-processing trackers, studioControllerModelOverride
///   for pre-gen trackers. The final generator intentionally does not read
///   PipelineSettings.memoryBookApi.generationModel because that field belongs
///   to MemoryBook draft generation.
///
/// Every sampling parameter is applied through [_SlotSampling], which resolves
/// each `<field>Override` flag to either the stored value or `null`. A `null`
/// reaches `copyWithSampling` untouched, so the selected API preset's own value
/// is what ends up in the request.

class AgentConfigResolver {
  final Future<List<ApiConfig>> Function() _loadApiConfigs;
  final ApiConfig? Function() _readActiveApiConfig;
  final PipelineSettings Function() _readPipelineSettings;

  AgentConfigResolver({
    required this._loadApiConfigs,
    required this._readActiveApiConfig,
    required this._readPipelineSettings,
  });

  Future<ResolvedAgentConfig> resolveAgentConfig(
    StudioAgent agent,
    ApiConfig current,
    String sessionId, {
    bool isFinalResponse = false,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
  }) async {
    final apiConfigs = turnConfig?.apiConfigs ?? await _loadApiConfigs();
    final selectedApiConfigId = apiConfigId ?? '';
    final resolver = StudioApiConfigResolver(
      apiConfigs: apiConfigs,
      activeConfig: turnConfig?.activeApiConfig ?? _readActiveApiConfig(),
    );
    final pipeline = turnConfig?.pipelineSettings ?? _readPipelineSettings();

    final String modelOverride;
    final _SlotSampling sampling;
    if (isFinalResponse) {
      modelOverride = pipeline.studioAgent.studioFinalModelOverride;
      sampling = _SlotSampling.finalGenerator(pipeline);
    } else if (agent.phase == 'post_processing') {
      // Post Clean and the Ledger share this phase but not their model: the
      // Ledger prefers its own override and only then the cleaner's.
      final ledgerModel = pipeline.ledger.studioLedgerModel;
      modelOverride =
          StudioControllerOntology.specForAgent(agent)?.id == 'ledger' &&
              ledgerModel.isNotEmpty
          ? ledgerModel
          : pipeline.cleaner.postCleanerModel;
      sampling = _SlotSampling.cleaner(pipeline);
    } else {
      modelOverride = pipeline.studioAgent.studioControllerModelOverride;
      sampling = _SlotSampling.controller(pipeline);
    }

    return resolver
        .resolveAgentConfig(current, selectedApiConfigId, modelOverride)
        .copyWithSampling(
          topP: sampling.topP,
          topK: sampling.topK,
          frequencyPenalty: sampling.frequencyPenalty,
          presencePenalty: sampling.presencePenalty,
          omitTemperature: sampling.omitTemperature,
          omitTopP: sampling.omitTopP,
          extraRequestParameters: mergeExtraRequestParameters(
            resolver
                    .resolveRunConfig(selectedApiConfigId)
                    ?.extraRequestParameters ??
                const [],
            sampling.extraRequestParameters,
          ),
        );
  }
}

/// One slot's sampling parameters, already reduced to "send this" (non-null) or
/// "leave the API preset's value alone" (null).
class _SlotSampling {
  final double? topP;
  final int? topK;
  final double? frequencyPenalty;
  final double? presencePenalty;
  final bool? omitTemperature;
  final bool? omitTopP;
  final List<ExtraRequestParameter> extraRequestParameters;

  const _SlotSampling({
    required this.topP,
    required this.topK,
    required this.frequencyPenalty,
    required this.presencePenalty,
    required this.omitTemperature,
    required this.omitTopP,
    required this.extraRequestParameters,
  });

  /// `omitTemperature` rides along with the temperature override, which is
  /// encoded as a sentinel (negative = not overridden) rather than a flag.
  factory _SlotSampling.finalGenerator(PipelineSettings pipeline) {
    final a = pipeline.studioAgent;
    return _SlotSampling(
      topP: a.studioFinalTopPOverride ? a.studioFinalTopP : null,
      topK: a.studioFinalTopKOverride ? a.studioFinalTopK : null,
      frequencyPenalty: a.studioFinalFrequencyPenaltyOverride
          ? a.studioFinalFrequencyPenalty
          : null,
      presencePenalty: a.studioFinalPresencePenaltyOverride
          ? a.studioFinalPresencePenalty
          : null,
      omitTemperature: a.studioFinalTemperature >= 0
          ? a.studioFinalOmitTemperature
          : null,
      omitTopP: a.studioFinalTopPOverride ? a.studioFinalOmitTopP : null,
      extraRequestParameters: a.studioFinalExtraRequestParameters,
    );
  }

  factory _SlotSampling.controller(PipelineSettings pipeline) {
    final a = pipeline.studioAgent;
    return _SlotSampling(
      topP: a.studioControllerTopPOverride ? a.studioControllerTopP : null,
      topK: a.studioControllerTopKOverride ? a.studioControllerTopK : null,
      frequencyPenalty: a.studioControllerFrequencyPenaltyOverride
          ? a.studioControllerFrequencyPenalty
          : null,
      presencePenalty: a.studioControllerPresencePenaltyOverride
          ? a.studioControllerPresencePenalty
          : null,
      omitTemperature: a.studioControllerTemperature >= 0
          ? a.studioControllerOmitTemperature
          : null,
      omitTopP: a.studioControllerTopPOverride
          ? a.studioControllerOmitTopP
          : null,
      extraRequestParameters: a.studioControllerExtraRequestParameters,
    );
  }

  factory _SlotSampling.cleaner(PipelineSettings pipeline) {
    final c = pipeline.cleaner;
    return _SlotSampling(
      topP: c.postCleanerTopPOverride ? c.postCleanerTopP : null,
      topK: c.postCleanerTopKOverride ? c.postCleanerTopK : null,
      frequencyPenalty: c.postCleanerFrequencyPenaltyOverride
          ? c.postCleanerFrequencyPenalty
          : null,
      presencePenalty: c.postCleanerPresencePenaltyOverride
          ? c.postCleanerPresencePenalty
          : null,
      omitTemperature: c.postCleanerTemperature >= 0
          ? c.postCleanerOmitTemperature
          : null,
      omitTopP: c.postCleanerTopPOverride ? c.postCleanerOmitTopP : null,
      extraRequestParameters: c.postCleanerExtraRequestParameters,
    );
  }
}
