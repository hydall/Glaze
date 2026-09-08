import '../../models/api_config.dart';
import '../../models/pipeline_settings.dart';
import '../../models/studio_config.dart';
import '../agent_runner.dart' show ResolvedAgentConfig;
import '../studio_api_config_resolver.dart';
import '../studio_turn_config_snapshot.dart';
import '../transport/extra_request_parameters.dart';

/// Resolves which API config an agent uses.
///
/// With the 3-slot model (v55):
/// - [apiConfigId] — if non-empty, overrides `runApiConfigId` from the
///   StudioConfig. Callers pass `cheapApiConfigId` for trackers,
///   `expensiveApiConfigId` for the final generator, `cleanerApiConfigId`
///   for post-processing agents. When empty, falls back to `runApiConfigId`
///   then to the active chat config.
/// - Model overrides are global PipelineSettings values configured from the
///   Studio menu: studioFinalModelOverride for the final generator,
///   postCleanerModel for post-processing trackers, studioTrackerModelOverride
///   for pre-gen trackers. The final generator intentionally does not read
///   PipelineSettings.memoryBookApi.generationModel because that field belongs
///   to MemoryBook draft generation.

class AgentConfigResolver {
  final Future<List<ApiConfig>> Function() _loadApiConfigs;
  final ApiConfig? Function() _readActiveApiConfig;
  final PipelineSettings Function() _readPipelineSettings;
  final Future<String> Function(String sessionId) _readRunApiConfigId;

  AgentConfigResolver({
    required this._loadApiConfigs,
    required this._readActiveApiConfig,
    required this._readPipelineSettings,
    required this._readRunApiConfigId,
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
    final runApiConfigId = (apiConfigId != null && apiConfigId.isNotEmpty)
        ? apiConfigId
        : turnConfig?.config?.runApiConfigId ??
              await _readRunApiConfigId(sessionId);
    final resolver = StudioApiConfigResolver(
      apiConfigs: apiConfigs,
      activeConfig: turnConfig?.activeApiConfig ?? _readActiveApiConfig(),
    );
    final pipeline = turnConfig?.pipelineSettings ?? _readPipelineSettings();
    if (isFinalResponse) {
      return resolver
          .resolveAgentConfig(
            current,
            runApiConfigId,
            pipeline.studioAgent.studioFinalModelOverride,
          )
          .copyWithSampling(
            topP: pipeline.studioAgent.studioFinalTopP,
            topK: pipeline.studioAgent.studioFinalTopK,
            frequencyPenalty: pipeline.studioAgent.studioFinalFrequencyPenalty,
            presencePenalty: pipeline.studioAgent.studioFinalPresencePenalty,
            omitTemperature: pipeline.studioAgent.studioFinalOmitTemperature,
            omitTopP: pipeline.studioAgent.studioFinalOmitTopP,
            extraRequestParameters: mergeExtraRequestParameters(
              resolver
                      .resolveRunConfig(runApiConfigId)
                      ?.extraRequestParameters ??
                  const [],
              pipeline.studioAgent.studioFinalExtraRequestParameters,
            ),
          );
    } else if (agent.phase == 'post_processing') {
      if (pipeline.cleaner.postCleanerModel.isNotEmpty) {
        return resolver
            .resolveAgentConfig(
              current,
              runApiConfigId,
              pipeline.cleaner.postCleanerModel,
            )
            .copyWithSampling(
              topP: pipeline.cleaner.postCleanerTopP,
              topK: pipeline.cleaner.postCleanerTopK,
              frequencyPenalty: pipeline.cleaner.postCleanerFrequencyPenalty,
              presencePenalty: pipeline.cleaner.postCleanerPresencePenalty,
              omitTemperature: pipeline.cleaner.postCleanerOmitTemperature,
              omitTopP: pipeline.cleaner.postCleanerOmitTopP,
              extraRequestParameters: mergeExtraRequestParameters(
                resolver
                        .resolveRunConfig(runApiConfigId)
                        ?.extraRequestParameters ??
                    const [],
                pipeline.cleaner.postCleanerExtraRequestParameters,
              ),
            );
      }
      return resolver
          .resolveAgentConfig(current, runApiConfigId, '')
          .copyWithSampling(
            topP: pipeline.cleaner.postCleanerTopP,
            topK: pipeline.cleaner.postCleanerTopK,
            frequencyPenalty: pipeline.cleaner.postCleanerFrequencyPenalty,
            presencePenalty: pipeline.cleaner.postCleanerPresencePenalty,
            omitTemperature: pipeline.cleaner.postCleanerOmitTemperature,
            omitTopP: pipeline.cleaner.postCleanerOmitTopP,
            extraRequestParameters: mergeExtraRequestParameters(
              resolver
                      .resolveRunConfig(runApiConfigId)
                      ?.extraRequestParameters ??
                  const [],
              pipeline.cleaner.postCleanerExtraRequestParameters,
            ),
          );
    } else if (pipeline.studioAgent.studioTrackerModelOverride.isNotEmpty) {
      return resolver
          .resolveAgentConfig(
            current,
            runApiConfigId,
            pipeline.studioAgent.studioTrackerModelOverride,
          )
          .copyWithSampling(
            topP: pipeline.studioAgent.studioTrackerTopP,
            topK: pipeline.studioAgent.studioTrackerTopK,
            frequencyPenalty:
                pipeline.studioAgent.studioTrackerFrequencyPenalty,
            presencePenalty: pipeline.studioAgent.studioTrackerPresencePenalty,
            omitTemperature: pipeline.studioAgent.studioTrackerOmitTemperature,
            omitTopP: pipeline.studioAgent.studioTrackerOmitTopP,
            extraRequestParameters: mergeExtraRequestParameters(
              resolver
                      .resolveRunConfig(runApiConfigId)
                      ?.extraRequestParameters ??
                  const [],
              pipeline.studioAgent.studioTrackerExtraRequestParameters,
            ),
          );
    }
    return resolver
        .resolveAgentConfig(current, runApiConfigId, '')
        .copyWithSampling(
          topP: pipeline.studioAgent.studioTrackerTopP,
          topK: pipeline.studioAgent.studioTrackerTopK,
          frequencyPenalty: pipeline.studioAgent.studioTrackerFrequencyPenalty,
          presencePenalty: pipeline.studioAgent.studioTrackerPresencePenalty,
          omitTemperature: pipeline.studioAgent.studioTrackerOmitTemperature,
          omitTopP: pipeline.studioAgent.studioTrackerOmitTopP,
          extraRequestParameters: mergeExtraRequestParameters(
            resolver.resolveRunConfig(runApiConfigId)?.extraRequestParameters ??
                const [],
            pipeline.studioAgent.studioTrackerExtraRequestParameters,
          ),
        );
  }
}
