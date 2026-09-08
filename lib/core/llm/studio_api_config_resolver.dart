import '../models/api_config.dart';
import 'agent_runner.dart' show ResolvedAgentConfig;

/// Single home for the studio/agent API-config resolution policies.
///
/// With the Studio unbound from user presets, per-agent model overrides are
/// gone. The 3 API Config slots (expensive/cheap/cleaner) on StudioConfig
/// replace them. This resolver maps a slot id to an [ApiConfig].
class StudioApiConfigResolver {
  final List<ApiConfig> apiConfigs;
  final ApiConfig? activeConfig;

  const StudioApiConfigResolver({required this.apiConfigs, this.activeConfig});

  /// Resolve the [ApiConfig] used to RUN trackers / agents: the studio's
  /// `runApiConfigId` if it resolves to a saved config, otherwise the active
  /// chat config. Returns `null` when neither is available.
  ApiConfig? resolveRunConfig(String runApiConfigId) {
    if (runApiConfigId.isNotEmpty) {
      final byRunId = apiConfigs
          .where((c) => c.id == runApiConfigId)
          .firstOrNull;
      if (byRunId != null) return byRunId;
    }
    return activeConfig;
  }

  /// Resolve an [ApiConfig] by its id from the saved list, falling back to
  /// the active chat config. Returns `null` when neither is available.
  ApiConfig? resolveById(String configId) {
    if (configId.isNotEmpty) {
      final match = apiConfigs.where((c) => c.id == configId).firstOrNull;
      if (match != null) return match;
    }
    return activeConfig;
  }

  /// Resolve a single agent's full [ResolvedAgentConfig] using the run API
  /// config + optional model override (from PipelineSettings, not per-agent).
  ResolvedAgentConfig resolveAgentConfig(
    ApiConfig current,
    String runApiConfigId,
    String modelOverride,
  ) {
    final active = resolveRunConfig(runApiConfigId) ?? current;
    return ResolvedAgentConfig.fromApiConfig(
      active,
      modelOverride: modelOverride,
    );
  }
}
