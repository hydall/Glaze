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
import 'package:glaze_flutter/core/models/summary_block.dart';

/// Captures the aux call instead of hitting the network. Subclassing (rather
/// than stubbing Dio) is what keeps the protocol assertion meaningful: the
/// service is expected to hand its [AuxApiConfig] to [AuxLlmClient], which is
/// the layer that owns per-protocol URL/auth/body shape.
class _RecordingAuxLlmClient extends AuxLlmClient {
  static const response = '  generated summary  ';

  /// Answers handed out in turn; [response] once they run out.
  final List<String> responses;

  _RecordingAuxLlmClient([this.responses = const []]);

  AuxApiConfig? config;
  final calls = <List<Map<String, String>>>[];
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
    calls.add(
      messages ??
          [
            {'role': 'user', 'content': prompt},
          ],
    );
    this.maxTokens = maxTokens;
    this.temperature = temperature;
    this.timeoutMs = timeoutMs;
    this.captureContext = captureContext;
    return calls.length <= responses.length
        ? responses[calls.length - 1]
        : response;
  }

  List<Map<String, String>>? get messages => calls.lastOrNull;

  String? _content(String role) =>
      messages?.where((m) => m['role'] == role).map((m) => m['content']).join();

  String? get system => _content('system');
  String? get user => _content('user');
}

const _api = ApiConfig(
  id: 'api',
  endpoint: 'https://example.com/v1',
  apiKey: 'secret',
  model: 'model',
);

