import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/summary_service.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/summary_block.dart';
import 'package:glaze_flutter/core/services/summary_preamble.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/summary_providers.dart';
import 'package:glaze_flutter/features/chat/services/summary_generation_service.dart';
import 'package:glaze_flutter/features/chat/state/summary_regeneration_provider.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';

/// Regenerating writes one block of the chain again as a draft that waits on
/// the block for approval, the way a Memory Books draft does. See
/// `docs/INVARIANTS.md` INV-S5.
class _RecordingAuxLlmClient extends AuxLlmClient {
  String answer = 'Fresh retelling.';
  final calls = <List<Map<String, String>>>[];

  /// When set, every call waits for it — a request still in flight.
  Completer<void>? gate;

  String? get system =>
      calls.lastOrNull?.firstWhere((m) => m['role'] == 'system')['content'];
  String? get user =>
      calls.lastOrNull?.lastWhere((m) => m['role'] == 'user')['content'];

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
    calls.add(messages ?? const []);
    await gate?.future;
    return answer;
  }
}

const _api = ApiConfig(
  id: 'chat',
  endpoint: 'https://chat.example.com/v1',
  apiKey: 'chat-key',
  model: 'chat-model',
  maxTokens: 900,
);

final _messages = [
  for (var i = 0; i < 4; i++)
    ChatMessage(
      id: 'm$i',
      role: i.isEven ? 'user' : 'assistant',
      content: 'Message $i. ${'They walked on through the snow. ' * 40}',
    ),
];

final _edited = [
  _messages[0].copyWith(content: 'Edited. ${_messages[0].content}'),
  ..._messages.skip(1),
];

ChatSession _session([List<ChatMessage>? messages]) => ChatSession(
  id: 'session',
  characterId: 'char',
  sessionIndex: 0,
  messages: messages ?? _messages,
);

SummaryBlock _block(
  String id,
  List<String> ids, {
  int level = 1,
  String? content,
  List<String> childIds = const [],
  bool archived = false,
  SummaryDraft? draft,
}) => SummaryBlock(
  id: id,
  level: level,
  content: content ?? 'Old text of $id.',
  messageIds: ids,
  sourceHash: SummaryChain.fingerprint(ids, SummaryChain.index(_messages)),
  childIds: childIds,
  archived: archived,
  tokens: 5,
  sourceTokens: 400,
  createdAt: 7,
  draft: draft,
);

SummaryDraft _draft(List<String> ids, {String content = 'Draft text.'}) =>
    SummaryDraft(
      content: content,
      messageIds: ids,
      sourceHash: SummaryChain.fingerprint(ids, SummaryChain.index(_messages)),
      tokens: 3,
      sourceTokens: 400,
    );

typedef _Harness = ({ProviderContainer container, _RecordingAuxLlmClient llm});

Future<_Harness> _harness(List<SummaryBlock> blocks) async {
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
  await container.read(apiConfigRepoProvider).put(_api);
  container.invalidate(apiListProvider);
  await container.read(apiListProvider.future);
  container.read(activeApiPresetIdProvider.notifier).state = _api.id;
  await container
      .read(summaryServiceProvider)
      .saveBlocks(sessionId: 'session', blocks: blocks, messages: _messages);
  return (container: container, llm: llm);
}

SummaryGenerationService _generator(ProviderContainer container) =>
    container.read(summaryGenerationServiceProvider);

Future<void> _regenerate(
  ProviderContainer container,
  String blockId, [
  List<ChatMessage>? messages,
]) => _generator(container).regenerateBlock(
  charId: 'char',
  session: _session(messages),
  blockId: blockId,
);

Future<void> _approve(
  ProviderContainer container,
  String blockId, [
  List<ChatMessage>? messages,
]) => _generator(
  container,
).approveDraft(session: _session(messages), blockId: blockId);

Future<List<SummaryBlock>> _blocks(ProviderContainer container) =>
    container.read(summaryServiceProvider).getBlocks('session');

Future<SummaryBlock> _one(ProviderContainer container, String id) async =>
    (await _blocks(container)).firstWhere((b) => b.id == id);

