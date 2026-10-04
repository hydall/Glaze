import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/studio/agent_config_resolver.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/cleaner_settings.dart';
import 'package:glaze_flutter/core/models/ledger_settings.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_agent_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

/// Characterization tests for Studio model-override resolution.
///
/// After the dedup refactor, model overrides live ONLY in global
/// [PipelineSettings] (studioAgent / cleaner / ledger). The preset's
/// [StudioRuntimeSettings] no longer carries agents/cleaner/ledger.
/// [StudioTurnConfigSnapshot] passes [PipelineSettings] through without
/// replacing those blocks.
///
/// These tests pin that contract so a future regression (e.g. re-introducing
/// per-preset overrides that silently shadow global settings) is caught.
void main() {
  const activeApi = ApiConfig(
    id: 'active',
    endpoint: 'https://active.example',
    model: 'active-model',
  );
  const expensiveApi = ApiConfig(
    id: 'expensive',
    endpoint: 'https://expensive.example',
    model: 'expensive-model',
  );
  const cheapApi = ApiConfig(
    id: 'cheap',
    endpoint: 'https://cheap.example',
    model: 'cheap-model',
  );
  const cleanerApi = ApiConfig(
    id: 'cleaner',
    endpoint: 'https://cleaner.example',
    model: 'cleaner-model',
  );

  AgentConfigResolver buildResolver(PipelineSettings pipeline) {
    return AgentConfigResolver(
      loadApiConfigs: () async => const [activeApi, expensiveApi, cheapApi, cleanerApi],
      readActiveApiConfig: () => activeApi,
      readPipelineSettings: () => pipeline,
    );
  }

  group('final generator model override', () {
    test('uses studioFinalModelOverride when set', () async {
      final pipeline = const PipelineSettings(
        studioAgent: StudioAgentSettings(
          studioFinalModelOverride: 'kimi-hosted',
        ),
      );
      final resolver = buildResolver(pipeline);
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 's', enabled: true),
        preset: const StudioPreset(
          id: 'p',
          expensiveApiConfigId: 'expensive',
          agents: [
            StudioAgent(id: 'final', controllerId: 'final', order: 0, phase: 'final'),
          ],
        ),
        pipelineSettings: pipeline,
        apiConfigs: const [activeApi, expensiveApi, cheapApi, cleanerApi],
        activeApiConfig: activeApi,
      );

      final resolved = await resolver.resolveAgentConfig(
        const StudioAgent(id: 'final', controllerId: 'final', order: 0, phase: 'final'),
        activeApi,
        's',
        isFinalResponse: true,
        apiConfigId: snapshot.preset!.expensiveApiConfigId,
        turnConfig: snapshot,
      );

      expect(resolved.model, 'kimi-hosted');
      expect(resolved.endpoint, expensiveApi.endpoint);
    });

    test('falls back to slot config model when override is empty', () async {
      final pipeline = const PipelineSettings();
      final resolver = buildResolver(pipeline);
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 's', enabled: true),
        preset: const StudioPreset(
          id: 'p',
          expensiveApiConfigId: 'expensive',
          agents: [
            StudioAgent(id: 'final', controllerId: 'final', order: 0, phase: 'final'),
          ],
        ),
        pipelineSettings: pipeline,
        apiConfigs: const [activeApi, expensiveApi, cheapApi, cleanerApi],
        activeApiConfig: activeApi,
      );

      final resolved = await resolver.resolveAgentConfig(
        const StudioAgent(id: 'final', controllerId: 'final', order: 0, phase: 'final'),
        activeApi,
        's',
        isFinalResponse: true,
        apiConfigId: snapshot.preset!.expensiveApiConfigId,
        turnConfig: snapshot,
      );

      expect(resolved.model, expensiveApi.model);
    });

    test('falls back to active config when slot is empty', () async {
      final pipeline = const PipelineSettings();
      final resolver = buildResolver(pipeline);
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 's', enabled: true),
        preset: const StudioPreset(
          id: 'p',
          agents: [
            StudioAgent(id: 'final', controllerId: 'final', order: 0, phase: 'final'),
          ],
        ),
        pipelineSettings: pipeline,
        apiConfigs: const [activeApi, expensiveApi, cheapApi, cleanerApi],
        activeApiConfig: activeApi,
      );

      final resolved = await resolver.resolveAgentConfig(
        const StudioAgent(id: 'final', controllerId: 'final', order: 0, phase: 'final'),
        activeApi,
        's',
        isFinalResponse: true,
        apiConfigId: snapshot.preset!.expensiveApiConfigId,
        turnConfig: snapshot,
      );

      expect(resolved.model, activeApi.model);
      expect(resolved.endpoint, activeApi.endpoint);
    });
  });

  group('pre-gen controller model override', () {
    test('uses studioControllerModelOverride when set', () async {
      final pipeline = const PipelineSettings(
        studioAgent: StudioAgentSettings(
          studioControllerModelOverride: 'tracker-override',
        ),
      );
      final resolver = buildResolver(pipeline);
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 's', enabled: true),
        preset: const StudioPreset(
          id: 'p',
          cheapApiConfigId: 'cheap',
          agents: [
            StudioAgent(id: 'cont', controllerId: 'continuity', order: 0),
          ],
        ),
        pipelineSettings: pipeline,
        apiConfigs: const [activeApi, expensiveApi, cheapApi, cleanerApi],
        activeApiConfig: activeApi,
      );

      final resolved = await resolver.resolveAgentConfig(
        const StudioAgent(id: 'cont', controllerId: 'continuity', order: 0),
        activeApi,
        's',
        apiConfigId: snapshot.preset!.cheapApiConfigId,
        turnConfig: snapshot,
      );

      expect(resolved.model, 'tracker-override');
      expect(resolved.endpoint, cheapApi.endpoint);
    });

    test('falls back to slot config model when override is empty', () async {
      final pipeline = const PipelineSettings();
      final resolver = buildResolver(pipeline);
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 's', enabled: true),
        preset: const StudioPreset(
          id: 'p',
          cheapApiConfigId: 'cheap',
          agents: [
            StudioAgent(id: 'cont', controllerId: 'continuity', order: 0),
          ],
        ),
        pipelineSettings: pipeline,
        apiConfigs: const [activeApi, expensiveApi, cheapApi, cleanerApi],
        activeApiConfig: activeApi,
      );

      final resolved = await resolver.resolveAgentConfig(
        const StudioAgent(id: 'cont', controllerId: 'continuity', order: 0),
        activeApi,
        's',
        apiConfigId: snapshot.preset!.cheapApiConfigId,
        turnConfig: snapshot,
      );

      expect(resolved.model, cheapApi.model);
    });
  });

  group('post-processing model override', () {
    test('uses postCleanerModel for post_clean agents', () async {
      final pipeline = const PipelineSettings(
        cleaner: CleanerSettings(postCleanerModel: 'cleaner-override'),
      );
      final resolver = buildResolver(pipeline);
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 's', enabled: true),
        preset: const StudioPreset(
          id: 'p',
          cleanerApiConfigId: 'cleaner',
          agents: [
            StudioAgent(
              id: 'pc',
              controllerId: 'post_clean',
              order: 0,
              phase: 'post_processing',
            ),
          ],
        ),
        pipelineSettings: pipeline,
        apiConfigs: const [activeApi, expensiveApi, cheapApi, cleanerApi],
        activeApiConfig: activeApi,
      );

      final resolved = await resolver.resolveAgentConfig(
        const StudioAgent(
          id: 'pc',
          controllerId: 'post_clean',
          order: 0,
          phase: 'post_processing',
        ),
        activeApi,
        's',
        apiConfigId: snapshot.preset!.cleanerApiConfigId,
        turnConfig: snapshot,
      );

      expect(resolved.model, 'cleaner-override');
      expect(resolved.endpoint, cleanerApi.endpoint);
    });

    test('uses studioLedgerModel for ledger agents when set', () async {
      final pipeline = const PipelineSettings(
        ledger: LedgerSettings(studioLedgerModel: 'ledger-override'),
      );
      final resolver = buildResolver(pipeline);
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 's', enabled: true),
        preset: const StudioPreset(
          id: 'p',
          cleanerApiConfigId: 'cleaner',
          agents: [
            StudioAgent(
              id: 'led',
              controllerId: 'ledger',
              order: 0,
              phase: 'post_processing',
            ),
          ],
        ),
        pipelineSettings: pipeline,
        apiConfigs: const [activeApi, expensiveApi, cheapApi, cleanerApi],
        activeApiConfig: activeApi,
      );

      final resolved = await resolver.resolveAgentConfig(
        const StudioAgent(
          id: 'led',
          controllerId: 'ledger',
          order: 0,
          phase: 'post_processing',
        ),
        activeApi,
        's',
        apiConfigId: snapshot.preset!.cleanerApiConfigId,
        turnConfig: snapshot,
      );

      expect(resolved.model, 'ledger-override');
    });

    test('falls back to slot config model when override is empty', () async {
      final pipeline = const PipelineSettings();
      final resolver = buildResolver(pipeline);
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 's', enabled: true),
        preset: const StudioPreset(
          id: 'p',
          cleanerApiConfigId: 'cleaner',
          agents: [
            StudioAgent(
              id: 'pc',
              controllerId: 'post_clean',
              order: 0,
              phase: 'post_processing',
            ),
          ],
        ),
        pipelineSettings: pipeline,
        apiConfigs: const [activeApi, expensiveApi, cheapApi, cleanerApi],
        activeApiConfig: activeApi,
      );

      final resolved = await resolver.resolveAgentConfig(
        const StudioAgent(
          id: 'pc',
          controllerId: 'post_clean',
          order: 0,
          phase: 'post_processing',
        ),
        activeApi,
        's',
        apiConfigId: snapshot.preset!.cleanerApiConfigId,
        turnConfig: snapshot,
      );

      expect(resolved.model, cleanerApi.model);
    });
  });

  group('StudioTurnConfigSnapshot does not replace pipeline settings', () {
    test('global pipelineSettings passes through unchanged when Studio enabled', () {
      final pipeline = const PipelineSettings(
        studioAgent: StudioAgentSettings(
          studioFinalModelOverride: 'global-final',
        ),
        cleaner: CleanerSettings(postCleanerModel: 'global-cleaner'),
      );
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 's', enabled: true),
        preset: const StudioPreset(id: 'p'),
        pipelineSettings: pipeline,
        apiConfigs: const [],
        activeApiConfig: null,
      );

      expect(
        snapshot.pipelineSettings.studioAgent.studioFinalModelOverride,
        'global-final',
      );
      expect(
        snapshot.pipelineSettings.cleaner.postCleanerModel,
        'global-cleaner',
      );
    });

    test('global pipelineSettings passes through unchanged when Studio disabled', () {
      final pipeline = const PipelineSettings(
        studioAgent: StudioAgentSettings(
          studioControllerModelOverride: 'global-controller',
        ),
      );
      final snapshot = StudioTurnConfigSnapshot(
        config: null,
        preset: null,
        pipelineSettings: pipeline,
        apiConfigs: const [],
        activeApiConfig: null,
      );

      expect(
        snapshot.pipelineSettings.studioAgent.studioControllerModelOverride,
        'global-controller',
      );
    });
  });

  group('post_clean toggle disables cleaner stage', () {
    test('disabling post_clean agent forces postCleanerEnabled false', () {
      final pipeline = const PipelineSettings(
        cleaner: CleanerSettings(postCleanerEnabled: true),
      );
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 's', enabled: true),
        preset: const StudioPreset(
          id: 'p',
          agentEnabled: {'post_clean': false},
        ),
        pipelineSettings: pipeline,
        apiConfigs: const [],
        activeApiConfig: null,
      );

      expect(snapshot.pipelineSettings.cleaner.postCleanerEnabled, isFalse);
    });

    test('enabling post_clean preserves postCleanerEnabled', () {
      final pipeline = const PipelineSettings(
        cleaner: CleanerSettings(postCleanerEnabled: true),
      );
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 's', enabled: true),
        preset: const StudioPreset(
          id: 'p',
          agentEnabled: {'post_clean': true},
        ),
        pipelineSettings: pipeline,
        apiConfigs: const [],
        activeApiConfig: null,
      );

      expect(snapshot.pipelineSettings.cleaner.postCleanerEnabled, isTrue);
    });
  });
}
