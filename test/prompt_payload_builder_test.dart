import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/prompt_payload_builder.dart';
import 'package:glaze_flutter/core/llm/prompt_inputs_collector.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'buildFromPreFetched only loads graph prompt content when memory is enabled',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      addTearDown(db.close);
      var loadCount = 0;
      final builderProvider = Provider((ref) {
        Future<void> initializeApiConfigs() async {}
        Future<List<ChatMessage>> injectHistory({
          required String sessionId,
          required List<ChatMessage> messages,
        }) async => messages;
        List<RuntimePromptBlock> readRuntimePromptBlocks(String sessionId) =>
            const [];
        final inputsCollector = PromptInputsCollector(
          ref,
          initializeApiConfigs: initializeApiConfigs,
          readActiveApiConfig: () => null,
          injectHistory: injectHistory,
          readRuntimePromptBlocks: readRuntimePromptBlocks,
        );
        return PromptPayloadBuilder(
          ref,
          inputsCollector: inputsCollector,
          initializeApiConfigs: initializeApiConfigs,
          readActiveApiConfig: () => null,
          injectHistory: injectHistory,
          readRuntimePromptBlocks: readRuntimePromptBlocks,
          loadEffectiveLedgerTrackers: (sessionId) async {
            loadCount++;
            return [
              Tracker(
                sessionId: sessionId,
                name: 'world:weather',
                value: 'rain',
                scope: 'ledger',
              ),
              Tracker(
                sessionId: sessionId,
                name: 'arc:escape.status',
                value: 'active',
                scope: 'ledger',
              ),
              Tracker(
                sessionId: sessionId,
                name: 'arc:escape.title',
                value: 'Escape',
                scope: 'ledger',
              ),
            ];
          },
        );
      });
      final builder = container.read(builderProvider);

      for (final (mode, expectedArc) in [('balanced', true), ('fast', false)]) {
        await container
            .read(memoryGlobalSettingsProvider.notifier)
            .save(MemoryGlobalSettings(memoryMode: mode));
        final callsBeforeBuild = loadCount;

        final payload = await builder.buildFromPreFetched(
          charId: 'c1',
          session: const ChatSession(
            id: 's1',
            characterId: 'c1',
            sessionIndex: 0,
          ),
          character: const Character(id: 'c1', name: 'Character'),
          chatApi: const ApiConfig(id: 'api'),
          preset: null,
          persona: null,
          lorebooks: const [],
        );

        expect(loadCount - callsBeforeBuild, 1, reason: mode);
        expect(
          payload.studioSessionStateContent,
          contains('weather: rain'),
          reason: mode,
        );
        expect(payload.arcContent != null, expectedArc, reason: mode);
        if (expectedArc) {
          expect(payload.arcContent, contains('- Escape'));
        }
      }

      await container
          .read(memoryGlobalSettingsProvider.notifier)
          .save(const MemoryGlobalSettings(enabled: false));
      final callsBeforeGlobalDisable = loadCount;
      final globallyDisabledPayload = await builder.buildFromPreFetched(
        charId: 'c1',
        session: const ChatSession(
          id: 's1',
          characterId: 'c1',
          sessionIndex: 0,
        ),
        character: const Character(id: 'c1', name: 'Character'),
        chatApi: const ApiConfig(id: 'api'),
        preset: null,
        persona: null,
        lorebooks: const [],
      );

      expect(loadCount, callsBeforeGlobalDisable);
      expect(globallyDisabledPayload.studioSessionStateContent, isNull);
      expect(globallyDisabledPayload.arcContent, isNull);
      expect(globallyDisabledPayload.entitiesContent, isNull);

      await container
          .read(memoryGlobalSettingsProvider.notifier)
          .save(const MemoryGlobalSettings());
      await container.read(memoryBookRepoProvider).put(
        const MemoryBook(
          id: 'memorybook_s1',
          sessionId: 's1',
          settings: MemoryBookSettings(enabled: false),
        ),
      );
      final callsBeforeBookDisable = loadCount;
      final bookDisabledPayload = await builder.buildFromPreFetched(
        charId: 'c1',
        session: const ChatSession(
          id: 's1',
          characterId: 'c1',
          sessionIndex: 0,
        ),
        character: const Character(id: 'c1', name: 'Character'),
        chatApi: const ApiConfig(id: 'api'),
        preset: null,
        persona: null,
        lorebooks: const [],
      );

      expect(loadCount, callsBeforeBookDisable);
      expect(bookDisabledPayload.studioSessionStateContent, isNull);
      expect(bookDisabledPayload.arcContent, isNull);
      expect(bookDisabledPayload.entitiesContent, isNull);
    },
  );
}
