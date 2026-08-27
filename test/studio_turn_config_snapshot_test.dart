import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/agent_runner.dart';
import 'package:glaze_flutter/core/llm/studio/agent_config_resolver.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/cleaner_settings.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';
import 'package:glaze_flutter/core/models/ledger_settings.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_agent_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_mode.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_policy.dart';
import 'package:glaze_flutter/core/state/active_studio_preset_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/studio_turn_config_resolver.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('snapshot freezes policy derived from unresolved preset blocks', () {
    final snapshot = StudioTurnConfigSnapshot(
      config: const StudioConfig(sessionId: 'session', enabled: true),
      preset: const StudioPreset(
        id: 'preset',
        blocks: [
          StudioPresetBlock(
            id: ledgerPromptInjectionHeaderId,
            title: ledgerPromptInjectionHeaderTitle,
            enabled: false,
          ),
        ],
      ),
      pipelineSettings: const PipelineSettings(),
      apiConfigs: const [],
      activeApiConfig: null,
    );

    expect(snapshot.ledgerPromptInjectionPolicy.presetOptIn, isFalse);
    expect(
      snapshot.ledgerPromptInjectionPolicy.effectiveMode,
      LedgerPromptInjectionMode.disabled,
    );
  });

  test(
    'resolver default-denies before loading enabled-only dependencies',
    () async {
      const settings = PipelineSettings(
        studioAgent: StudioAgentSettings(
          studioControllerModelOverride: 'captured-model',
        ),
      );
      const activeApi = ApiConfig(
        id: 'active',
        endpoint: 'https://active.example',
        model: 'active-model',
      );
      var apiLoads = 0;
      var presetLoads = 0;
      final resolver = StudioTurnConfigResolver(
        readPipelineSettings: () => settings,
        readStudioFeatureEnabled: () => false,
        loadApiConfigs: () async => apiLoads++,
        readApiConfigs: () => throw StateError('API list must not be read'),
        readActiveApiConfig: () => activeApi,
        loadActivePresetId: () async {
          presetLoads++;
          return 'selected';
        },
        loadPreset: (_) async => throw StateError('preset must not be loaded'),
        loadDefaultPreset: () async =>
            throw StateError('default preset must not be loaded'),
      );

      final snapshot = await resolver.resolve('session');

      expect(snapshot.enabled, isFalse);
      expect(snapshot.config, isNull);
      expect(snapshot.preset, isNull);
      expect(snapshot.pipelineSettings, settings);
      expect(snapshot.apiConfigs, isEmpty);
      expect(snapshot.activeApiConfig, activeApi);
      expect(apiLoads, 0);
      expect(presetLoads, 0);
    },
  );

  test(
    'resolver enables the selected preset for any session and falls back to default',
    () async {
      const api = ApiConfig(
        id: 'api',
        endpoint: 'https://api.example',
        model: 'model',
      );
      final sourceApis = <ApiConfig>[api];
      var apiLoaded = false;
      var defaultLoads = 0;
      final resolver = StudioTurnConfigResolver(
        readPipelineSettings: () => const PipelineSettings(),
        readStudioFeatureEnabled: () => true,
        loadApiConfigs: () async => apiLoaded = true,
        readApiConfigs: () {
          expect(apiLoaded, isTrue);
          return sourceApis;
        },
        readActiveApiConfig: () => api,
        loadActivePresetId: () async => 'missing',
        loadPreset: (_) async => null,
        loadDefaultPreset: () async {
          defaultLoads++;
          return const StudioPreset(
            id: 'default',
            agentEnabled: {'agency': false},
            agents: [
              StudioAgent(id: 'final', controllerId: 'final', order: 5),
              StudioAgent(id: 'agency', controllerId: 'agency', order: 1),
              StudioAgent(
                id: 'continuity',
                controllerId: 'continuity',
                order: 3,
              ),
            ],
          );
        },
      );

      final snapshot = await resolver.resolve('session');
      sourceApis.clear();

      expect(snapshot.preset?.id, 'default');
      expect(defaultLoads, 1);
      expect(snapshot.preset?.agents.map((agent) => agent.id), [
        'continuity',
        'final',
      ]);
      expect(snapshot.config?.sessionId, 'session');
      expect(snapshot.config?.enabled, isTrue);
      expect(snapshot.apiConfigs, [api]);
      expect(
        () => snapshot.apiConfigs.add(api),
        throwsUnsupportedError,
        reason: 'the turn must retain an immutable API-list snapshot',
      );
    },
  );

  test(
    'active preset change does not alter a captured turn snapshot',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      addTearDown(db.close);

      await container
          .read(studioFeatureEnabledProvider.notifier)
          .setEnabled(true);
      await container
          .read(studioPresetRepoProvider)
          .upsert(
            const StudioPreset(
              id: 'old-preset',
              cheapApiConfigId: 'old-api',
              cleanerApiConfigId: 'old-api',
              agents: [
                StudioAgent(
                  id: 'continuity',
                  controllerId: 'continuity',
                  name: 'Continuity',
                  order: 0,
                ),
                StudioAgent(
                  id: 'final',
                  controllerId: 'final',
                  name: 'Final',
                  order: 1,
                ),
              ],
              runtime: StudioRuntimeSettings(
                broadcastBlocks: ['preset broadcast'],
              ),
              blocks: [
                StudioPresetBlock(
                  id: 'old-ledger',
                  section: 'ledger',
                  content: 'old ledger instructions',
                ),
              ],
            ),
          );
      await container
          .read(studioPresetRepoProvider)
          .upsert(
            const StudioPreset(
              id: 'new-preset',
              cheapApiConfigId: 'new-api',
              cleanerApiConfigId: 'new-api',
              blocks: [
                StudioPresetBlock(
                  id: 'new-ledger',
                  section: 'ledger',
                  content: 'new ledger instructions',
                ),
              ],
            ),
          );
      await container
          .read(apiConfigRepoProvider)
          .put(
            const ApiConfig(
              id: 'old-api',
              endpoint: 'https://old.example',
              model: 'old-model',
            ),
          );
      await container
          .read(apiConfigRepoProvider)
          .put(
            const ApiConfig(
              id: 'new-api',
              endpoint: 'https://new.example',
              model: 'new-model',
            ),
          );
      container.invalidate(apiListProvider);
      await container.read(apiListProvider.future);
      await container
          .read(activeStudioPresetProvider.notifier)
          .set('old-preset');
      await container
          .read(pipelineSettingsProvider.notifier)
          .save(
            const PipelineSettings(
              studioAgent: StudioAgentSettings(
                studioControllerModelOverride: 'old-override',
              ),
            ),
          );

      final snapshot = await container
          .read(studioTurnConfigResolverProvider)
          .resolve('session');

      await container
          .read(activeStudioPresetProvider.notifier)
          .set('new-preset');
      await container
          .read(studioPresetRepoProvider)
          .upsert(
            snapshot.preset!.copyWith(
              cheapApiConfigId: 'new-api',
              cleanerApiConfigId: 'new-api',
            ),
          );
      await container
          .read(pipelineSettingsProvider.notifier)
          .save(
            const PipelineSettings(
              studioAgent: StudioAgentSettings(
                studioControllerModelOverride: 'new-override',
              ),
            ),
          );

      expect(snapshot.preset!.id, 'old-preset');
      expect(snapshot.preset!.blocks.single.content, 'old ledger instructions');
      expect(snapshot.preset!.cheapApiConfigId, 'old-api');
      expect(snapshot.preset!.runtime.broadcastBlocks, ['preset broadcast']);
      expect(
        snapshot.pipelineSettings.studioAgent.studioControllerModelOverride,
        'old-override',
      );
      final cleanerConfig = snapshot.resolveCleanerConfig(
        errorLabel: 'test-cleaner',
      );
      expect(cleanerConfig.endpoint, 'https://old.example/v1/chat/completions');
      expect(cleanerConfig.model, 'old-model');
    },
  );

  test('AgentRunner resolves downstream API identity from snapshot', () async {
    const oldApi = ApiConfig(
      id: 'old-api',
      endpoint: 'https://old.example',
      model: 'old-model',
    );
    const newApi = ApiConfig(
      id: 'new-api',
      endpoint: 'https://new.example',
      model: 'new-model',
    );
    var currentSettings = const PipelineSettings();
    var currentApis = const [newApi];
    final runner = AgentRunner(
      configResolver: AgentConfigResolver(
        loadApiConfigs: () async => currentApis,
        readActiveApiConfig: () => newApi,
        readPipelineSettings: () => currentSettings,
      ),
      readPipelineSettings: () => currentSettings,
    );
    final snapshot = StudioTurnConfigSnapshot(
      config: StudioConfig(sessionId: 'session', enabled: true),
      preset: const StudioPreset(id: 'old-preset', cheapApiConfigId: 'old-api'),
      pipelineSettings: PipelineSettings(
        studioAgent: StudioAgentSettings(
          studioControllerModelOverride: 'snapshot-model',
        ),
      ),
      apiConfigs: [oldApi],
      activeApiConfig: oldApi,
    );

    currentSettings = const PipelineSettings(
      studioAgent: StudioAgentSettings(
        studioControllerModelOverride: 'changed-model',
      ),
    );
    currentApis = const [newApi];
    final resolved = await runner.resolveAgentConfig(
      const StudioAgent(id: 'tracker', name: 'Tracker'),
      newApi,
      'session',
      apiConfigId: snapshot.preset!.cheapApiConfigId,
      turnConfig: snapshot,
    );

    expect(resolved.endpoint, oldApi.endpoint);
    expect(resolved.model, 'snapshot-model');
  });

  test('dedicated Ledger slot is not overridden by cleaner routing', () {
    const cleaner = ApiConfig(
      id: 'cleaner',
      endpoint: 'https://cleaner.example',
      model: 'cleaner-model',
    );
    const ledger = ApiConfig(
      id: 'ledger',
      endpoint: 'https://ledger.example',
      model: 'ledger-model',
    );
    final snapshot = StudioTurnConfigSnapshot(
      config: const StudioConfig(sessionId: 'session', enabled: true),
      preset: const StudioPreset(
        id: 'preset',
        cleanerApiConfigId: 'cleaner',
        ledgerApiConfigId: 'ledger',
      ),
      pipelineSettings: const PipelineSettings(),
      apiConfigs: const [cleaner, ledger],
      activeApiConfig: cleaner,
    );

    final resolved = snapshot.resolveLedgerConfig(errorLabel: 'test-ledger');
    expect(resolved.endpoint, ledger.endpoint);
    expect(resolved.model, ledger.model);
  });

  test('dedicated Ledger slot keeps its model and excludes cleaner extras', () {
    const cleanerExtra = ExtraRequestParameter(key: 'cleaner_only', value: '1');
    final snapshot = StudioTurnConfigSnapshot(
      config: const StudioConfig(sessionId: 'session', enabled: true),
      preset: const StudioPreset(
        id: 'preset',
        cleanerApiConfigId: 'cleaner',
        ledgerApiConfigId: 'ledger',
      ),
      pipelineSettings: const PipelineSettings(
        cleaner: CleanerSettings(
          postCleanerModel: 'cleaner-override',
          postCleanerExtraRequestParameters: [cleanerExtra],
        ),
      ),
      apiConfigs: const [
        ApiConfig(id: 'cleaner', model: 'cleaner-model'),
        ApiConfig(id: 'ledger', model: 'ledger-model'),
      ],
      activeApiConfig: null,
    );

    final resolved = snapshot.resolveLedgerConfig(errorLabel: 'ledger');
    expect(resolved.model, 'ledger-model');
    expect(resolved.extraRequestParameters, isEmpty);
  });

  test('Ledger model-only route uses cleaner slot without cleaner extras', () {
    final snapshot = StudioTurnConfigSnapshot(
      config: const StudioConfig(sessionId: 'session', enabled: true),
      preset: const StudioPreset(id: 'preset', cleanerApiConfigId: 'cleaner'),
      pipelineSettings: const PipelineSettings(
        cleaner: CleanerSettings(
          postCleanerModel: 'cleaner-override',
          postCleanerExtraRequestParameters: [
            ExtraRequestParameter(key: 'cleaner_only', value: '1'),
          ],
        ),
        ledger: LedgerSettings(studioLedgerModel: 'ledger-override'),
      ),
      apiConfigs: const [ApiConfig(id: 'cleaner', model: 'cleaner-model')],
      activeApiConfig: null,
    );

    final resolved = snapshot.resolveLedgerConfig(errorLabel: 'ledger');
    expect(resolved.model, 'ledger-override');
    expect(resolved.extraRequestParameters, isEmpty);
  });

  test(
    'resolver disables legacy agents whose phase mismatches their spec',
    () async {
      // Reproduces the "beauty" agent corruption: a retired pre-gen agent
      // whose controllerId was re-tagged to post_clean but still carries
      // phase=pre_generation. Without the phase-mismatch guard the resolver
      // maps it to the post_clean spec, sees agentEnabled['post_clean']==true,
      // and lets it run as a pre-generation controller.
      final resolver = StudioTurnConfigResolver(
        readPipelineSettings: () => const PipelineSettings(),
        readStudioFeatureEnabled: () => true,
        loadApiConfigs: () async {},
        readApiConfigs: () => const [],
        readActiveApiConfig: () => null,
        loadActivePresetId: () async => 'preset',
        loadPreset: (_) async => const StudioPreset(
          id: 'preset',
          agentEnabled: {
            'continuity': false,
            'agency': false,
            'dialogue': false,
            'guard': false,
            'world': false,
            'meta': false,
            'post_clean': true,
          },
          agents: [
            StudioAgent(
              id: 'agent_continuity',
              controllerId: 'continuity',
              order: 0,
              phase: 'pre_generation',
            ),
            StudioAgent(
              id: 'agent_beauty',
              controllerId: 'post_clean',
              order: 7,
              phase: 'pre_generation',
            ),
            StudioAgent(
              id: 'agent_final',
              controllerId: 'final',
              order: 8,
              phase: 'final',
            ),
          ],
        ),
        loadDefaultPreset: () async => null,
      );

      final snapshot = await resolver.resolve('session');

      final ids = snapshot.preset?.agents.map((a) => a.id).toList();
      expect(ids, isNot(contains('agent_beauty')));
      expect(ids, contains('agent_final'));
    },
  );

  test(
    'disabling the post_clean agent toggle also disables the cleaner stage',
    () {
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 'session', enabled: true),
        preset: const StudioPreset(
          id: 'preset',
          agentEnabled: {'post_clean': false},
        ),
        pipelineSettings: const PipelineSettings(
          cleaner: CleanerSettings(postCleanerEnabled: true),
        ),
        apiConfigs: const [],
        activeApiConfig: null,
      );

      expect(snapshot.pipelineSettings.cleaner.postCleanerEnabled, isFalse);
    },
  );

  test(
    'enabling the post_clean agent toggle preserves the cleaner runtime setting',
    () {
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 'session', enabled: true),
        preset: const StudioPreset(
          id: 'preset',
          agentEnabled: {'post_clean': true},
        ),
        pipelineSettings: const PipelineSettings(
          cleaner: CleanerSettings(postCleanerEnabled: true),
        ),
        apiConfigs: const [],
        activeApiConfig: null,
      );

      expect(snapshot.pipelineSettings.cleaner.postCleanerEnabled, isTrue);
    },
  );

  test(
    'post_clean agent toggle defaults to on when absent, preserving cleaner runtime',
    () {
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 'session', enabled: true),
        preset: const StudioPreset(id: 'preset'),
        pipelineSettings: const PipelineSettings(
          cleaner: CleanerSettings(postCleanerEnabled: true),
        ),
        apiConfigs: const [],
        activeApiConfig: null,
      );

      expect(snapshot.pipelineSettings.cleaner.postCleanerEnabled, isTrue);
    },
  );

  test('Ledger toggle is owned by the active Studio preset', () {
    StudioTurnConfigSnapshot snapshot(StudioPreset? preset) =>
        StudioTurnConfigSnapshot(
          config: preset == null
              ? null
              : const StudioConfig(sessionId: 'session', enabled: true),
          preset: preset,
          pipelineSettings: const PipelineSettings(),
          apiConfigs: const [],
          activeApiConfig: null,
        );

    expect(snapshot(const StudioPreset(id: 'default')).ledgerEnabled, isTrue);
    expect(
      snapshot(
        const StudioPreset(id: 'disabled', agentEnabled: {'ledger': false}),
      ).ledgerEnabled,
      isFalse,
    );
    expect(snapshot(null).ledgerEnabled, isFalse);
  });
}
