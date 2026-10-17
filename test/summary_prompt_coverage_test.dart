import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/llm/prompt_inputs_collector.dart';
import 'package:glaze_flutter/core/llm/prompt_payload_builder.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/summary_block.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/summary_providers.dart';

/// Messages a live summary block covers are not sent: the block stands in for
/// them. Once a source changes, the block drops out and they come back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const messages = [
    ChatMessage(id: 'm1', role: 'user', content: 'Old one'),
    ChatMessage(id: 'm2', role: 'assistant', content: 'Old two'),
    ChatMessage(id: 'm3', role: 'user', content: 'Fresh'),
  ];
  const session = ChatSession(
    id: 's1',
    characterId: 'c1',
    sessionIndex: 0,
    messages: messages,
  );

  late ProviderContainer container;
  late PromptPayloadBuilder builder;
  late PromptInputsCollector collector;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);
    Future<void> initializeApiConfigs() async {}
    Future<List<ChatMessage>> injectHistory({
      required String sessionId,
      required List<ChatMessage> messages,
    }) async => messages;
    List<RuntimePromptBlock> readRuntimePromptBlocks(String _) => const [];
    final builderProvider = Provider((ref) {
      final inputs = PromptInputsCollector(
        ref,
        initializeApiConfigs: initializeApiConfigs,
        readActiveApiConfig: () => const ApiConfig(id: 'api'),
        injectHistory: injectHistory,
        readRuntimePromptBlocks: readRuntimePromptBlocks,
      );
      return (
        builder: PromptPayloadBuilder(
          ref,
          inputsCollector: inputs,
          initializeApiConfigs: initializeApiConfigs,
          readActiveApiConfig: () => null,
          injectHistory: injectHistory,
          readRuntimePromptBlocks: readRuntimePromptBlocks,
        ),
        collector: inputs,
      );
    });
    final built = container.read(builderProvider);
    builder = built.builder;
    collector = built.collector;
    await container
        .read(characterRepoProvider)
        .put(const Character(id: 'c1', name: 'Character'));
    await container.read(chatRepoProvider).put(session);
    const ids = ['m1', 'm2'];
    await container
        .read(summaryServiceProvider)
        .saveBlocks(
          sessionId: 's1',
          blocks: [
            SummaryBlock(
              id: 'b1',
              level: 1,
              content: 'They met.',
              messageIds: ids,
              sourceHash: SummaryChain.fingerprint(
                ids,
                SummaryChain.index(messages),
              ),
            ),
          ],
          messages: messages,
        );
  });

  Future<List<String>> generationHistory(ChatSession s) async {
    final inputs = await builder.collectGenerationContext(
      charId: 'c1',
      session: s,
      apiConfigOverride: const ApiConfig(id: 'api'),
      allowRemoteRetrieval: false,
    );
    return inputs.history.map((m) => m.id).toList();
  }

  test('covered messages are left out and the block is sent', () async {
    final inputs = await builder.collectGenerationContext(
      charId: 'c1',
      session: session,
      apiConfigOverride: const ApiConfig(id: 'api'),
      allowRemoteRetrieval: false,
    );
    expect(inputs.history.map((m) => m.id), ['m3']);
    expect(inputs.summaryContent, 'They met.');
  });

  test('the isolate path drops the same messages', () async {
    final inputs = await collector.collectInputs(
      charId: 'c1',
      session: session,
    );
    expect(inputs.history.map((m) => m.id), ['m3']);
    expect(inputs.summaryContent, 'They met.');
  });

  test('an edited source brings its messages back', () async {
    final edited = session.copyWith(
      messages: [
        messages[0].copyWith(content: 'Old one, edited'),
        messages[1],
        messages[2],
      ],
    );
    expect(await generationHistory(edited), ['m1', 'm2', 'm3']);
  });

  test('a switched-off summary leaves the history whole', () async {
    await container
        .read(summaryServiceProvider)
        .setSummaryEnabled(sessionId: 's1', enabled: false);
    expect(await generationHistory(session), ['m1', 'm2', 'm3']);
  });
}
