import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/context_calculator.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/history_trim.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/features/chat/state/token_breakdown_cache.dart';

/// History of [count] messages, each roughly the same size, ids `m0..mN`.
List<PromptMessage> _history(int count) => [
  for (var i = 0; i < count; i++)
    PromptMessage(
      role: i.isEven ? 'user' : 'assistant',
      content: 'message $i ${'filler ' * 20}',
      sourceMessageId: 'm$i',
      isHistory: true,
    ),
];

ContextCalculator _calculator({
  required String mode,
  String? anchorId,
  int contextSize = 4000,
  int maxTokens = 1000,
}) => ContextCalculator(
  contextSize: contextSize,
  maxTokens: maxTokens,
  historyTrimMode: mode,
  historyAnchorId: anchorId,
);

TokenBreakdown _run(
  ContextCalculator calculator,
  List<PromptMessage> history,
) => calculator.calculate(staticBlocks: const [], historyMessages: history);

void main() {
  group('sliding', () {
    test('keeps as much history as fits and reports no anchor', () {
      final history = _history(80);
      final result = _run(_calculator(mode: HistoryTrimMode.sliding), history);

      expect(result.cutoffIndex, greaterThan(0));
      expect(result.trimmedHistory.length, 80 - result.cutoffIndex);
      expect(result.historyTokens, lessThanOrEqualTo(result.historyBudget));
      expect(
        result.historyAnchorId,
        isNull,
        reason: 'sliding holds nothing still, so there is no anchor to keep',
      );
    });

    test('the cutoff advances as the chat grows', () {
      final first = _run(
        _calculator(mode: HistoryTrimMode.sliding),
        _history(80),
      );
      final later = _run(
        _calculator(mode: HistoryTrimMode.sliding),
        _history(90),
      );

      // The prefix moves every turn — this is exactly what costs the cache.
      expect(later.cutoffIndex, greaterThan(first.cutoffIndex));
    });
  });

  group('stepped', () {
    test('re-anchors with headroom, so it keeps less than sliding would', () {
      final history = _history(80);
      final sliding = _run(_calculator(mode: HistoryTrimMode.sliding), history);
      final stepped = _run(_calculator(mode: HistoryTrimMode.stepped), history);

      expect(stepped.cutoffIndex, greaterThan(sliding.cutoffIndex));
      expect(
        stepped.historyTokens,
        lessThan(sliding.historyTokens),
        reason: 'the spare budget is the headroom the next turns grow into',
      );
      expect(stepped.historyAnchorId, 'm${stepped.cutoffIndex}');
    });

    test(
      'an anchor that still fits holds the prefix still as the chat grows',
      () {
        final first = _run(
          _calculator(mode: HistoryTrimMode.stepped),
          _history(80),
        );
        final anchor = first.historyAnchorId!;

        // Four more turns land; the anchored window still fits, so the request
        // still starts at the same message and the provider's cache can hit.
        final later = _run(
          _calculator(mode: HistoryTrimMode.stepped, anchorId: anchor),
          _history(84),
        );

        expect(later.historyAnchorId, anchor);
        expect(later.trimmedHistory.first.sourceMessageId, anchor);
      },
    );

    test('the anchor moves once the window it opens stops fitting', () {
      final history = _history(200);
      final stale = _run(
        _calculator(mode: HistoryTrimMode.stepped, anchorId: 'm0'),
        history,
      );

      expect(stale.historyAnchorId, isNot('m0'));
      expect(stale.historyTokens, lessThanOrEqualTo(stale.historyBudget));
    });

    test('raising max output tokens re-anchors instead of overflowing', () {
      final history = _history(120);
      final roomy = _run(_calculator(mode: HistoryTrimMode.stepped), history);
      final anchor = roomy.historyAnchorId!;

      // Same chat, same anchor, but the completion budget just doubled — the
      // history budget shrinks by exactly that much.
      final tight = _run(
        _calculator(
          mode: HistoryTrimMode.stepped,
          anchorId: anchor,
          maxTokens: 2500,
        ),
        history,
      );

      expect(tight.historyAnchorId, isNot(anchor));
      expect(tight.historyTokens, lessThanOrEqualTo(tight.historyBudget));
      expect(
        tight.totalTokens + 2500,
        lessThanOrEqualTo(4000),
        reason: 'the prompt must still leave the completion its full budget',
      );
    });

    test('an anchor whose message is gone is replaced, not trusted', () {
      final result = _run(
        _calculator(mode: HistoryTrimMode.stepped, anchorId: 'deleted-message'),
        _history(80),
      );

      expect(result.historyAnchorId, isNotNull);
      expect(result.historyAnchorId, isNot('deleted-message'));
      expect(result.historyTokens, lessThanOrEqualTo(result.historyBudget));
    });

    test('never keeps less history than the budget allows for one message', () {
      // One message far larger than the reduced refill target: the stepped
      // walk would come back empty, so it must fall back to the full budget.
      final huge = [
        PromptMessage(
          role: 'user',
          content: 'x ' * 5000,
          sourceMessageId: 'big',
          isHistory: true,
        ),
      ];
      final budget = ContextCalculator(
        contextSize: 4000,
        maxTokens: 1000,
      ).safeContext;
      expect(
        estimateTokens(huge.single.content),
        allOf(
          greaterThan(
            (budget * (100 - kDefaultHistoryTrimStepPercent) / 100).floor(),
          ),
          lessThanOrEqualTo(budget),
        ),
        reason: 'the fixture must sit between the refill target and the budget',
      );

      final result = _run(_calculator(mode: HistoryTrimMode.stepped), huge);
      expect(result.trimmedHistory, hasLength(1));
      expect(result.cutoffIndex, 0);
    });
  });

  group('live updates', () {
    const base = ApiConfig(id: 'c1');

    String hashFor(ApiConfig config) => TokenBreakdownCache.computeHash(
      charId: 'char',
      sessionId: 'session',
      messageCount: 10,
      contextSize: config.contextSize,
      maxTokens: config.maxTokens,
      authorsNote: '',
      summary: '',
      trimSignature: config.contextBudgetSignature,
    );

    test('switching the trim mode changes the cache key', () {
      final stepped = base.copyWith(historyTrimMode: HistoryTrimMode.stepped);
      expect(hashFor(stepped), isNot(hashFor(base)));
    });

    test('moving either stepped knob changes the cache key', () {
      final stepped = base.copyWith(historyTrimMode: HistoryTrimMode.stepped);
      expect(
        hashFor(stepped.copyWith(historyTrimTriggerPercent: 60)),
        isNot(hashFor(stepped)),
      );
      expect(
        hashFor(stepped.copyWith(historyTrimStepPercent: 50)),
        isNot(hashFor(stepped)),
      );
    });

    test('a cached breakdown is not served across a trim-mode change', () {
      final breakdown = _run(
        _calculator(mode: HistoryTrimMode.sliding),
        _history(40),
      );
      TokenBreakdownCache.set(hashFor(base), breakdown);

      expect(TokenBreakdownCache.get(hashFor(base)), isNotNull);
      expect(
        TokenBreakdownCache.get(
          hashFor(base.copyWith(historyTrimMode: HistoryTrimMode.stepped)),
        ),
        isNull,
      );
    });
  });
}
