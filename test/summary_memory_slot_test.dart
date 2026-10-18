import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/summary_service.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book_api_settings.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/summary_providers.dart';
import 'package:glaze_flutter/features/chat/services/summary_generation_service.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';

/// Summarizing runs on the Memory slot — the connection memory drafts use —
/// rather than on whatever connection the chat happens to be pointed at.
class _RecordingAuxLlmClient extends AuxLlmClient {
  AuxApiConfig? config;
  double? temperature;
  int? maxTokens;

  @override
  Future<String> callOnce({
    required AuxApiConfig config,
    String prompt = '',
    List<Map<String, String>>? messages,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
    LlmCaptureContext? captureContext,
    AuxRawResponseSink? onRawResponse,
  }) async {
    this.config = config;
    this.temperature = temperature;
    this.maxTokens = maxTokens;
    return 'summary';
  }
}

const _chatConfig = ApiConfig(
  id: 'chat',
  endpoint: 'https://chat.example.com/v1',
  apiKey: 'chat-key',
  model: 'chat-model',
  maxTokens: 900,
);

const _memoryConfig = ApiConfig(
  id: 'memory',
  endpoint: 'https://api.anthropic.com',
  apiKey: 'memory-key',
  model: 'memory-model',
  protocol: LlmProtocol.anthropic,
  maxTokens: 4096,
);

const _session = ChatSession(
  id: 'session',
  characterId: 'char',
  sessionIndex: 0,
  messages: [ChatMessage(id: 'm1', role: 'user', content: 'Hello')],
);

typedef _Harness = ({ProviderContainer container, _RecordingAuxLlmClient llm});

Future<_Harness> _harness({MemoryBookApiSettings? slot}) async {
  SharedPreferences.setMockInitialValues({});
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final llm = _RecordingAuxLlmClient();
  final container = ProviderContainer(
    overrides: [
      appDbProvider.overrideWithValue(db),
      summaryServiceProvider.overrideWith(
        (ref) => SummaryService(ref.watch(summaryRepoProvider), llm: llm),
      ),
    ],
  );
  addTearDown(() async {
    container.dispose();
    await db.close();
  });

  final repo = container.read(apiConfigRepoProvider);
  await repo.put(_chatConfig);
  await repo.put(_memoryConfig);
  container.invalidate(apiListProvider);
  await container.read(apiListProvider.future);
  // The chat is pointed at its own connection; the Memory slot is what the
  // summary is expected to follow.
  container.read(activeApiPresetIdProvider.notifier).state = _chatConfig.id;

  if (slot != null) {
    final pipeline = container.read(pipelineSettingsProvider);
    await container
        .read(pipelineSettingsProvider.notifier)
        .save(pipeline.copyWith(memoryBookApi: slot));
  }
  return (container: container, llm: llm);
}

Future<void> _summarize(ProviderContainer container) => container
    .read(summaryGenerationServiceProvider)
    .generate(charId: 'char', session: _session);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the summary runs on the connection the Memory slot names', () async {
    final h = await _harness(
      slot: const MemoryBookApiSettings(apiConfigId: 'memory'),
    );

    await _summarize(h.container);

    // The repo normalizes a saved endpoint by appending the protocol's path,
    // so this asserts on the host it resolved to rather than the literal.
    expect(h.llm.config?.endpoint, startsWith(_memoryConfig.endpoint));
    expect(h.llm.config?.apiKey, _memoryConfig.apiKey);
    expect(h.llm.config?.model, _memoryConfig.model);
    // And through that connection's own chat protocol, not a hardcoded one.
    expect(h.llm.config?.protocol, LlmProtocol.anthropic);
  });

  test("the slot's model override wins over the connection's", () async {
    final h = await _harness(
      slot: const MemoryBookApiSettings(
        apiConfigId: 'memory',
        generationModel: 'haiku-cheap',
      ),
    );

    await _summarize(h.container);

    expect(h.llm.config?.model, 'haiku-cheap');
  });

  test('an unbound slot still falls back to the chat connection', () async {
    final h = await _harness();

    await _summarize(h.container);

    expect(h.llm.config?.endpoint, startsWith(_chatConfig.endpoint));
    expect(h.llm.config?.model, _chatConfig.model);
  });

  test('the output cap comes from the slot, then the connection', () async {
    final capped = await _harness(
      slot: const MemoryBookApiSettings(
        apiConfigId: 'memory',
        generationMaxTokens: 512,
      ),
    );
    await _summarize(capped.container);
    expect(capped.llm.maxTokens, 512);

    final inherited = await _harness(
      slot: const MemoryBookApiSettings(apiConfigId: 'memory'),
    );
    await _summarize(inherited.container);
    expect(inherited.llm.maxTokens, _memoryConfig.maxTokens);
  });

  test('temperature stays low unless the slot pins one', () async {
    final unset = await _harness(
      slot: const MemoryBookApiSettings(apiConfigId: 'memory'),
    );
    await _summarize(unset.container);
    expect(unset.llm.temperature, kSummaryDefaultTemperature);

    final pinned = await _harness(
      slot: const MemoryBookApiSettings(
        apiConfigId: 'memory',
        generationTemperature: 0.8,
      ),
    );
    await _summarize(pinned.container);
    expect(pinned.llm.temperature, 0.8);
  });

  test('a custom endpoint on the slot is used as it stands', () async {
    final h = await _harness(
      slot: const MemoryBookApiSettings(
        generationSource: 'custom',
        generationEndpoint: 'https://proxy.example.com/v1',
        generationApiKey: 'proxy-key',
        generationModel: 'proxy-model',
      ),
    );

    await _summarize(h.container);

    expect(h.llm.config?.endpoint, 'https://proxy.example.com/v1');
    expect(h.llm.config?.model, 'proxy-model');
    expect(h.llm.config?.protocol, LlmProtocol.customChatCompletion);
  });
}