Matcher _reason(String reason) => throwsA(
  isA<SummaryChainException>().having((e) => e.reason, 'reason', reason),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a block is written again as a draft, and keeps its text', () async {
    final h = await _harness([
      _block('b1', ['m0', 'm1']),
      _block('b2', ['m2', 'm3']),
    ]);

    await _regenerate(h.container, 'b1');

    final b1 = await _one(h.container, 'b1');
    expect(b1.content, 'Old text of b1.');
    expect(b1.draft?.content, 'Fresh retelling.');
    expect(b1.draft?.messageIds, ['m0', 'm1']);
    expect((await _one(h.container, 'b2')).draft, isNull);
    expect(h.llm.user, contains('Message 0.'));
    expect(h.llm.user, isNot(contains('Message 2.')));
    // A draft is never sent: the prompt still carries the old text.
    final view = await h.container
        .read(summaryServiceProvider)
        .getPromptView('session', _messages);
    expect(view?.content, contains('Old text of b1.'));
    expect(view?.content, isNot(contains('Fresh retelling.')));
  });

  test('approving puts the draft in the block, in its place', () async {
    final h = await _harness([
      _block('b1', ['m0', 'm1']),
      _block('b2', ['m2', 'm3']),
    ]);
    await _regenerate(h.container, 'b1');

    await _approve(h.container, 'b1');

    final b1 = await _one(h.container, 'b1');
    expect(b1.content, 'Fresh retelling.');
    expect(b1.draft, isNull);
    expect(b1.level, 1);
    expect(b1.messageIds, ['m0', 'm1']);
    expect(b1.createdAt, 7);
    expect((await _blocks(h.container)).map((b) => b.id), ['b1', 'b2']);
  });

  test('the blocks before it are its context, not itself', () async {
    final h = await _harness([
      _block('b1', ['m0', 'm1']),
      _block('b2', ['m2', 'm3']),
    ]);

    await _regenerate(h.container, 'b2');

    expect(h.llm.user, contains('Old text of b1.'));
    expect(h.llm.user, isNot(contains('Old text of b2.')));
  });

  test('a stale block comes back once its draft is approved', () async {
    final h = await _harness([
      _block('b1', ['m0', 'm1']),
    ]);
    final edited = SummaryChain.index(_edited);
    expect(SummaryChain.isStale(await _one(h.container, 'b1'), edited), isTrue);

    await _regenerate(h.container, 'b1', _edited);
    expect(h.llm.user, contains('Edited.'));
    await _approve(h.container, 'b1', _edited);

    expect(
      SummaryChain.isStale(await _one(h.container, 'b1'), edited),
      isFalse,
    );
  });

  test('a merge is merged again from its parts', () async {
    final h = await _harness([
      _block('p1', ['m0', 'm1'], archived: true),
      _block('p2', ['m2', 'm3'], archived: true),
      _block(
        'merged',
        ['m0', 'm1', 'm2', 'm3'],
        level: 2,
        childIds: const ['p1', 'p2'],
      ),
    ]);

    await _regenerate(h.container, 'merged');
    await _approve(h.container, 'merged');

    final blocks = await _blocks(h.container);
    final merged = blocks.firstWhere((b) => b.id == 'merged');
    expect(merged.content, 'Fresh retelling.');
    expect(merged.level, 2);
    expect(merged.childIds, ['p1', 'p2']);
    expect(blocks.where((b) => b.archived).map((b) => b.id), ['p1', 'p2']);
    expect(h.llm.system, startsWith(summaryMergePrompt));
    expect(h.llm.user, contains('Old text of p1.'));
    expect(h.llm.user, contains('Old text of p2.'));
  });

  test('a merge whose messages changed is refused', () async {
    final h = await _harness([
      _block('p1', ['m0', 'm1'], archived: true),
      _block('p2', ['m2', 'm3'], archived: true),
      _block(
        'merged',
        ['m0', 'm1', 'm2', 'm3'],
        level: 2,
        childIds: const ['p1', 'p2'],
      ),
    ]);

    await expectLater(
      _regenerate(h.container, 'merged', _edited),
      _reason('stale_merge'),
    );
    expect(h.llm.calls, isEmpty);
  });

  test('a note is not regenerated', () async {
    final h = await _harness([
      const SummaryBlock(id: 'note', level: 0, content: 'A note.'),
    ]);

    await expectLater(
      _regenerate(h.container, 'note'),
      throwsA(isA<SummaryChainException>()),
    );
    expect(h.llm.calls, isEmpty);
  });

  test('an answer no shorter than its source leaves no draft', () async {
    final h = await _harness([
      _block('b1', ['m0', 'm1']),
    ]);
    h.llm.answer = 'Far too long. ' * 2000;

    await expectLater(_regenerate(h.container, 'b1'), _reason('not_shorter'));
    expect((await _one(h.container, 'b1')).draft, isNull);
  });

  test(
    'the refusal instruction goes first in the prompt when it is on',
    () async {
      final h = await _harness([
        _block('p1', ['m0', 'm1'], archived: true),
        _block('p2', ['m2', 'm3'], archived: true),
        _block(
          'merged',
          ['m0', 'm1', 'm2', 'm3'],
          level: 2,
          childIds: const ['p1', 'p2'],
        ),
        _block('b3', ['m0', 'm1']),
      ]);
      await h.container
          .read(summaryPreambleProvider.notifier)
          .save(const SummaryPreamble(enabled: true, text: 'Retell it all.'));

      await _regenerate(h.container, 'merged');
      expect(h.llm.system, startsWith('Retell it all.\n\n$summaryMergePrompt'));

      await _regenerate(h.container, 'b3');
      expect(
        h.llm.system,
        startsWith('Retell it all.\n\n$defaultSummaryPrompt'),
      );

      // Off, the prompts go as chosen; the text is kept for next time.
      await h.container
          .read(summaryPreambleProvider.notifier)
          .save(const SummaryPreamble(enabled: false, text: 'Retell it all.'));
      await _regenerate(h.container, 'b3');
      expect(h.llm.system, startsWith(defaultSummaryPrompt));
      expect(
        (await h.container.read(summaryPreambleProvider.future)).text,
        'Retell it all.',
      );
    },
  );

  test('a stopped run writes no draft', () async {
    final h = await _harness([
      _block('b1', ['m0', 'm1']),
    ]);

    await _generator(h.container).regenerateBlock(
      charId: 'char',
      session: _session(),
      blockId: 'b1',
      cancelToken: CancelToken()..cancel(),
    );

    expect((await _one(h.container, 'b1')).draft, isNull);
  });

  test('a draft whose messages changed is not approved', () async {
    final h = await _harness([
      _block('b1', ['m0', 'm1'], draft: _draft(['m0', 'm1'])),
    ]);

    await expectLater(_approve(h.container, 'b1', _edited), _reason('changed'));

    final b1 = await _one(h.container, 'b1');
    expect(b1.content, 'Old text of b1.');
    expect(b1.draft?.content, 'Draft text.');
  });

  test('a draft is edited, then approved as edited', () async {
    final h = await _harness([
      _block('b1', ['m0', 'm1'], draft: _draft(['m0', 'm1'])),
    ]);

    await _generator(h.container).editDraft(
      session: _session(),
      blockId: 'b1',
      content: '  My own words.  ',
    );
    expect((await _one(h.container, 'b1')).draft?.content, 'My own words.');
    await _approve(h.container, 'b1');

    final b1 = await _one(h.container, 'b1');
    expect(b1.content, 'My own words.');
    expect(b1.tokens, estimateTokens('My own words.'));
  });

  test('a discarded draft leaves the block as it was', () async {
    final h = await _harness([
      _block('b1', ['m0', 'm1'], draft: _draft(['m0', 'm1'])),
    ]);

    await _generator(
      h.container,
    ).discardDraft(session: _session(), blockId: 'b1');

    final b1 = await _one(h.container, 'b1');
    expect(b1.draft, isNull);
    expect(b1.content, 'Old text of b1.');
  });

  group('running', () {
    test('counts from its start, and leaves the draft when done', () async {
      final h = await _harness([
        _block('b1', ['m0', 'm1']),
      ]);
      h.llm.gate = Completer<void>();
      final jobs = h.container.read(summaryRegenerationProvider.notifier);

      final run = jobs.regenerate(
        charId: 'char',
        session: _session(),
        blockId: 'b1',
      );
      final running = h.container.read(summaryRegenerationProvider);
      expect(running.since('session', 'b1'), isNotNull);
      expect(running.isBusy('session'), isTrue);
      expect(running.isBusy('other'), isFalse);

      h.llm.gate!.complete();
      await run;

      expect(
        h.container.read(summaryRegenerationProvider).since('session', 'b1'),
        isNull,
      );
      expect(
        (await _one(h.container, 'b1')).draft?.content,
        'Fresh retelling.',
      );
    });

    test('a stop ends the count and writes nothing', () async {
      final h = await _harness([
        _block('b1', ['m0', 'm1']),
      ]);
      h.llm.gate = Completer<void>();
      final jobs = h.container.read(summaryRegenerationProvider.notifier);

      final run = jobs.regenerate(
        charId: 'char',
        session: _session(),
        blockId: 'b1',
      );
      // Let the request go out before stopping it.
      for (var i = 0; i < 1000 && h.llm.calls.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(h.llm.calls, isNotEmpty);
      jobs.cancel('session', 'b1');
      expect(
        h.container.read(summaryRegenerationProvider).since('session', 'b1'),
        isNull,
      );
      h.llm.gate!.complete();
      await run;

      expect((await _one(h.container, 'b1')).draft, isNull);
      expect(h.container.read(summaryRegenerationProvider).lastFailure, isNull);
    });

    test('a failure is kept for the sheet to show', () async {
      final h = await _harness([
        _block('b1', ['m0', 'm1']),
      ]);
      h.llm.answer = 'Far too long. ' * 2000;

      await h.container
          .read(summaryRegenerationProvider.notifier)
          .regenerate(charId: 'char', session: _session(), blockId: 'b1');

      final failure = h.container.read(summaryRegenerationProvider).lastFailure;
      expect(failure?.blockId, 'b1');
      expect(
        failure?.error,
        isA<SummaryChainException>().having(
          (e) => e.reason,
          'reason',
          'not_shorter',
        ),
      );
    });
  });

  group('chain', () {
    test('liveBefore keeps the blocks that start earlier, and notes last', () {
      final chain = [
        const SummaryBlock(id: 'note', level: 0, content: 'A note.'),
        _block('b1', ['m0', 'm1']),
        _block('b2', ['m2', 'm3']),
      ];

      expect(SummaryChain.liveBefore(chain, _messages, 'm2').map((b) => b.id), [
        'b1',
        'note',
      ]);
    });

    test('a draft is put on an active block only', () {
      final chain = [
        _block('b1', ['m0', 'm1']),
        _block('p1', ['m2'], archived: true),
      ];

      expect(
        SummaryChain.putDraft(chain, 'b1', _draft(['m0', 'm1'])).first.draft,
        isNotNull,
      );
      expect(
        () => SummaryChain.putDraft(chain, 'p1', _draft(['m2'])),
        throwsA(isA<SummaryChainException>()),
      );
      expect(
        () => SummaryChain.approveDraft(chain, _messages, 'b1'),
        throwsA(isA<SummaryChainException>()),
      );
    });

    test('a part merged away loses its draft', () {
      final chain = [
        _block('b1', ['m0', 'm1'], draft: _draft(['m0', 'm1'])),
        _block('b2', ['m2', 'm3']),
      ];
      final merged = _block(
        'merged',
        ['m0', 'm1', 'm2', 'm3'],
        level: 2,
        childIds: const ['b1', 'b2'],
      );

      final next = SummaryChain.commitMerge(chain, merged);

      expect(next.firstWhere((b) => b.id == 'b1').draft, isNull);
    });

    test('a draft survives the round trip through storage', () {
      final chain = [
        _block('b1', ['m0', 'm1'], draft: _draft(['m0', 'm1'])),
        _block('b2', ['m2', 'm3']),
      ];

      final decoded = SummaryBlock.decodeList(SummaryBlock.encodeList(chain));

      final draft = decoded.first.draft;
      expect(draft?.content, 'Draft text.');
      expect(draft?.messageIds, ['m0', 'm1']);
      expect(draft?.sourceHash, chain.first.draft?.sourceHash);
      expect(decoded.last.draft, isNull);
      expect(chain.last.toJson().containsKey('draft'), isFalse);
    });
  });

  test('writers to the chain at once keep each other\'s change', () async {
    final h = await _harness([
      _block('b1', ['m0', 'm1']),
    ]);
    final service = h.container.read(summaryServiceProvider);
    List<SummaryBlock> add(List<SummaryBlock> blocks, String id) => [
      ...blocks,
      SummaryBlock(id: id, level: 0, content: 'Note $id.'),
    ];

    await Future.wait([
      for (final id in ['n1', 'n2', 'n3'])
        service.mutateBlocks(
          sessionId: 'session',
          messages: _messages,
          change: (blocks) => add(blocks, id),
        ),
    ]);

    expect((await _blocks(h.container)).map((b) => b.id).toSet(), {
      'b1',
      'n1',
      'n2',
      'n3',
    });
  });
}
