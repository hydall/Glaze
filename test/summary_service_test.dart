import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/summary_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/summary_service.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

/// Captures the aux call instead of hitting the network. Subclassing (rather
/// than stubbing Dio) is what keeps the protocol assertion meaningful: the
/// service is expected to hand its [AuxApiConfig] to [AuxLlmClient], which is
/// the layer that owns per-protocol URL/auth/body shape.
class _RecordingAuxLlmClient extends AuxLlmClient {
  static const response = '  generated summary  ';

  AuxApiConfig? config;
  String? prompt;
  int? maxTokens;
  double? temperature;
  int? timeoutMs;
  LlmCaptureContext? captureContext;

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
    this.prompt = prompt;
    this.maxTokens = maxTokens;
    this.temperature = temperature;
    this.timeoutMs = timeoutMs;
    this.captureContext = captureContext;
    return response;
  }
}

void main() {
  late AppDatabase db;
  late SummaryRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = SummaryRepo(db);
  });

  tearDown(() => db.close());

  test('reads defaults and persists trimmed manual summary state', () async {
    final service = SummaryService(repo);

    expect(await service.getSummary('session'), isNull);
    expect(await service.getSummaryContent('session'), isNull);
    expect(await service.isSummaryEnabled('session'), isTrue);
    expect(await service.getSummaryMessageCount('session'), 0);

    await service.setSummary(
      sessionId: 'session',
      content: '  manual summary  ',
      messageCount: 7,
    );
    expect(await service.getSummary('session'), 'manual summary');
    expect(await service.getSummaryMessageCount('session'), 7);

    await service.setSummaryEnabled(sessionId: 'session', enabled: false);
    expect(await service.getSummary('session'), isNull);
    expect(await service.getSummaryContent('session'), 'manual summary');
    expect(await service.isSummaryEnabled('session'), isFalse);

    await service.deleteSummary('session');
    expect(await service.getSummaryContent('session'), isNull);
  });

  test(
    'generates with filtered history and persists the trimmed response',
    () async {
      final llm = _RecordingAuxLlmClient();
      final service = SummaryService(repo, llm: llm);
      const history = [
        ChatMessage(id: '1', role: 'user', content: 'Hello'),
        ChatMessage(id: '2', role: 'system', content: 'Ignored'),
        ChatMessage(id: '3', role: 'assistant', content: 'Hi there'),
      ];

      final result = await service.generateSummary(
        sessionId: 'session',
        history: history,
        apiConfig: const ApiConfig(
          id: 'api',
          endpoint: 'https://example.com/v1',
          apiKey: 'secret',
          model: 'model',
        ),
        customPrompt: 'Context:\n{{history}}',
      );

      expect(result, 'generated summary');
      expect(llm.prompt, contains('User: Hello'));
      expect(llm.prompt, contains('Character: Hi there'));
      expect(llm.prompt, isNot(contains('Ignored')));
      expect(await service.getSummaryContent('session'), 'generated summary');
      expect(await service.getSummaryMessageCount('session'), history.length);
      expect((await repo.get('session'))?.prompt, 'Context:\n{{history}}');
      expect(llm.captureContext?.stage, 'summary');
      expect(llm.captureContext?.sessionId, 'session');
    },
  );

  test(
    'routes the call through the config protocol, not always OpenAI',
    () async {
      final llm = _RecordingAuxLlmClient();
      final service = SummaryService(repo, llm: llm);

      await service.generateSummary(
        sessionId: 'session',
        history: const [ChatMessage(id: '1', role: 'user', content: 'Hi')],
        apiConfig: const ApiConfig(
          id: 'api',
          endpoint: 'https://api.anthropic.com',
          apiKey: 'secret',
          model: 'claude-sonnet-4',
          protocol: LlmProtocol.anthropic,
          maxTokens: 4096,
          firstChunkTimeoutMs: 12000,
        ),
      );

      expect(llm.config?.protocol, LlmProtocol.anthropic);
      expect(llm.config?.endpoint, 'https://api.anthropic.com');
      expect(llm.config?.apiKey, 'secret');
      expect(llm.config?.model, 'claude-sonnet-4');
      expect(llm.maxTokens, 4096);
      expect(llm.timeoutMs, 12000);
    },
  );

  test('expands macros in the prompt but never in the transcript', () async {
    final llm = _RecordingAuxLlmClient();
    final service = SummaryService(repo, llm: llm);
    const template = 'Recap {{char}} for {{user}}.\n{{history}}\nDone.';

    await service.generateSummary(
      sessionId: 'session',
      history: const [
        // The transcript itself must stay untouched, macros and all.
        ChatMessage(id: '1', role: 'user', content: 'Say {{char}} out loud'),
      ],
      apiConfig: const ApiConfig(
        id: 'api',
        endpoint: 'https://example.com/v1',
        apiKey: 'secret',
        model: 'model',
      ),
      customPrompt: template,
      macroContext: const MacroContext(
        charName: 'Alice',
        userName: 'Bob',
        charId: 'char',
        sessionId: 'session',
      ),
    );

    expect(llm.prompt, startsWith('Recap Alice for Bob.'));
    expect(llm.prompt, contains('User: Say {{char}} out loud'));
    expect(llm.prompt, endsWith('Done.'));
    // The template is persisted unexpanded so it stays reusable.
    expect((await repo.get('session'))?.prompt, template);
  });

  test('falls back to the built-in prompt for a blank template', () async {
    final llm = _RecordingAuxLlmClient();
    final service = SummaryService(repo, llm: llm);

    await service.generateSummary(
      sessionId: 'session',
      history: const [ChatMessage(id: '1', role: 'user', content: 'Hi')],
      apiConfig: const ApiConfig(
        id: 'api',
        endpoint: 'https://example.com/v1',
        apiKey: 'secret',
        model: 'model',
      ),
      customPrompt: '   ',
    );

    expect(llm.prompt, startsWith(defaultSummaryPrompt));
    expect(llm.prompt, contains('User: Hi'));
  });

  test('ledger-stamped game time travels with the transcript', () async {
    final llm = _RecordingAuxLlmClient();
    final service = SummaryService(repo, llm: llm);

    await service.generateSummary(
      sessionId: 'session',
      history: const [
        ChatMessage(id: '1', role: 'user', content: 'Morning.'),
        ChatMessage(
          id: '2',
          role: 'assistant',
          content: 'She nods.',
          time: '12.05.2027 · RP_Day 0 · 09:15',
        ),
      ],
      apiConfig: const ApiConfig(
        id: 'api',
        endpoint: 'https://example.com/v1',
        apiKey: 'secret',
        model: 'model',
      ),
      customPrompt: 'Context:\n{{history}}',
    );

    expect(llm.prompt, contains('User: Morning.'));
    expect(llm.prompt, contains('[12.05.2027 · RP_Day 0 · 09:15] She nods.'));
  });

  test('accepts an OpenRouter config with no endpoint', () async {
    final llm = _RecordingAuxLlmClient();
    final service = SummaryService(repo, llm: llm);

    // OpenRouter's transport hardcodes its base URL, so configs legitimately
    // carry an empty endpoint. The old implementation rejected them.
    await service.generateSummary(
      sessionId: 'session',
      history: const [ChatMessage(id: '1', role: 'user', content: 'Hi')],
      apiConfig: const ApiConfig(
        id: 'api',
        apiKey: 'secret',
        model: 'anthropic/claude-sonnet-4',
        protocol: LlmProtocol.openrouter,
      ),
    );

    expect(llm.config?.protocol, LlmProtocol.openrouter);
    expect(await service.getSummaryContent('session'), 'generated summary');
  });

  test(
    'rejects incomplete API configuration before making a request',
    () async {
      final llm = _RecordingAuxLlmClient();
      final service = SummaryService(repo, llm: llm);

      await expectLater(
        service.generateSummary(
          sessionId: 'session',
          history: const [],
          apiConfig: const ApiConfig(id: 'api', model: 'model'),
        ),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        service.generateSummary(
          sessionId: 'session',
          history: const [],
          apiConfig: const ApiConfig(
            id: 'api',
            endpoint: 'https://example.com',
          ),
        ),
        throwsA(isA<Exception>()),
      );
      expect(llm.prompt, isNull);
    },
  );

  test('regeneration threshold behavior is unchanged', () {
    final service = SummaryService(repo);

    expect(service.needsRegeneration(5, null), isTrue);
    expect(service.needsRegeneration(10, 8), isFalse);
    expect(service.needsRegeneration(13, 10), isTrue);
  });
}
