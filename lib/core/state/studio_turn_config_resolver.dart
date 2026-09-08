import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/api_list_provider.dart';
import '../llm/studio_activation_gate.dart';
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
  final Future<StudioConfig?> Function(String sessionId) loadStudioConfig;
  final Future<String> Function() loadActivePresetId;
  final Future<StudioPreset?> Function(String presetId) loadPreset;
  final Future<StudioPreset?> Function() loadDefaultPreset;

  const StudioTurnConfigResolver({
    required this.readPipelineSettings,
    required this.readStudioFeatureEnabled,
    required this.loadApiConfigs,
    required this.readApiConfigs,
    required this.readActiveApiConfig,
    required this.loadStudioConfig,
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

    StudioConfig? effectiveConfig;
    StudioPreset? preset;
    final storedConfig = await loadStudioConfig(sessionId);
    if (storedConfig?.enabled == true) {
      final presetId = await loadActivePresetId();
      preset = (await loadPreset(presetId)) ?? (await loadDefaultPreset());
      if (preset != null) {
        final agentEnabled = preset.agentEnabled;
        final beautyPipelineEnabled = preset.blocks.any(
          (block) => block.id == 'beauty_task' && block.enabled,
        );
        final agents = storedConfig!.agents.map((agent) {
          final specId = StudioControllerOntology.specForAgent(agent).id;
          final disableBeauty = specId == 'beauty' && !beautyPipelineEnabled;
          return agentEnabled[specId] == false || disableBeauty
              ? agent.copyWith(enabled: false)
              : agent;
        }).toList();
        final gated =
            StudioActivationGate.applyExecutionMode(
                agents,
                preset.executionMode,
              ).where((agent) => agent.enabled).toList()
              ..sort((a, b) => a.order.compareTo(b.order));
        if (gated.isNotEmpty) {
          effectiveConfig = storedConfig.copyWith(agents: gated);
        }
      }
    }

    return StudioTurnConfigSnapshot(
      config: effectiveConfig,
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
    loadStudioConfig: (sessionId) =>
        ref.read(studioConfigRepoProvider).getBySessionId(sessionId),
    loadActivePresetId: () => ref.read(activeStudioPresetProvider.future),
    loadPreset: (presetId) =>
        ref.read(studioPresetRepoProvider).getById(presetId),
    loadDefaultPreset: () => ref.read(studioPresetRepoProvider).getDefault(),
  );
});
