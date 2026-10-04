import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/api_list_provider.dart';
import '../llm/studio_controller_ontology.dart';
import '../llm/studio_turn_config_snapshot.dart';
import '../models/api_config.dart';
import '../models/pipeline_settings.dart';
import '../models/studio_config.dart';
import 'active_studio_preset_provider.dart';
import 'db_provider.dart';

class StudioTurnConfigResolver {
  final PipelineSettings Function() readPipelineSettings;
  final bool Function() readStudioFeatureEnabled;
  final Future<void> Function() loadApiConfigs;
  final List<ApiConfig> Function() readApiConfigs;
  final ApiConfig? Function() readActiveApiConfig;
  final Future<String> Function() loadActivePresetId;
  final Future<StudioPreset?> Function(String presetId) loadPreset;
  final Future<StudioPreset?> Function() loadDefaultPreset;

  const StudioTurnConfigResolver({
    required this.readPipelineSettings,
    required this.readStudioFeatureEnabled,
    required this.loadApiConfigs,
    required this.readApiConfigs,
    required this.readActiveApiConfig,
    required this.loadActivePresetId,
    required this.loadPreset,
    required this.loadDefaultPreset,
  });

  Future<StudioTurnConfigSnapshot> resolve(String sessionId) async {
    final pipelineSettings = readPipelineSettings();
    if (!readStudioFeatureEnabled()) {
      return StudioTurnConfigSnapshot(
        config: null,
        preset: null,
        pipelineSettings: pipelineSettings,
        apiConfigs: const [],
        activeApiConfig: readActiveApiConfig(),
      );
    }

    await loadApiConfigs();
    final apiConfigs = List<ApiConfig>.unmodifiable(readApiConfigs());
    final activeApiConfig = readActiveApiConfig();

    StudioPreset? preset;
    final presetId = await loadActivePresetId();
    preset = (await loadPreset(presetId)) ?? (await loadDefaultPreset());
    if (preset != null) {
      final agentEnabled = preset.agentEnabled;
      final agents = preset.agents.map((agent) {
        final spec = StudioControllerOntology.specForAgent(agent);
        if (spec == null) return agent.copyWith(enabled: false);
        if (spec.isFinal) return agent.copyWith(enabled: true);
        // An agent whose stored phase doesn't match its resolved spec's
        // phase is a legacy mismap (e.g. a retired "beauty" agent re-tagged
        // to post_clean but still carrying phase=pre_generation). Disable
        // it rather than letting it run in the wrong lane.
        if (agent.phase != spec.phase) {
          return agent.copyWith(enabled: false);
        }
        return agentEnabled[spec.id] == false
            ? agent.copyWith(enabled: false)
            : agent;
      }).toList();
      final gated = agents.where((agent) => agent.enabled).toList()
        ..sort((a, b) => a.order.compareTo(b.order));
      if (gated.isNotEmpty) {
        preset = preset.copyWith(agents: gated);
      } else {
        // A preset without a runnable agent is not an active Studio turn.
        // Keep the old default-deny behavior for empty or corrupted presets.
        preset = null;
      }
    }

    return StudioTurnConfigSnapshot(
      // Studio is global once an agentic preset is selected. The config still
      // carries the session identity required by the execution pipeline, but
      // must not restore the retired per-chat enable switch.
      config: preset == null
          ? null
          : StudioConfig(sessionId: sessionId, enabled: true),
      preset: preset,
      pipelineSettings: pipelineSettings,
      apiConfigs: apiConfigs,
      activeApiConfig: activeApiConfig,
    );
  }
}

final studioTurnConfigResolverProvider = Provider<StudioTurnConfigResolver>((
  ref,
) {
  return StudioTurnConfigResolver(
    readPipelineSettings: () => ref.read(pipelineSettingsProvider),
    readStudioFeatureEnabled: () => ref.read(studioFeatureEnabledProvider),
    loadApiConfigs: () async {
      await ref.read(apiListProvider.future);
    },
    readApiConfigs: () =>
        ref.read(apiListProvider).value ?? const <ApiConfig>[],
    readActiveApiConfig: () => ref.read(activeApiConfigProvider),
    loadActivePresetId: () => ref.read(activeStudioPresetProvider.future),
    loadPreset: (presetId) =>
        ref.read(studioPresetRepoProvider).getById(presetId),
    loadDefaultPreset: () => ref.read(studioPresetRepoProvider).getDefault(),
  );
});
