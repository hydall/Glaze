import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/summary_providers.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/summary_block.dart';

List<ChatMessage> _chat(int count, {String text = 'word word word word'}) => [
  for (var i = 0; i < count; i++)
    ChatMessage(
      id: 'm$i',
      role: i.isEven ? 'user' : 'assistant',
      content: '$text $i',
    ),
];

SummaryBlock _block(
  String id,
  List<ChatMessage> messages,
  List<String> ids, {
  int level = 1,
  List<String> childIds = const [],
  bool archived = false,
  int tokens = 10,
}) => SummaryBlock(
  id: id,
  level: level,
  content: 'Block $id',
  messageIds: ids,
  sourceHash: SummaryChain.fingerprint(ids, SummaryChain.index(messages)),
  childIds: childIds,
  archived: archived,
  tokens: tokens,
);

void main() {
  group('planSource', () {
    test('keeps the fresh tail and takes the oldest uncovered run', () {
      final messages = _chat(10);
      final plan = SummaryChain.planSource(
        blocks: const [],
        messages: messages,
        tailBudgetTokens: 0,
        maxSourceTokens: 100000,
      );
      // At least two messages always stay as raw history.
      expect(plan.source.map((m) => m.id), [for (var i = 0; i < 8; i++) 'm$i']);
    });

    test('starts after what live blocks already cover', () {
      final messages = _chat(10);
      final plan = SummaryChain.planSource(
        blocks: [
          _block('a', messages, ['m0', 'm1', 'm2']),
        ],
        messages: messages,
        tailBudgetTokens: 0,
        maxSourceTokens: 100000,
      );
      expect(plan.source.first.id, 'm3');
      // Everything uncovered outside the tail, the run itself included.
      expect(plan.remainingMessages, 5);
    });

    test('the manual tail is a share of the context, or tokens', () {
      const d = SummaryCompactionSettings();
      expect(d.manualTailUnit, SummaryManualTailUnit.percent);
      expect(d.manualTailPercent, 25);
      expect(d.manualTailBudget(32000), 8000);
      final tokens = SummaryCompactionSettings.fromJson({
        'manualTailUnit': 'tokens',
        'manualTailTokens': 3000,
      });
      expect(tokens.manualTailBudget(32000), 3000);
      expect(SummaryCompactionSettings.fromJson(tokens.toJson()), tokens);
      // Tokens have no upper bound; a non-positive number is not a tail.
      expect(
        SummaryCompactionSettings.fromJson({
          'manualTailTokens': 1000000,
        }).manualTailTokens,
        1000000,
      );
      expect(
        SummaryCompactionSettings.fromJson({
          'manualTailTokens': 0,
        }).manualTailTokens,
        d.manualTailTokens,
      );
      // Out-of-range values are clamped, an unknown unit falls back.
      final odd = SummaryCompactionSettings.fromJson({
        'manualTailUnit': 'messages',
        'manualTailPercent': 400,
      });
      expect(odd.manualTailUnit, SummaryManualTailUnit.percent);
      expect(
        odd.manualTailPercent,
        SummaryCompactionSettings.maxManualTailPercent,
      );
    });

    test('counts what is left beyond the run it capped', () {
      final messages = _chat(10);
      final plan = SummaryChain.planSource(
        blocks: const [],
        messages: messages,
        tailBudgetTokens: 0,
        maxSourceTokens: 1,
      );
      expect(plan.source.map((m) => m.id), ['m0']);
      expect(plan.remainingMessages, 8);
    });

    test('a stale block no longer covers its messages', () {
      final messages = _chat(10);
      final blocks = [
        _block('a', messages, ['m0', 'm1']),
      ];
      final edited = [
        messages[0].copyWith(content: 'changed'),
        ...messages.skip(1),
      ];
      final plan = SummaryChain.planSource(
        blocks: blocks,
        messages: edited,
        tailBudgetTokens: 0,
        maxSourceTokens: 100000,
      );
      expect(plan.source.first.id, 'm0');
      expect(SummaryChain.promptView(blocks, edited).content, isEmpty);
    });

    test('hidden and error messages are neither summarized nor counted', () {
      final messages = [
        ..._chat(4),
        const ChatMessage(id: 'h', role: 'user', content: 'x', isHidden: true),
        ..._chat(4).map((m) => m.copyWith(id: '${m.id}b')),
      ];
      final plan = SummaryChain.planSource(
        blocks: const [],
        messages: messages,
        tailBudgetTokens: 0,
        maxSourceTokens: 100000,
      );
      expect(plan.source.map((m) => m.id), isNot(contains('h')));
    });
  });

  group('merge', () {
    test('picks the oldest adjacent run of the lowest level', () {
      final messages = _chat(10);
      final blocks = [
        _block('a', messages, ['m0', 'm1']),
        _block('b', messages, ['m2', 'm3']),
        _block('c', messages, ['m4', 'm5']),
      ];
      final run = SummaryChain.mergeCandidate(
        blocks,
        messages,
        maxInputTokens: 100000,
      );
      expect(run.map((b) => b.id), ['a', 'b', 'c']);
    });

    test('commit archives the parts; delete brings them back', () {
      final messages = _chat(10);
      final blocks = [
        _block('a', messages, ['m0', 'm1']),
        _block('b', messages, ['m2', 'm3']),
      ];
      final merged = _block(
        'ab',
        messages,
        ['m0', 'm1', 'm2', 'm3'],
        level: 2,
        childIds: ['a', 'b'],
      );
      final after = SummaryChain.commitMerge(blocks, merged);
      expect(SummaryChain.live(after, messages).map((b) => b.id), ['ab']);
      expect(after.where((b) => b.archived).map((b) => b.id), ['a', 'b']);

      final restored = SummaryChain.delete(after, 'ab');
      expect(SummaryChain.live(restored, messages).map((b) => b.id), [
        'a',
        'b',
      ]);
    });

    test('a manual selection must be adjacent and of one level', () {
      final messages = _chat(10);
      final blocks = [
        _block('a', messages, ['m0', 'm1']),
        _block('b', messages, ['m2', 'm3']),
        _block('c', messages, ['m4', 'm5'], level: 2),
      ];
      expect(
        SummaryChain.manualMergeSelection(blocks, messages, {
          'b',
          'a',
        }).map((b) => b.id),
        ['a', 'b'],
      );
      expect(
        () => SummaryChain.manualMergeSelection(blocks, messages, {'a', 'c'}),
        throwsA(isA<SummaryChainException>()),
      );
      expect(
        () => SummaryChain.manualMergeSelection(blocks, messages, {'b', 'c'}),
        throwsA(isA<SummaryChainException>()),
      );
    });

    test('withoutStale drops a stale merge with its archive', () {
      final messages = _chat(10);
      final blocks = SummaryChain.commitMerge(
        [
          _block('a', messages, ['m0', 'm1']),
          _block('b', messages, ['m2', 'm3']),
        ],
        _block(
          'ab',
          messages,
          ['m0', 'm1', 'm2', 'm3'],
          level: 2,
          childIds: ['a', 'b'],
        ),
      );
      final edited = [
        ...messages.take(2),
        messages[2].copyWith(content: 'changed'),
        ...messages.skip(3),
      ];
      expect(SummaryChain.withoutStale(blocks, edited), isEmpty);
    });

    test('a stale block with a fresh draft waits for the reader', () {
      final messages = _chat(10);
      final edited = [
        messages[0].copyWith(content: 'changed'),
        ...messages.skip(1),
      ];
      final ids = ['m0', 'm1'];
      final blocks = [
        _block('a', messages, ids).withDraft(
          SummaryDraft(
            content: 'Retold',
            messageIds: ids,
            sourceHash: SummaryChain.fingerprint(
              ids,
              SummaryChain.index(edited),
            ),
          ),
        ),
      ];

      expect(SummaryChain.withoutStale(blocks, edited), blocks);
      // Its messages are not retold again while the draft waits.
      final plan = SummaryChain.planSource(
        blocks: blocks,
        messages: edited,
        tailBudgetTokens: 0,
        maxSourceTokens: 100000,
      );
      expect(plan.source.first.id, 'm2');
    });

    test('editing a draft that is gone says so', () {
      final messages = _chat(4);
      expect(
        () => SummaryChain.editDraft(
          [
            _block('a', messages, ['m0', 'm1']),
          ],
          'a',
          'text',
        ),
        throwsA(isA<SummaryChainException>()),
      );
    });
  });

  test('withoutCovered removes exactly the covered messages', () {
    final messages = _chat(6);
    final view = SummaryChain.promptView([
      _block('a', messages, ['m0', 'm1']),
    ], messages);
    expect(SummaryChain.withoutCovered(messages, view).map((m) => m.id), [
      'm2',
      'm3',
      'm4',
      'm5',
    ]);
  });

  test('notes come last and cover nothing', () {
    final messages = _chat(4);
    final blocks = [
      const SummaryBlock(id: 'n', level: 0, content: 'Note'),
      _block('a', messages, ['m0', 'm1']),
    ];
    final view = SummaryChain.promptView(blocks, messages);
    expect(view.content, endsWith('Note'));
    expect(view.coveredMessageIds, {'m0', 'm1'});
  });

  test('commitSource refuses a run another block already covers', () {
    final messages = _chat(6);
    final blocks = [
      _block('a', messages, ['m0', 'm1']),
    ];
    expect(
      () => SummaryChain.commitSource(
        blocks,
        messages,
        _block('b', messages, ['m1', 'm2']),
      ),
      throwsA(isA<SummaryChainException>()),
    );
  });

  test('an unreadable list decodes to nothing', () {
    expect(SummaryBlock.decodeList('not json'), isEmpty);
    final blocks = [
      _block('a', _chat(2), ['m0']),
    ];
    expect(
      SummaryBlock.decodeList(SummaryBlock.encodeList(blocks)).single.id,
      'a',
    );
  });
}
