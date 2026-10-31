import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/context_calculator.dart';
import 'package:glaze_flutter/core/llm/summary_service.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/summary_block.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/summary_providers.dart';
import 'package:glaze_flutter/features/chat/services/summary_generation_service.dart';
import 'package:glaze_flutter/features/chat/state/cached_token_breakdown.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';

/// The automatic run brings the prompt back under the trigger: the raw tail
/// it leaves is what fits under the line next to the fixed part, not a share
/// of the window.
class _FakeLlmClient extends AuxLlmClient {
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
  }) async => 'summary';
}

// 4000 of context, 900 for the reply: the prompt may use 3100, and the
// default trigger (75 %) sits at 2325.
const _config = ApiConfig(
  id: 'chat',
  endpoint: 'https://chat.example.com/v1',
  apiKey: 'chat-key',
  model: 'chat-model',
  maxTokens: 900,
  contextSize: 4000,
);

const _messageCount = 40;

/// About 125 tokens each under the approximate count the tests run with.
final _session = ChatSession(
  id: 'session',
  characterId: 'char',
  sessionIndex: 0,
  messages: [
    for (var i = 0; i < _messageCount; i++)
      ChatMessage(
        id: 'm$i',
        role: i.isEven ? 'user' : 'assistant',
        content: 'Snow fell on the road all night. ' * 15,
      ),
  ],
);

/// A prompt build whose fixed part — preset, lorebooks, memory — came to
/// [fixed] tokens, with no history sent yet.
TokenBreakdown _breakdown(int fixed) => TokenBreakdown(
  sourceTokens: const {},
  staticTotal: fixed,
  fixedTotal: fixed,
  historyBudget: 3100 - fixed,
  historyTokens: 0,
  totalTokens: fixed,
  cutoffIndex: 0,
  trimmedHistory: const [],
);

Future<ProviderContainer> _container(int fixed) async {
  SharedPreferences.setMockInitialValues({});
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDbProvider.overrideWithValue(db),
      summaryServiceProvider.overrideWith(
        (ref) => SummaryService(
          ref.watch(summaryRepoProvider),
          llm: _FakeLlmClient(),
        ),
      ),
    ],
  );
  addTearDown(() async {
    container.dispose();
    await db.close();
  });
  await container.read(apiConfigRepoProvider).put(_config);
  container.invalidate(apiListProvider);
  await container.read(apiListProvider.future);
  container.read(activeApiPresetIdProvider.notifier).state = _config.id;
  container.read(cachedTokenBreakdownProvider('char').notifier).state =
      _breakdown(fixed);
  return container;
}

/// Tokens of history the run left as written.
Future<int> _rawTail(ProviderContainer container) async {
  final blocks = await container
      .read(summaryServiceProvider)
      .getBlocks(_session.id);
  final covered = SummaryChain.promptView(
    blocks,
    _session.messages,
  ).coveredMessageIds;
  var tokens = 0;
  for (final m in _session.messages) {
    if (!covered.contains(m.id)) tokens += estimateTokens(m.content);
  }
  return tokens;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final perMessage = estimateTokens(_session.messages.first.content);

  test('the tail is what fits under the trigger beside the fixed part', () {
    expect(
      SummaryGenerationService.autoTailBudget(
        total: 3100,
        triggerTokens: 2325,
        fixedTokens: 500,
        summaryTokens: 100,
      ),
      1725,
    );
    // The fixed part alone is past the trigger: the floor keeps the newest
    // exchanges raw rather than retelling up to the last message.
    expect(
      SummaryGenerationService.autoTailBudget(
        total: 3100,
        triggerTokens: 2325,
        fixedTokens: 2500,
        summaryTokens: 100,
      ),
      310,
    );
  });

  test('a run with a small fixed part leaves the room under the trigger', () async {
    final container = await _container(500);
    final result = await container
        .read(summaryGenerationServiceProvider)
        .compact(charId: 'char', session: _session);
    expect(result.created, greaterThan(0));

    // 2325 − 500 − the blocks written: well over the 775 the rest of the
    // window would have allowed.
    final tail = await _rawTail(container);
    expect(tail, lessThanOrEqualTo(2325 - 500));
    expect(tail, greaterThan(1200));
  });

  test('a fixed part near the trigger leaves only the floor', () async {
    final container = await _container(2100);
    await container
        .read(summaryGenerationServiceProvider)
        .compact(charId: 'char', session: _session);

    // 2325 − 2100 = 225 is under the floor of 310 (a tenth of 3100), so the
    // floor is the tail. The run stops once what lies outside it is less
    // than one block's worth (twice the block target), rather than write a
    // block for a message or two; it never keeps fewer messages than every
    // tail does.
    final tail = await _rawTail(container);
    final settings = await container.read(
      summaryCompactionSettingsProvider.future,
    );
    expect(
      tail,
      lessThan(310 + settings.blockTargetTokens * 2 + perMessage),
    );
    expect(
      tail,
      greaterThanOrEqualTo(SummaryChain.minTailMessages * perMessage),
    );
  });
}
