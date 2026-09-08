import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/agent_runner.dart';
import 'package:glaze_flutter/core/llm/studio_slot_resolver.dart';
import 'package:glaze_flutter/core/llm/studio/agent_config_resolver.dart';
import 'package:glaze_flutter/core/llm/studio_api_config_resolver.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';
import 'package:glaze_flutter/core/models/memory_book_api_settings.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_agent_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/memory_agent_providers.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppDatabase _testDb() => AppDatabase.forTesting(NativeDatabase.memory());

void main() {
  group('StudioApiConfigResolver', () {
    test('resolveAgentConfig uses runApiConfigId when set', () {
      final active = ApiConfig(
        id: 'active',
        name: 'Active',
        endpoint: 'https://active',
        apiKey: 'key',
        model: 'gpt-4o',
        protocol: 'openai',
      );
      final cheap = ApiConfig(
        id: 'cheap-1',
        name: 'Cheap',
        endpoint: 'https://cheap',
        apiKey: 'key',
        model: 'gpt-4o-mini',
        protocol: 'openai',
      );
      final resolver = StudioApiConfigResolver(
        apiConfigs: [active, cheap],
        activeConfig: active,
      );

      final resolved = resolver.resolveAgentConfig(active, 'cheap-1', '');
      expect(resolved.model, 'gpt-4o-mini');
    });

    test('resolveAgentConfig falls back to active when id not found', () {
      final active = ApiConfig(
        id: 'active',
        name: 'Active',
        endpoint: 'https://active',
        apiKey: 'key',
        model: 'gpt-4o',
        protocol: 'openai',
      );
      final resolver = StudioApiConfigResolver(
        apiConfigs: [active],
        activeConfig: active,
      );

      final resolved = resolver.resolveAgentConfig(active, 'nonexistent', '');
      expect(resolved.model, 'gpt-4o');
    });

    test('resolveAgentConfig applies modelOverride', () {
      final active = ApiConfig(
        id: 'active',
        name: 'Active',
        endpoint: 'https://active',
        apiKey: 'key',
        model: 'gpt-4o',
        protocol: 'openai',
      );
      final resolver = StudioApiConfigResolver(
        apiConfigs: [active],
        activeConfig: active,
      );

      final resolved = resolver.resolveAgentConfig(active, '', 'custom-model');
      expect(resolved.model, 'custom-model');
    });

    test('resolveAgentConfig with empty runApiConfigId uses active', () {
      final active = ApiConfig(
        id: 'active',
        name: 'Active',
        endpoint: 'https://active',
        apiKey: 'key',
        model: 'gpt-4o',
        protocol: 'openai',
      );
      final resolver = StudioApiConfigResolver(
        apiConfigs: [active],
        activeConfig: active,
      );

      final resolved = resolver.resolveAgentConfig(active, '', '');
      expect(resolved.model, 'gpt-4o');
    });
  });

  group('StudioConfig 3-config fields', () {
    test('default values are empty strings', () {
      final config = StudioConfig(sessionId: 'test');
      expect(config.expensiveApiConfigId, '');
      expect(config.cheapApiConfigId, '');
      expect(config.cleanerApiConfigId, '');
      expect(config.finalPresetId, '');
    });

    test('copyWith updates config fields', () {
      final config = StudioConfig(sessionId: 'test');
      final updated = config.copyWith(
        expensiveApiConfigId: 'exp-1',
        cheapApiConfigId: 'cheap-1',
        cleanerApiConfigId: 'clean-1',
        finalPresetId: 'custom-preset',
      );
      expect(updated.expensiveApiConfigId, 'exp-1');
      expect(updated.cheapApiConfigId, 'cheap-1');
      expect(updated.cleanerApiConfigId, 'clean-1');
      expect(updated.finalPresetId, 'custom-preset');
    });

    test('StudioAgent has no promptShard/modelSource/model/modelOverride', () {
      final agent = StudioAgent(id: 'test', name: 'Test');
      expect(agent.id, 'test');
      expect(agent.enabled, true);
      // These fields were removed in v55 migration — if they still exist,
      // the freezed model wasn't regenerated.
    });
  });

  group('ResolvedAgentConfig', () {
    test('fromApiConfig preserves all fields', () {
      final api = ApiConfig(
        id: 'test',
        name: 'Test',
        endpoint: 'https://test',
        apiKey: 'key',
        model: 'model-1',
        protocol: 'openai',
        maxTokens: 8000,
        contextSize: 16000,
      );
      final resolved = ResolvedAgentConfig.fromApiConfig(api);
      expect(resolved.endpoint, 'https://test');
      expect(resolved.model, 'model-1');
      expect(resolved.apiKey, 'key');
      expect(resolved.protocol, 'openai');
    });

    test('fromApiConfig with modelOverride', () {
      final api = ApiConfig(
        id: 'test',
        name: 'Test',
        endpoint: 'https://test',
        apiKey: 'key',
        model: 'model-1',
        protocol: 'openai',
      );
      final resolved = ResolvedAgentConfig.fromApiConfig(
        api,
        modelOverride: 'override-model',
      );
      expect(resolved.model, 'override-model');
    });
  });

  group('Responses API routing', () {
    test('resolved agent config inherits the API preset toggle', () {
      final resolved = ResolvedAgentConfig.fromApiConfig(
        const ApiConfig(id: 'api', useResponsesApi: true),
      );

      expect(resolved.useResponsesApi, isTrue);
    });

    test('auxiliary Studio slot can override the API preset toggle', () {
      final resolved = StudioSlotResolver.resolve(
        apiConfigs: const [
          ApiConfig(
            id: 'api',
            endpoint: 'https://example.test/v1',
            apiKey: 'key',
            model: 'model',
            useResponsesApi: true,
          ),
        ],
        apiConfigId: 'api',
        useResponsesApi: false,
      );

      expect(resolved.useResponsesApi, isFalse);
    });
  });

  test('Studio slot parameters override API parameters by key', () async {
    const apiParameter = ExtraRequestParameter(
      key: 'reasoning_effort',
      value: 'high',
    );
    const studioParameter = ExtraRequestParameter(
      key: 'reasoning_effort',
      value: 'xhigh',
    );
    final api = ApiConfig(
      id: 'api',
      name: 'API',
      endpoint: 'https://example.test',
      apiKey: 'key',
      model: 'model',
      protocol: 'openai',
      extraRequestParameters: const [apiParameter],
    );
    final resolver = AgentConfigResolver(
      loadApiConfigs: () async => [api],
      readActiveApiConfig: () => api,
      readPipelineSettings: () => const PipelineSettings(
        studioAgent: StudioAgentSettings(
          studioFinalExtraRequestParameters: [studioParameter],
        ),
      ),
      readRunApiConfigId: (_) async => api.id,
    );

    final resolved = await resolver.resolveAgentConfig(
      const StudioAgent(id: 'final', name: 'Final'),
      api,
      'session',
      isFinalResponse: true,
    );

    expect(resolved.extraRequestParameters, const [studioParameter]);
  });

  group('AgentRunner Studio final routing', () {
    test('final timeout is not capped at 120 seconds', () {
      const settings = PipelineSettings(
        studioAgent: StudioAgentSettings(studioFinalTimeoutMs: 180000),
      );
      final runner = AgentRunner(
        configResolver: AgentConfigResolver(
          loadApiConfigs: () async => const [],
          readActiveApiConfig: () => null,
          readPipelineSettings: () => settings,
          readRunApiConfigId: (_) async => '',
        ),
        readPipelineSettings: () => settings,
      );

      expect(
        runner.effectiveTimeoutMs(
          const StudioAgent(id: 'final', name: 'Final'),
          true,
        ),
        180000,
      );
    });

    test(
      'final generator ignores MemoryBook generationModel override',
      () async {
        SharedPreferences.setMockInitialValues({});
        final db = _testDb();
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [appDbProvider.overrideWithValue(db)],
        );
        addTearDown(container.dispose);

        final active = ApiConfig(
          id: 'active',
          name: 'Active',
          endpoint: 'https://active',
          apiKey: 'key',
          model: 'chat-model',
          protocol: 'openai',
        );
        final expensive = ApiConfig(
          id: 'expensive',
          name: 'Expensive',
          endpoint: 'https://expensive',
          apiKey: 'key',
          model: 'final-slot-model',
          protocol: 'openai',
        );
        await container.read(apiConfigRepoProvider).put(active);
        await container.read(apiConfigRepoProvider).put(expensive);
        container.read(activeApiPresetIdProvider.notifier).state = active.id;
        container.invalidate(apiListProvider);
        await container.read(apiListProvider.future);
        await container
            .read(studioConfigRepoProvider)
            .upsert(
              StudioConfig(
                sessionId: 'session-1',
                enabled: true,
                expensiveApiConfigId: expensive.id,
              ),
            );
        await container
            .read(pipelineSettingsProvider.notifier)
            .save(
              const PipelineSettings(
                memoryBookApi: MemoryBookApiSettings(
                  generationModel: 'memory-book-model',
                ),
              ),
            );

        final resolved = await container
            .read(agentRunnerProvider)
            .resolveAgentConfig(
              const StudioAgent(id: 'final', name: 'Final'),
              active,
              'session-1',
              isFinalResponse: true,
              apiConfigId: expensive.id,
            );

        expect(resolved.model, 'final-slot-model');
      },
    );

    test(
      'final generator uses Studio final override instead of MemoryBook model',
      () async {
        SharedPreferences.setMockInitialValues({});
        final db = _testDb();
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [appDbProvider.overrideWithValue(db)],
        );
        addTearDown(container.dispose);

        final active = ApiConfig(
          id: 'active',
          name: 'Active',
          endpoint: 'https://active',
          apiKey: 'key',
          model: 'chat-model',
          protocol: 'openai',
        );
        final expensive = ApiConfig(
          id: 'expensive',
          name: 'Expensive',
          endpoint: 'https://expensive',
          apiKey: 'key',
          model: 'final-slot-model',
          protocol: 'openai',
        );
        await container.read(apiConfigRepoProvider).put(active);
        await container.read(apiConfigRepoProvider).put(expensive);
        container.read(activeApiPresetIdProvider.notifier).state = active.id;
        container.invalidate(apiListProvider);
        await container.read(apiListProvider.future);
        await container
            .read(studioConfigRepoProvider)
            .upsert(
              StudioConfig(
                sessionId: 'session-1',
                enabled: true,
                expensiveApiConfigId: expensive.id,
              ),
            );
        await container
            .read(pipelineSettingsProvider.notifier)
            .save(
              const PipelineSettings(
                memoryBookApi: MemoryBookApiSettings(
                  generationModel: 'memory-book-model',
                ),
                studioAgent: StudioAgentSettings(
                  studioFinalModelOverride: 'studio-final-model',
                ),
              ),
            );

        final resolved = await container
            .read(agentRunnerProvider)
            .resolveAgentConfig(
              const StudioAgent(id: 'final', name: 'Final'),
              active,
              'session-1',
              isFinalResponse: true,
              apiConfigId: expensive.id,
            );

        expect(resolved.model, 'studio-final-model');
      },
    );
  });
}
