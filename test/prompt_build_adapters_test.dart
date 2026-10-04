import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/preset_repo.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/llm/prompt_inputs_collector.dart';
import 'package:glaze_flutter/core/llm/prompt_payload_builder.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/providers/prompt_build_providers.dart';
import 'package:glaze_flutter/features/extensions/services/runtime_prompt_injection_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'collector invokes adapters at collection time and uses fresh API',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      addTearDown(db.close);
      await container
          .read(characterRepoProvider)
          .put(const Character(id: 'c1', name: 'Character'));

      var api = const ApiConfig(id: 'first', contextSize: 4096);
      var initializationCount = 0;
      var historyInjectionCount = 0;
      var runtimeReadCount = 0;
      final collectorProvider = Provider(
        (ref) => PromptInputsCollector(
          ref,
          initializeApiConfigs: () async {
            initializationCount++;
          },
          readActiveApiConfig: () => api,
          injectHistory: ({required sessionId, required messages}) async {
            historyInjectionCount++;
            return [
              ...messages,
              const ChatMessage(
                id: 'ext',
                role: 'system',
                content: 'Extension',
              ),
            ];
          },
          readRuntimePromptBlocks: (sessionId) {
            runtimeReadCount++;
            return const [
              RuntimePromptBlock(
                id: 'runtime',
                content: 'Fresh runtime block',
                depth: 2,
                role: 'system',
              ),
            ];
          },
        ),
      );
      final collector = container.read(collectorProvider);
      const session = ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        messages: [ChatMessage(id: 'user', role: 'user', content: 'Hello')],
      );

      final first = await collector.collectInputs(
        charId: 'c1',
        session: session,
      );
      api = const ApiConfig(id: 'second', contextSize: 8192);
      final second = await collector.collectInputs(
        charId: 'c1',
        session: session,
      );

      expect(initializationCount, 2);
      expect(historyInjectionCount, 2);
      expect(runtimeReadCount, 2);
      expect(first.apiConfig.id, 'first');
      expect(second.apiConfig.id, 'second');
      expect(second.history.last.id, 'ext');
      expect(second.runtimePromptBlocks.single.id, 'runtime');
    },
  );

  test('runtime prompt adapter returns an immutable detached mapping', () {
    final source = <RuntimePromptInjection>[
      const RuntimePromptInjection(
        id: 'one',
        content: 'Content',
        depth: 3,
        role: 'assistant',
      ),
    ];

    final mapped = mapRuntimePromptBlocks(source);
    source.clear();

    expect(mapped.single.id, 'one');
    expect(mapped.single.content, 'Content');
    expect(mapped.single.depth, 3);
    expect(mapped.single.role, 'assistant');
    expect(() => mapped.add(mapped.single), throwsUnsupportedError);
  });

  test(
    'builder initializes APIs but an override bypasses the active read',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      addTearDown(db.close);
      await container
          .read(characterRepoProvider)
          .put(const Character(id: 'c1', name: 'Character'));

      var initializationCount = 0;
      var activeReadCount = 0;
      Future<void> initializeApiConfigs() async {
        initializationCount++;
      }

      ApiConfig? readActiveApiConfig() {
        activeReadCount++;
        return const ApiConfig(id: 'active');
      }

      Future<List<ChatMessage>> injectHistory({
        required String sessionId,
        required List<ChatMessage> messages,
      }) async => messages;

      final builderProvider = Provider((ref) {
        final collector = PromptInputsCollector(
          ref,
          initializeApiConfigs: initializeApiConfigs,
          readActiveApiConfig: readActiveApiConfig,
          injectHistory: injectHistory,
          readRuntimePromptBlocks: (_) => const [],
        );
        return PromptPayloadBuilder(
          ref,
          inputsCollector: collector,
          initializeApiConfigs: initializeApiConfigs,
          readActiveApiConfig: readActiveApiConfig,
          injectHistory: injectHistory,
          readRuntimePromptBlocks: (_) => const [],
        );
      });

      final payload = await container
          .read(builderProvider)
          .buildFromSession(
            charId: 'c1',
            session: null,
            apiConfigOverride: const ApiConfig(id: 'override'),
            skipVectorSearch: true,
          );

      expect(initializationCount, 1);
      expect(activeReadCount, 0);
      expect(payload.apiConfig.id, 'override');
    },
  );

  test('neutral collection never reads ordinary preset state', () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        presetRepoProvider.overrideWithValue(_ThrowingPresetRepo(db)),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);
    await container
        .read(characterRepoProvider)
        .put(const Character(id: 'c1', name: 'Character'));
    final builder = _builder(container);

    final inputs = await builder.collectGenerationContext(
      charId: 'c1',
      session: null,
      apiConfigOverride: const ApiConfig(id: 'api'),
      skipVectorSearch: true,
    );

    expect(inputs.character.id, 'c1');
    expect(inputs.apiConfig.id, 'api');
    await expectLater(
      builder.buildFromSession(
        charId: 'c1',
        session: null,
        apiConfigOverride: const ApiConfig(id: 'api'),
        skipVectorSearch: true,
      ),
      throwsStateError,
    );
  });

  test('ordinary adapter preserves live preset resolution semantics', () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);
    await container
        .read(characterRepoProvider)
        .put(const Character(id: 'c1', name: 'Character'));
    final repo = container.read(presetRepoProvider);
    await repo.put(const Preset(id: 'first', name: 'First'));
    await repo.put(const Preset(id: 'selected', name: 'Selected'));
    final firstId = (await repo.getAll()).first.id;
    final builder = _builder(container);

    Future<String?> resolve(String? activeId) async {
      container.read(activePresetIdProvider.notifier).state = activeId;
      final payload = await builder.buildFromSession(
        charId: 'c1',
        session: null,
        apiConfigOverride: const ApiConfig(id: 'api'),
        skipVectorSearch: true,
      );
      return payload.preset?.id;
    }

    expect(await resolve('selected'), 'selected');
    expect(await resolve(null), firstId);
    expect(await resolve('missing'), isNull);

    await repo.delete('first');
    await repo.delete('selected');
    expect(await resolve(null), isNull);
  });
}

PromptPayloadBuilder _builder(ProviderContainer container) {
  Future<void> initializeApiConfigs() async {}
  Future<List<ChatMessage>> injectHistory({
    required String sessionId,
    required List<ChatMessage> messages,
  }) async => messages;

  final provider = Provider((ref) {
    final collector = PromptInputsCollector(
      ref,
      initializeApiConfigs: initializeApiConfigs,
      readActiveApiConfig: () => null,
      injectHistory: injectHistory,
      readRuntimePromptBlocks: (_) => const [],
    );
    return PromptPayloadBuilder(
      ref,
      inputsCollector: collector,
      initializeApiConfigs: initializeApiConfigs,
      readActiveApiConfig: () => null,
      injectHistory: injectHistory,
      readRuntimePromptBlocks: (_) => const [],
    );
  });
  return container.read(provider);
}

class _ThrowingPresetRepo extends PresetRepo {
  _ThrowingPresetRepo(super.db);

  @override
  Future<List<Preset>> getAll() =>
      Future.error(StateError('ordinary preset state was read'));
}