void main() {
  late AppDatabase db;
  late SummaryRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = SummaryRepo(db);
  });

  tearDown(() => db.close());

  const messages = [
    ChatMessage(id: '1', role: 'user', content: 'Hello'),
    ChatMessage(id: '2', role: 'assistant', content: 'Hi there'),
    ChatMessage(id: '3', role: 'user', content: 'Fresh'),
  ];

  SummaryBlock block(List<String> ids, String content) => SummaryBlock(
    id: 'b-${ids.join()}',
    level: 1,
    content: content,
    messageIds: ids,
    sourceHash: SummaryChain.fingerprint(ids, SummaryChain.index(messages)),
    tokens: 3,
  );

  test('blocks round-trip and render into content', () async {
    final service = SummaryService(repo);
    expect(await service.getBlocks('session'), isEmpty);
    expect(await service.isSummaryEnabled('session'), isTrue);

    await service.saveBlocks(
      sessionId: 'session',
      blocks: [
        block(['1', '2'], 'They met.'),
      ],
      messages: messages,
    );

    expect((await service.getBlocks('session')).single.content, 'They met.');
    expect(await service.getSummary('session'), 'They met.');

    await service.setSummaryEnabled(sessionId: 'session', enabled: false);
    expect(await service.getSummary('session'), isNull);
    expect(await service.getPromptView('session', messages), isNull);
    // Switching off keeps the blocks.
    expect(await service.getBlocks('session'), hasLength(1));

    await service.deleteSummary('session');
    expect(await service.getBlocks('session'), isEmpty);
  });

  test('a summary from before blocks reads as one note', () async {
    final service = SummaryService(repo);
    await repo.put(sessionId: 'session', content: 'Old text', messageCount: 9);

    final blocks = await service.getBlocks('session');
    expect(blocks.single.isNote, isTrue);
    expect(blocks.single.content, 'Old text');

    // Sent, but standing in for no messages.
    final view = await service.getPromptView('session', messages);
    expect(view?.content, 'Old text');
    expect(view?.coveredMessageIds, isEmpty);
  });

  test('the prompt view covers live blocks only', () async {
    final service = SummaryService(repo);
    await service.saveBlocks(
      sessionId: 'session',
      blocks: [
        block(['1', '2'], 'They met.'),
      ],
      messages: messages,
    );

    final view = await service.getPromptView('session', messages);
    expect(view?.coveredMessageIds, {'1', '2'});

    // An edited source makes the block stale: not sent, messages come back.
    final edited = [
      messages[0],
      messages[1].copyWith(content: 'Hi there, edited'),
      messages[2],
    ];
    expect(await service.getPromptView('session', edited), isNull);
  });

  test('summarizes one run through the config protocol', () async {
    final llm = _RecordingAuxLlmClient();
    final service = SummaryService(repo, llm: llm);

    final result = await service.summarizeMessages(
      sessionId: 'session',
      source: const [
        ChatMessage(id: '1', role: 'user', content: 'Hello'),
        ChatMessage(id: '2', role: 'system', content: 'Ignored'),
        ChatMessage(id: '3', role: 'assistant', content: 'Hi there'),
      ],
      apiConfig: const ApiConfig(
        id: 'api',
        endpoint: 'https://api.anthropic.com',
        apiKey: 'secret',
        model: 'claude-sonnet-4',
        protocol: LlmProtocol.anthropic,
        maxTokens: 4096,
        firstChunkTimeoutMs: 12000,
        omitTemperature: true,
      ),
      targetTokens: 500,
      customPrompt: 'Context:\n{{history}}',
    );

    expect(result, 'generated summary');
    // Placed by the template, so it is sent as one user message.
    expect(llm.messages, hasLength(1));
    expect(llm.user, contains('User: Hello'));
    expect(llm.user, contains('Character: Hi there'));
    expect(llm.user, isNot(contains('Ignored')));
    expect(llm.config?.protocol, LlmProtocol.anthropic);
    expect(llm.config?.omitTemperature, isTrue);
    expect(llm.maxTokens, 4096);
    expect(llm.timeoutMs, 12000);
    expect(llm.temperature, kSummaryDefaultTemperature);
    expect(llm.captureContext?.stage, 'summary');
    // Nothing is persisted: the caller commits the block.
    expect(await service.getBlocks('session'), isEmpty);
  });

  test('expands macros in the prompt but never in the transcript', () async {
    final llm = _RecordingAuxLlmClient();
    final service = SummaryService(repo, llm: llm);

    await service.summarizeMessages(
      sessionId: 'session',
      source: const [
        ChatMessage(id: '1', role: 'user', content: 'Say {{char}} out loud'),
      ],
      apiConfig: _api,
      targetTokens: 300,
      customPrompt:
          'Recap {{char}} for {{user}} in {{target_tokens}}.\n'
          '{{history}}\nDone.',
      macroContext: const MacroContext(
        charName: 'Alice',
        userName: 'Bob',
        charId: 'char',
        sessionId: 'session',
      ),
    );

    expect(llm.user, startsWith('Recap Alice for Bob in 300.'));
    // Speakers go by their names; the transcript is never macro-expanded.
    expect(llm.user, contains('Bob: Say {{char}} out loud'));
    expect(llm.user, endsWith('Done.'));
    // Placed by the template, so no length hint is appended.
    expect(llm.user, isNot(contains(summaryLengthHint(300))));
  });

  test('the built-in prompt gets the length hint and the transcript', () async {
    final llm = _RecordingAuxLlmClient();
    final service = SummaryService(repo, llm: llm);

    await service.summarizeMessages(
      sessionId: 'session',
      source: const [
        ChatMessage(id: '1', role: 'user', content: 'Morning.'),
        ChatMessage(
          id: '2',
          role: 'assistant',
          content: 'She nods.',
          time: '12.05.2027 · RP_Day 0 · 09:15',
        ),
      ],
      apiConfig: _api,
      targetTokens: 400,
      customPrompt: '   ',
    );

    // Instructions in the system message, the material in the user one.
    expect(llm.messages?.map((m) => m['role']), ['system', 'user']);
    expect(llm.system, startsWith(defaultSummaryPrompt.trimRight()));
    expect(llm.system, contains(summaryLengthHint(400)));
    expect(llm.user, startsWith(summaryTranscriptHeader));
    // The Ledger clock stays out of the transcript.
    expect(llm.user, contains('Character: She nods.'));
    expect(llm.user, isNot(contains('RP_Day')));
  });

  test('earlier blocks are handed over as context, before the run', () async {
    final llm = _RecordingAuxLlmClient();
    final service = SummaryService(repo, llm: llm);

    await service.summarizeMessages(
      sessionId: 'session',
      source: const [ChatMessage(id: '1', role: 'user', content: 'Hello')],
      apiConfig: _api,
      targetTokens: 300,
      earlierSummary: 'They reached the pass after dark.',
    );

    expect(llm.system, isNot(contains(summaryPreviousHeader)));
    expect(llm.user, startsWith(summaryPreviousHeader));
    expect(
      llm.user!.indexOf('They reached the pass after dark.'),
      lessThan(llm.user!.indexOf('User: Hello')),
    );

    await service.summarizeMessages(
      sessionId: 'session',
      source: const [ChatMessage(id: '1', role: 'user', content: 'Hello')],
      apiConfig: _api,
      targetTokens: 300,
      customPrompt: 'So far: $summaryPreviousPlaceholder\n{{history}}',
      earlierSummary: 'They reached the pass.',
    );
    expect(llm.user, startsWith('So far: They reached the pass.'));
    expect(llm.user, isNot(contains(summaryPreviousHeader)));
  });

  test('a merge prompt lists the parts in order', () async {
    final llm = _RecordingAuxLlmClient();
    final service = SummaryService(repo, llm: llm);

    await service.mergeBlocks(
      sessionId: 'session',
      parts: [
        block(['1'], 'First part.'),
        block(['2'], 'Second part.'),
      ],
      apiConfig: _api,
      targetTokens: 200,
    );

    expect(llm.system, startsWith(summaryMergePrompt));
    expect(llm.system, contains(summaryLengthHint(200)));
    expect(
      llm.user!.indexOf('First part.'),
      lessThan(llm.user!.indexOf('Second part.')),
    );
  });

  test('a stored copy of the old built-in prompt counts as unset', () async {
    final service = SummaryService(repo);
    await service.setSummaryPrompt(
      sessionId: 'session',
      prompt:
          'Summarize the following part of a roleplay conversation concisely, '
          'in the language it is written in: key events in order, decisions, '
          'changes in relationships, and what is still unresolved. Keep '
          'proper names exactly as they appear.\n\n',
    );
    expect(await service.getSummaryPrompt('session'), isNull);

    await service.setSummaryPrompt(sessionId: 'session', prompt: 'Mine.');
    expect(await service.getSummaryPrompt('session'), 'Mine.');
  });

  test('a merge runs on the template it is given', () async {
    final llm = _RecordingAuxLlmClient();
    final service = SummaryService(repo, llm: llm);

    await service.mergeBlocks(
      sessionId: 'session',
      parts: [
        block(['1'], 'First part.'),
        block(['2'], 'Second part.'),
      ],
      apiConfig: _api,
      targetTokens: 200,
      template: 'Fold these into {{target_tokens}} tokens.',
    );

    expect(llm.system, 'Fold these into 200 tokens.');
    expect(llm.user, contains('First part.'));
  });

  test('a user message goes by the persona it was written as', () async {
    final llm = _RecordingAuxLlmClient();
    final service = SummaryService(repo, llm: llm);

    await service.summarizeMessages(
      sessionId: 'session',
      source: const [
        ChatMessage(id: '1', role: 'user', content: 'Hi', personaName: 'Eve'),
        ChatMessage(id: '2', role: 'user', content: 'Again'),
      ],
      apiConfig: _api,
      targetTokens: 300,
      macroContext: const MacroContext(
        charName: 'Alice',
        userName: 'Bob',
        charId: 'char',
        sessionId: 'session',
      ),
    );

    expect(llm.user, contains('Eve: Hi'));
    expect(llm.user, contains('Bob: Again'));
  });

  test('an answer well past its target is shortened once', () async {
    final long = List.filled(400, 'word').join(' ');
    final llm = _RecordingAuxLlmClient([long, 'Short.']);
    final service = SummaryService(repo, llm: llm);

    final result = await service.summarizeMessages(
      sessionId: 'session',
      source: const [ChatMessage(id: '1', role: 'user', content: 'Hello')],
      apiConfig: _api,
      targetTokens: 150,
    );

    expect(result, 'Short.');
    expect(llm.calls, hasLength(2));
    expect(llm.system, startsWith(summaryShortenPrompt));
    expect(llm.user, long);
  });

  test('a shortening that is no shorter keeps the first answer', () async {
    final long = List.filled(400, 'word').join(' ');
    final llm = _RecordingAuxLlmClient([long, '$long more']);
    final service = SummaryService(repo, llm: llm);

    final result = await service.mergeBlocks(
      sessionId: 'session',
      parts: [
        block(['1'], 'First part.'),
        block(['2'], 'Second part.'),
      ],
      apiConfig: _api,
      targetTokens: 150,
    );

    expect(result, long);
  });

  test('an answer within its target is not sent back', () async {
    final llm = _RecordingAuxLlmClient();
    final service = SummaryService(repo, llm: llm);

    await service.summarizeMessages(
      sessionId: 'session',
      source: const [ChatMessage(id: '1', role: 'user', content: 'Hello')],
      apiConfig: _api,
      targetTokens: 150,
    );

    expect(llm.calls, hasLength(1));
  });

  test('accepts an OpenRouter config with no endpoint', () async {
    final llm = _RecordingAuxLlmClient();
    final service = SummaryService(repo, llm: llm);

    await service.summarizeMessages(
      sessionId: 'session',
      source: const [ChatMessage(id: '1', role: 'user', content: 'Hi')],
      apiConfig: const ApiConfig(
        id: 'api',
        apiKey: 'secret',
        model: 'anthropic/claude-sonnet-4',
        protocol: LlmProtocol.openrouter,
      ),
      targetTokens: 200,
    );

    expect(llm.config?.protocol, LlmProtocol.openrouter);
  });

  test('rejects incomplete API configuration before a request', () async {
    final llm = _RecordingAuxLlmClient();
    final service = SummaryService(repo, llm: llm);

    for (final config in const [
      ApiConfig(id: 'api', model: 'model'),
      ApiConfig(id: 'api', endpoint: 'https://example.com'),
    ]) {
      await expectLater(
        service.summarizeMessages(
          sessionId: 'session',
          source: const <ChatMessage>[],
          apiConfig: config,
          targetTokens: 200,
        ),
        throwsA(isA<Exception>()),
      );
    }
    expect(llm.calls, isEmpty);
  });

  test('the prompt can be written without touching the blocks', () async {
    final service = SummaryService(repo);
    await service.saveBlocks(
      sessionId: 'session',
      blocks: [
        block(['1', '2'], 'kept'),
      ],
      messages: messages,
    );

    await service.setSummaryPrompt(
      sessionId: 'session',
      prompt: 'Recap {{char}}.',
    );

    expect(await service.getSummaryPrompt('session'), 'Recap {{char}}.');
    expect((await service.getBlocks('session')).single.content, 'kept');

    // A blank template means "use the built-in prompt", not an empty one.
    await service.setSummaryPrompt(sessionId: 'session', prompt: '   ');
    expect(await service.getSummaryPrompt('session'), isNull);
    expect((await service.getBlocks('session')).single.content, 'kept');
  });
}
