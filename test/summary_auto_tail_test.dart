import 'dart:convert';

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

/// About 125 tokens each under the approximate count the tests run with.
ChatSession _sessionOf(int count) => ChatSession(
  id: 'session',
  characterId: 'char',
  sessionIndex: 0,
  messages: [
    for (var i = 0; i < count; i++)
      ChatMessage(
        id: 'm$i',
        role: i.isEven ? 'user' : 'assistant',
        content: 'Snow fell on the road all night. ' * 15,
      ),
  ],
);

final _session = _sessionOf(40);

/// A prompt build whose fixed part — preset, lorebooks, memory — came to
/// [fixed] tokens, and whose history held [sent].
TokenBreakdown _breakdown(int fixed, {Set<String> sent = const {}}) =>
    TokenBreakdown(
      sourceTokens: const {},
      staticTotal: fixed,
      fixedTotal: fixed,
      historyBudget: 3100 - fixed,
      historyTokens: 0,
      totalTokens: fixed,
      cutoffIndex: 0,
      trimmedHistory: const [],
      visibleMessageIds: sent,
    );

Future<ProviderContainer> _container(
  int fixed, {
  Set<String> sent = const {},
  Map<String, Object>? settings,
}) async {
  SharedPreferences.setMockInitialValues({
    if (settings != null) 'summaryCompaction': jsonEncode(settings),
  });  final db = AppDatabase.forTesting(NativeDatabase.memory());
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
      _breakdown(fixed, sent: sent);
  return container;
}

/// Messages no block stands in for, oldest first.
Future<List<String>> _rawIds(
  ProviderContainer container, [
  ChatSession? session,
]) async {
  final chat = session ?? _session;
  final blocks = await container
      .read(summaryServiceProvider)
      .getBlocks(chat.id);
  final covered = SummaryChain.promptView(
    blocks,
    chat.messages,
  ).coveredMessageIds;
  return [
    for (final m in chat.messages)
      if (!covered.contains(m.id)) m.id,
  ];
}

/// Tokens of history the run left as written.
Future<int> _rawTail(ProviderContainer container) async {
  var tokens = 0;
  for (final id in await _rawIds(container)) {
    tokens += estimateTokens(
      _session.messages.firstWhere((m) => m.id == id).content,
    );
  }
  return tokens;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final perMessage = estimateTokens(_session.messages.first.content);

  test('the tail is what fits under the trigger beside the fixed part', () {
    expect(
      SummaryGenerationService.autoTailBudget(
        compactToTokens: 2325,
        floorTokens: 310,
        fixedTokens: 500,
        summaryTokens: 100,
      ),
      1725,
    );
    // The fixed part alone is past the trigger: the floor keeps the newest
    // exchanges raw rather than retelling up to the last message.
    expect(
      SummaryGenerationService.autoTailBudget(
        compactToTokens: 2325,
        floorTokens: 310,
        fixedTokens: 2500,
        summaryTokens: 100,
      ),
      310,
    );
  });

  test('the least raw history is a setting, a tenth by default', () {
    const d = SummaryCompactionSettings();
    expect(d.autoTailFloorUnit, SummaryManualTailUnit.percent);
    expect(d.autoTailFloor(100000), 10000);
    // Saved before the setting existed: the default.
    expect(SummaryCompactionSettings.fromJson(const {}), d);
    const tokens = SummaryCompactionSettings(
      autoTailFloorUnit: SummaryManualTailUnit.tokens,
      autoTailFloorTokens: 16000,
    );
    expect(tokens.autoTailFloor(100000), 16000);
    // Never past the line a run compacts to.
    expect(tokens.autoTailFloor(20000), 15000);
    expect(SummaryCompactionSettings.fromJson(tokens.toJson()), tokens);
  });

  test('the line a run compacts to never sits above the trigger', () {
    const settings = SummaryCompactionSettings(
      triggerPercent: 60,
      compactToPercent: 75,
    );
    expect(settings.compactToTokens(1000), 600);
    // Saved before the line existed: it is the trigger.
    expect(
      SummaryCompactionSettings.fromJson(const {
        'triggerPercent': 70,
      }).compactToPercent,
      70,
    );
    expect(
      SummaryCompactionSettings.fromJson(const {
        'triggerPercent': 70,
        'compactToPercent': 50,
      }).compactToPercent,
      50,
    );
  });

  test('a lower line frees room under the trigger for the chat to grow', () async {
    // Trigger 75 % (2325), compact to 50 % (1550): with a fixed part of
    // 500 the run leaves 1050 raw where compacting to the trigger left
    // 1825.
    final container = await _container(
      500,
      settings: {'autoEnabled': true, 'triggerPercent': 75, 'compactToPercent': 50},
    );
    await container
        .read(summaryGenerationServiceProvider)
        .compact(charId: 'char', session: _session);

    final tail = await _rawTail(container);
    expect(tail, lessThanOrEqualTo(1550 - 500));
    expect(tail, greaterThan(700));
  });

  test('what the trim dropped waits for a due run', () async {
    // Twelve messages, 1500 of history beside a fixed part of 500: 2000,
    // under the 2325 trigger. The last prompt sent only the newest six —
    // the trim dropped m0…m5 — but nothing runs until the fill asks for it.
    final session = _sessionOf(12);
    final container = await _container(
      500,
      sent: {for (var i = 6; i < 12; i++) 'm$i'},
    );
    final result = await container
        .read(summaryGenerationServiceProvider)
        .compact(charId: 'char', session: session);
    expect(result.created, 0);
  });

  test('a prompt that sent everything is left to the fill', () async {
    final session = _sessionOf(12);
    final container = await _container(
      500,
      sent: {for (var i = 0; i < 12; i++) 'm$i'},
    );
    final result = await container
        .read(summaryGenerationServiceProvider)
        .compact(charId: 'char', session: session);
    expect(result.created, 0);
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
