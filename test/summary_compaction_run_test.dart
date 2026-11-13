import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/summary_service.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/summary_block.dart'
    show SummaryBlock, SummaryChain, SummaryChainException;
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/summary_providers.dart';
import 'package:glaze_flutter/features/chat/services/summary_generation_service.dart';
import 'package:glaze_flutter/features/chat/state/summary_compaction_provider.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';

/// A manual compaction retells the whole backlog of a long chat in one run,
/// however many blocks that takes, and can be stopped between blocks.
class _CountingLlmClient extends AuxLlmClient {
  int calls = 0;

  /// Runs with the number of the request about to be answered.
  void Function(int call)? onCall;

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
    calls++;
    onCall?.call(calls);
    // As the real transport does: a cancelled request never answers.
    if (cancelToken?.isCancelled ?? false) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(),
        reason: 'cancelled',
      );
    }
    return 'summary';
  }
}

// A small window: the summarizer takes one message per request (its input
// cap bottoms out at 2000 tokens, below one of these messages), so every
// message outside the fresh tail is a block of its own.
const _config = ApiConfig(
  id: 'chat',
  endpoint: 'https://chat.example.com/v1',
  apiKey: 'chat-key',
  model: 'chat-model',
  maxTokens: 900,
  contextSize: 4000,
);

// Enough messages that the backlog needs more blocks than an automatic run
// may make.
const _messageCount = 24;

final _session = ChatSession(
  id: 'session',
  characterId: 'char',
  sessionIndex: 0,
  messages: [
    for (var i = 0; i < _messageCount; i++)
      ChatMessage(
        id: 'm$i',
        role: i.isEven ? 'user' : 'assistant',
        content: 'They walked on through the snow. ' * 500,
      ),
  ],
);

typedef _Harness = ({ProviderContainer container, _CountingLlmClient llm});

Future<_Harness> _harness() async {
  SharedPreferences.setMockInitialValues({});
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final llm = _CountingLlmClient();
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
  await container.read(apiConfigRepoProvider).put(_config);
  container.invalidate(apiListProvider);
  await container.read(apiListProvider.future);
  container.read(activeApiPresetIdProvider.notifier).state = _config.id;
  return (container: container, llm: llm);
}

Future<List<SummaryBlock>> _blocks(ProviderContainer container) =>
    container.read(summaryServiceProvider).getBlocks(_session.id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Everything but the manual tail: a quarter of the 4000-token context is
  // less than one of these messages, so the tail is the two newest messages
  // every tail keeps.
  final expectedBlocks = _messageCount - SummaryChain.minTailMessages;

  test(
    'a forced run retells the whole backlog, past the automatic cap',
    () async {
      final h = await _harness();
      final progress = <SummaryCompactionProgress>[];

      final result = await h.container
          .read(summaryGenerationServiceProvider)
          .compact(
            charId: 'char',
            session: _session,
            force: true,
            onProgress: progress.add,
          );

      expect(result.created, expectedBlocks);
      expect(h.llm.calls, expectedBlocks);
      expect((await _blocks(h.container)).length, expectedBlocks);
      // Reported before each request, counting down what is still ahead.
      expect(progress.length, expectedBlocks);
      expect(progress.first.sourceIds, ['m0']);
      expect(progress.first.remainingMessages, expectedBlocks - 1);
      expect(progress.last.remainingMessages, 0);
      expect(progress.map((p) => p.created), [
        for (var i = 0; i < expectedBlocks; i++) i,
      ]);
    },
  );

  test('a stop ends the run after the block under way', () async {
    final h = await _harness();
    final token = CancelToken();

    final result = await h.container
        .read(summaryGenerationServiceProvider)
        .compact(
          charId: 'char',
          session: _session,
          force: true,
          cancelToken: token,
          onProgress: (p) {
            if (p.created == 2) token.cancel();
          },
        );

    expect(result.created, 3);
    expect((await _blocks(h.container)).length, 3);
  });

  test('the notifier tracks the run and reports an empty one', () async {
    final h = await _harness();
    final notifier = h.container.read(summaryCompactionProvider.notifier);
    SummaryCompactionState state() =>
        h.container.read(summaryCompactionProvider);

    final run = notifier.compact(charId: 'char', session: _session);
    expect(state().isBusy(_session.id), isTrue);
    await run;
    expect(state().isBusy(_session.id), isFalse);
    expect(state().lastFailure, isNull);
    expect((await _blocks(h.container)).length, expectedBlocks);

    // Nothing left outside the tail: the reader hears so, as a failure.
    await notifier.compact(charId: 'char', session: _session);
    expect(state().isBusy(_session.id), isFalse);
    expect(
      state().lastFailure?.error,
      isA<SummaryChainException>().having(
        (e) => e.reason,
        'reason',
        'nothing_to_compact',
      ),
    );
  });

  test('cancel through the notifier keeps what was written', () async {
    final h = await _harness();
    final notifier = h.container.read(summaryCompactionProvider.notifier);
    SummaryCompactionState state() =>
        h.container.read(summaryCompactionProvider);

    // Stop while the first request is out: its block still lands, the run
    // shows as stopping until it has.
    var stoppingSeen = false;
    h.llm.onCall = (call) {
      if (call != 1) return;
      notifier.cancel(_session.id);
      stoppingSeen = state().run(_session.id)?.stopping ?? false;
    };
    await notifier.compact(charId: 'char', session: _session);

    expect(stoppingSeen, isTrue);
    expect(state().isBusy(_session.id), isFalse);
    expect(state().lastFailure, isNull);
    expect((await _blocks(h.container)).length, 1);
  });
}
